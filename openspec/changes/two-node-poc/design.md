# Design

## Context

See `proposal.md` for why this change exists. The constraints that shape the
approach:

- The check is POSIX `sh` for a stock Linux or macOS desktop (spec), so it has
  no `jq`, no `timeout`, no `bash` arrays and no way to ask the kernel for a
  free port.
- The Logos Storage CLI is a long-running node with a REST API. It has options
  and no subcommands (`storage --help`), so nothing in it publishes or fetches
  and then exits.
- Facts about the storage node below were read from
  `logos-storage-nim` at `v0.5.3-2-g9abeb709` and, where marked **observed**,
  seen against a CLI built from that revision. Re-check them there when the
  revision moves.

## Goals / Non-Goals

**Goals:**

- One program that a person or CI can point at a built storage CLI and that
  answers, with an exit status, whether the publish, fetch and re-publish path
  holds.
- Every failure path of that program testable without a real node.
- The facts the issue asked to confirm, recorded where the installer's design
  can use them.

**Non-Goals:**

- Building the storage CLI. The caller supplies it; see "How the CLI is
  obtained".
- A Nix flake, a `nix run .#test` wrapper or a CI workflow. The proposal
  excludes CI, and a flake with no build to define would pin an input nothing
  else uses yet.
- Anything the installer will do with the fetched bytes.

## Decisions

### This PoC comes before any installer code

The issue opens with: "Exercise the riskiest path end to end before committing
to the design." `docs/DESIGN.md` hangs two things on that path that were only
read from source: that a second node can fetch by CID what a first published,
and that the no-seeders fallback works, which needs the CID to be reproducible
from the bytes plus the pinned filename and block size. If either were false
the single-file form and the fallback would both need redesign, so they are
checked before the fetcher is chosen or anything is built on it.

### The check drives the official CLI over REST with `curl`

This is the "CLI plus script" option the issue asks to be recorded. The whole
flow, as the check runs it:

```
storage --data-dir=D --api-port=A --listen-port=L --listen-ip=127.0.0.1 \
        --nat=extip:127.0.0.1 --no-bootstrap-node            # publisher
GET  /api/storage/v1/spr            (Accept: text/plain)     # readiness, and the peer record
POST /api/storage/v1/data?blockSize=131072                   # body: the bytes
     Content-Type: application/octet-stream
     Content-Disposition: attachment; filename="poc-payload.bin"
     -> 200, body is the CID as text
GET  /api/storage/v1/data/<cid>/network/manifest             # JSON, see below
storage ... --bootstrap-node=<spr of the publisher>          # fetcher
GET  /api/storage/v1/data/<cid>/network/stream?advertise=false   # the bytes
SIGTERM                                                      # the node exits cleanly
```

What driving it from shell costs, all **observed**:

- **Readiness has to be polled.** The node prints "REST service started" to its
  log, but the only portable signal is a request that succeeds. `GET /spr` is
  used because the publisher's answer is needed anyway.
- **The fetcher needs the publisher's signed peer record** as its bootstrap
  node; on a fleet the preset replaces this. No explicit `connect` call was
  needed: bootstrapping from the publisher was enough for the fetcher to find
  it as a provider.
- **The manifest is one line of JSON**:
  `{"cid":…,"manifest":{"manifestVersion":0,"treeCid":…,"blockSize":131072,"datasetSize":350000,"filename":"poc-payload.bin","mimetype":"application/octet-stream"}}`.
- **An HTTP client is a dependency.** `curl` was chosen because macOS ships it.
  Considered: `wget` (not on macOS), a raw `/dev/tcp` socket (bash only), `nc`
  (variants disagree on flags, and no HTTP framing). The check names `curl` in
  its diagnostic when it is missing. See Risks: the shipped installer inherits
  this question.
- `curl` is always run with `-q` and `--noproxy '*'`. Without them a user's
  `~/.curlrc` or an `http_proxy` variable would send localhost requests to
  another machine, which the localhost requirement forbids.

### Every fetch starts and stops a node

The issue lists as a fact to confirm: "there is no fetch-one-CID-and-exit call,
so every fetch starts and stops a node". **Confirmed** for the CLI: it has no
subcommands, and the only download paths are REST routes on a running node
(`storage/rest/api.nim`). So a fetch is: start a node, wait for REST, request
the stream, stop the node. **Observed** on localhost: the node's log shows REST
up within a second of start, and the node exits on `SIGTERM` without needing
the `SIGKILL` fallback.

`/network/stream` is used rather than `POST /network`, which starts a
background download and returns a download id to poll: the stream hands the
bytes to the caller in one request, carries a `Content-Length`, and lets `curl`
report a short body as exit 18, which the check treats as a failed fetch.

The fetch is bounded twice. **Observed:** a fetcher with an empty store whose
only bootstrap node is gone answers 404 ("The requested CID could not be
retrieved") after about 27 seconds on its own; the check's 60-second
`--max-time` is the bound that holds if a later node waits longer.

### Resumability

The issue's second fact: "downloads are not resumable but already-stored blocks
are reused (inference)".

- **Not resumable, from source:** no route takes a range or an offset, and
  nothing persists the state of a download. A broken stream is requested again
  from the start.
- **Stored blocks are reused, from source:** the block exchange engine scans
  the local store for each batch and asks the network only for the missing
  indices (`storage/blockexchange/engine/engine.nim`, the `localScan` loop).
- **Observed, whole datasets only:** after one streamed fetch with
  `advertise=false`, the same fetcher served the same CID again with the
  publisher stopped, and again after the fetcher itself was restarted on the
  same data directory. So a completed download survives a node restart and
  needs no provider.
- **Not observed:** reuse after a download interrupted part-way. That would
  need a payload large enough to interrupt; it remains read from source.

### Two ports per node, fixed in the program

The spec's Purpose is written against the CLI from release 0.5.0 on, where a
node has two listeners. Up to 0.4.x a node also opened a UDP discovery port
(`--disc-port`); release 0.5.0 moved discovery from discv5 to the libp2p
Kademlia DHT, which runs over the same TCP listener as everything else
(`logos-storage-nim` commit `d8ff7b34`), and the option was removed.
**Observed:** the 0.5 CLI exits 1 with "Unrecognized option 'disc-port'". The
metrics server would add a third listener the check has no use for, so neither
is passed.

The reserved ports are the ones that are in use on a developer's machine for a
reason unrelated to this check: TCP 8080 is what the CLI gives the REST API
when none is stated, and the Basecamp storage module, which still embeds the
older library, defaults to TCP 8500 for listening and UDP 8090 for discovery
(`logos-storage-ui` `DEFAULT_LISTEN_PORT`, `logos-storage-module`'s interface
header).

The six ports of a run are six constants at the top of the program, so
"distinct, in range, not reserved" is read off one block rather than computed.
Considered and rejected:

- **`--listen-port=0`** (the CLI's own default, a random free port): the spec
  requires a stated non-zero port, and `--api-port` has no such mode.
- **A caller-supplied base port:** needs an allocator that skips reserved
  numbers and checks the range, which is code and tests for a knob nobody has
  asked for.
- **Probing for a free port:** not possible in POSIX `sh` without a helper.

The cost is that two runs at once, or another program on one of the six ports,
make a node fail to start. That fails closed with the node named.

### No CLI version check

The spec puts an earlier CLI outside the capability rather than asking the
check to detect one, and the check does not try:

- The version string is not a reliable input. It is baked in at build time from
  `git describe --tags --abbrev=0` and reads "untagged build" when the build
  had no tags (`storage/conf.nim`, `getStorageVersion`); the Nix build used
  here prints `0.5.3-9abeb709` for both version and revision. A parser would
  refuse valid builds.
- A refusal on version is observable behaviour, so it would belong in the spec
  first.

What an earlier CLI does when driven by this check was not run and is not
claimed.

### The mimetype is pinned as well

The manifest holds `filename`, `mimetype` and `blockSize`, and the CID is the
manifest's. `curl --data-binary` sends
`Content-Type: application/x-www-form-urlencoded` unless told otherwise, so an
upload that states only the filename and block size still puts a mimetype in
the manifest, chosen by the HTTP client. Every upload therefore states
`application/octet-stream`. The spec names only two pinned values; this is
reported to the `spec-writer` and marked `NO SPEC:` in the unit suite.

### The test content is deterministic

The content is 10000 numbered lines of 35 bytes written by `awk`: 350000 bytes,
more than two blocks of 131072 and not a whole number of them. `write_payload`
checks both properties of the file it wrote rather than trusting the
arithmetic.

Random bytes (`/dev/urandom`) would satisfy the spec equally. Deterministic
content was chosen because it makes the printed CID comparable across runs,
machines and CLI versions, which is the property the no-seeders fallback rests
on. **Observed:** three separate runs, under `bash` as `sh` and under
`busybox sh`, printed the same CID. With the CLI at `v0.5.3-2-g9abeb709` that
CID is `zDvZRwzkzpQY1AFjHNXTAUsh1nYyuHQWMwJsMT5jrPL49gGxWDph`; a different
value from a later CLI means the manifest encoding or the chunking changed, and
every hardcoded CID would change with it.

### Three nodes, and the third has no bootstrap node

The publisher and the fetcher are the spec's. The reproduction needs a node
that started empty and has not fetched the content, so it cannot be either of
them. The reproducer is started with `--no-bootstrap-node`: it has no peer, so
an equal CID can only have come from the bytes and the pinned values. Giving it
the publisher as a bootstrap node would also meet the requirement, but would
leave "it never fetched" resting on the absence of a request rather than on the
absence of a route. The two changed-value uploads go to the reproducer too, so
the publisher's store holds exactly the one dataset the fetcher asks for.

### The manifest is parsed with `sed`

`jq` is not on a stock desktop. The check extracts `"blockSize":<digits>` and
`"filename":"<text>"` with two `sed` expressions. This is safe for these two
keys because a JSON string cannot contain an unescaped quote, so no value can
forge the `"key":` sequence. It fails closed: no `blockSize` is "cannot parse",
no `filename` is reported as `none` and is a mismatch, and a filename with an
escaped quote stops at the backslash and is a mismatch. A general JSON reader
in `sh` was not attempted.

### Process handling

- **A watchdog bounds every stop.** `stop_node` sends `SIGTERM`, then waits
  with `wait`, with a background subshell that sends `SIGKILL` after ten
  seconds. Polling with `kill -0` cannot do this: it succeeds on a child that
  has exited but not been reaped. Without the watchdog, `wait` blocks for as
  long as a node ignores the signal; the unit test "a node that ignores SIGTERM
  is still stopped" exercises the path.
- **`kill -0` is still how an early exit is noticed** while waiting for
  readiness. It works there because the loop runs a foreground command between
  checks, and every shell tried reaps finished children while waiting for one,
  so the check lags by at most one poll.
- **`curl` runs in the background and the shell `wait`s for it.** A trapped
  signal interrupts `wait` at once, but queues behind a foreground child, so a
  `SIGTERM` during a 60-second fetch would otherwise be honoured a minute late.
- **`fail` is never called inside a command substitution**, where `exit` leaves
  only the subshell and the run would carry on. Functions hand results back in
  variables for this reason.

### Guards, and what breaks without each

"Watched red" means the guard was removed and the named unit test failed. The
other rows name the test written for the guard, which was not seen failing.

| Guard | Without it |
|---|---|
| The probe that nothing answers on a node's REST port before the node starts | A foreign server on that port answers the readiness poll for a node that died binding it, and the check carries on against a stranger. Watched red: "a foreign server on the REST port is refused". |
| The CID must be letters and digits only | An empty or multi-line upload answer is placed in the manifest URL and the failure is blamed on the manifest step. Test, not watched red: "upload returns no CID". |
| A CLI name with no slash is prefixed with `./` | The shell looks the name up on `PATH`, which is the search the spec forbids. Test, not watched red: "a bare name runs the file in the current directory". |
| `--listen-ip=127.0.0.1` | The node's peer-to-peer listener binds every interface (the CLI's default). No unit test can see a bind address; the spec's wording is met either way, and this is belt for "confined to localhost". |
| The peer record must start with `spr:` and hold only base64url characters | Whatever the publisher's REST port returned becomes a command-line argument of the fetcher. No test turns red: the stub always returns a well-formed record. |
| `cmp` after the sha256 comparison | Nothing observable: content that differs has a different sha256 first. It is the spec's second comparison, and only a sha256 collision could reach it. |

### How the CLI is obtained

The caller builds it. The command used for every real-node run recorded here:

```
nix build "git+file://<path to logos-storage-nim>?submodules=1#default" --no-link --print-out-paths
```

and the CLI is `bin/storage` under the path it prints. That binary links
`/nix/store` paths: it is fit for this check and says nothing about what a
release payload will be.

### Where the files live, and what the two layers see

- `tests/integration/storage-round-trip.sh` is the check. It is the project's
  first integration layer and needs a built CLI.
- `tests/run.sh` runs the unit suite in `tests/unit/` against a stub CLI and a
  stub `curl`. The stub CLI only records how it was started; the stub `curl`
  answers for it, with a CID that depends on the uploaded bytes, the filename,
  the block size and the mimetype, so the reproduction and changed-value checks
  compare something the upload decided.
- The unit suite sees every branch of the check. It cannot see whether a real
  node accepts the options, whether the REST routes exist, or whether a real
  CID reproduces: only a run of the check against a built CLI does.

The scratch directory is kept after a pass as after a failure, and
`--scratch-parent` chooses where it is made (default `$TMPDIR`, then `/tmp`).
Both are unspecified and marked `NO SPEC:` or reported.

## Risks / Trade-offs

- **`curl` on Linux desktops** → Not every Linux desktop installs `curl`. The
  check fails closed and names it. This is a finding for the fetcher choice:
  a shipped installer that drives the CLI over REST needs an HTTP client it can
  count on, or must carry one.
- **Fixed ports collide** → A second concurrent run, or another program on one
  of the six ports, fails the run at node start with the node named. Accepted
  for a check run by hand and by one CI job.
- **The readiness poll trusts the port** → Closed for a server that is already
  there by the pre-start probe. A foreign server that binds the port in the
  moment between the probe and the node's own bind is not covered.
- **Reaping behaviour is shell-dependent** → The early-exit check relies on the
  shell reaping children while it waits for a foreground command. Seen with
  `bash` as `sh` and with `busybox sh`; not seen with `dash` or the macOS `sh`,
  where the worst case is that a dead node is reported as "not ready" after the
  full wait instead of "exited".
- **Localhost says nothing about the fleet** → Bootstrap from a preset, NAT
  traversal, relay and expiry are all outside this check (spec, Purpose).
- **macOS is unrun** → Everything recorded as observed was seen on Linux
  x86_64. The program avoids GNU-only options, but no BSD userland has run it.

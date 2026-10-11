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
        --api-bindaddr=127.0.0.1 --nat=extip:127.0.0.1 \
        --no-bootstrap-node                                  # publisher
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

### The bounds, and what would move them

The spec asks for bounded waits and leaves the numbers to the check. They are
the constants under "Bounds" at the top of the program:

- **A node's start: 30 attempts**, each one readiness request of at most 2
  seconds and a 1-second pause, so at most 90 seconds and 30 when nothing is
  listening (a refused connection returns at once). **Observed:** a node's REST
  API is up within a second of start, so 30 is slack, not a measurement. A
  slow CI runner, or a CLI that does more before it listens, is what would
  force it up. The bound counts attempts because POSIX `sh` has no clock to
  count seconds with (`date +%s` is not in the POSIX the check is written to),
  and the diagnostic says "attempts" so that it is true for both cases.
- **The pre-start probe and each readiness request: 2 seconds.** Both talk to
  localhost, where an answer or a refusal is immediate; the limit only matters
  for a port that accepts a connection and then says nothing.
- **Every other request but the fetch: 30 seconds.** An upload of 350000
  bytes and a manifest read are local and answer in well under a second; the
  value is a ceiling against a hung node, chosen to match the start bound.
- **The fetch: 60 seconds**, argued above from the observed 27.
- **A stop: 10 seconds** before `SIGKILL`; see "Process handling".

### The REST API is bound explicitly, and `STORAGE_` variables are removed

The storage CLI loads its options with `envVarsPrefix = "storage"`
(`logos-storage-nim/storage.nim`), so any option can come from a `STORAGE_`
variable, and the REST bind address default of `127.0.0.1` is the
lowest-priority source (`StandaloneDefaultConfig`, same file). With
`STORAGE_API_BINDADDR=0.0.0.0` in the caller's environment all three nodes
would serve the unauthenticated REST API, which can upload, download and
delete, on every interface, and the run would still pass, because `0.0.0.0`
includes the `127.0.0.1` the check talks to. `STORAGE_METRICS=true` would open
the metrics listener the spec forbids. Fleet bootstrap cannot be reached this
way: `--no-bootstrap-node` wins.

Two measures, each sufficient for the bind address on its own, because the
first is visible in the invocation and the second covers every other option:

- `--api-bindaddr=127.0.0.1` on every node.
- `clear_storage_environment` unsets every `STORAGE_` variable in the check's
  own shell, once, before any node starts. Doing it once in the parent, rather
  than at each launch, means no launch can forget it.

Considered for the second:

- **`env -i CLI …`** gives an empty environment by construction, but `env`
  reads any leading argument that contains `=` as an assignment, so a storage
  CLI under a path with `=` in it would not be run; and it would also drop
  variables a differently built CLI may need, such as a library path.
- **`env -u NAME`** is not in POSIX and has the same `=` problem.

The names come from `env`, whose output cannot tell a variable from a line
inside another variable's multi-line value, and `unset` cannot remove a name
that is not a shell identifier. Both cases leave a `STORAGE_` line in a second
`env` listing, and the check then exits non-zero at the step `environment`
rather than start a node it cannot vouch for. The spec requires this for the
line inside another variable's value (requirement "A storage variable that
cannot be removed stops the run"). For a name that is not a shell identifier
it requires only that no node is given the variable, and leaves open whether
the run is refused, because some shells drop such a variable before the check
sees it; where the shell keeps it, this check refuses. A variable whose name
contains a newline is outside the spec, not handled and not claimed.

The clean-up is only as good as the listing it reads, and a listing that is
missing looks exactly like an environment with nothing to remove. Two cases
made the run pass with the caller's `STORAGE_` variables handed to every node,
both **observed** at the unit layer before they were closed:

- **No `env` on `PATH`.** The shell printed "command not found" twice and the
  run carried on to a full pass. `env` is therefore one of the tools
  `require_tools` looks for; see "Which tools are looked for before anything
  starts".
- **An `env` that exits non-zero.** The listing was read as `env | sed`, and a
  pipeline's status is its last command's, so `sed`'s zero hid `env`'s
  failure. `list_environment` now takes the output into a variable with
  `$(env)`, whose status is `env`'s, and fails at the step `environment` on
  anything but zero, whatever was printed: a partial listing is not evidence
  that the rest holds no `STORAGE_` variable. Both listings, the one before
  the `unset` and the one after, go through it.

Considered for seeing `env`'s status:

- **`set -o pipefail`** is in POSIX only from the 2024 issue; the `sh` of a
  stock desktop cannot be assumed to have it.
- **A file under the scratch directory** would need the scratch directory to
  exist before the environment is known to be clean, and the spec requires the
  refusal to come before it is created.
- **A here-document** to feed the variable to `sed` is a temporary file in
  most shells, written under `TMPDIR`, outside the scratch directory. The
  variable is piped from `printf` instead.

Not closed: an `env` that exits zero and prints nothing, or prints a listing
that is not the environment. The check trusts a zero status, as it trusts
every other tool it finds on `PATH`; the spec asks for no more.

The environment half was read from source and pinned at the unit layer, where
the stub node records the `STORAGE_` variables it was started with. No real
node was started with such a variable set. **Observed** for the option: a real
node accepts `--api-bindaddr=127.0.0.1`, logs
`REST service started address=127.0.0.1:28481`, and the run passes with the
CID recorded under "The test content is deterministic".

### Which tools are looked for before anything starts

`require_tools` looks for a sha256 tool and then for the names in its list,
and stops at the step `tools` naming the first one missing:

- **`curl`, `mktemp`, and `sha256sum` or `shasum`** are outside POSIX, so a
  stock desktop may lack them; the spec requires each to be named.
- **`awk`, `sed`, `cmp`, `wc` and `env`** are POSIX and looked for all the
  same, because the spec names these five. For the first four the reason is
  the diagnostic: without the check a run ends at whichever step first needs
  the utility, blamed on that step. For `env` it is not a matter of the
  diagnostic: a run without it does not end at all (see the `STORAGE_`
  decision above), so this is the one entry of the list whose absence would
  otherwise be a pass.
- **`cat`, `sleep` and `mkdir`** are run without being looked for. The spec
  puts a missing POSIX utility other than the five outside the capability. A
  list of every command the check runs was the alternative; it grows with the
  program and is wrong the first time someone forgets it. Read from the
  code, and not run: none of these three turns a failure into a pass. Without
  `cat` no HTTP status is read, so no node is ever seen ready; without `mkdir`
  no node gets a data directory; without `sleep` the readiness loop reaches
  the same number of attempts sooner and a stop goes to `SIGKILL` at once.

### A node's data directory is made with mode 700

`launch_node` makes each data directory with `mkdir -m 700` although the 077
umask already gives that mode. The node requires it: `checkAndCreateDataDir`
(`storage/utils/fileutils.nim`) compares the directory's mode with `0o700`,
and on a difference logs "Data directory has insecure permissions. Correcting
them." and changes the mode itself. So a looser directory is not refused, it
is silently tightened; stating the mode keeps the node's log free of that
warning and does not lean on the umask line staying where it is. The node's
parent directory, which holds only the log and the peer record, takes the
umask's mode and nothing depends on it beyond the spec's rule that the scratch
directory grants nothing to group or others.

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
make a node fail to start. That fails closed with the node named. The comment
above the constants says so, for whoever next picks a port for another test.

The spec once carried a scenario "Reserved ports are occupied": the check
passing while another process holds TCP 8080, TCP 8500 and UDP 8090. It was
removed. The unit layer's stub binds nothing, so the scenario could only be
seen against a real node, and nothing automated runs that; its checkable
consequences are already scenarios ("Ports passed to each node", "Request
target"). The spec's Purpose now puts the check's result with a reserved port
held outside the capability. It was not run by hand either.

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

### Why the mimetype is a pinned value

The issue names two values to pin, the filename and the block size. The
manifest holds a third, `mimetype`, and the CID is the manifest's. `curl
--data-binary` sends `Content-Type: application/x-www-form-urlencoded` unless
told otherwise, so an upload that states only the filename and block size still
puts a mimetype in the manifest, chosen by the HTTP client: a publisher using
another client, or another `curl` option, would get another CID from the same
bytes, filename and block size, with no error. The spec therefore pins
`application/octet-stream` as a third value, and the check treats it as it
treats the other two: stated in every upload, compared in the publisher's
manifest, and printed on a pass.

The check does not upload under a second mimetype to show the CID moves, as it
does for the filename and the block size; the spec puts that outside the
capability. That the mimetype is in the manifest is **observed** (the manifest
line above); that changing it changes the CID is read from the manifest being
what the CID is computed over, and was not run.

### The test content is deterministic

The content is 10000 numbered lines of 35 bytes written by `awk`: 350000 bytes,
more than two blocks of 131072 and not a whole number of them. `write_payload`
checks both properties of the file it wrote rather than trusting the
arithmetic.

Random bytes (`/dev/urandom`) would satisfy the spec equally. Deterministic
content was chosen because it makes the printed CID comparable across runs,
machines and CLI versions, which is the property the no-seeders fallback rests
on. **Observed:** every real-node run printed the same CID, under the
machine's `sh` and under `busybox sh`, the last two against the check as this
change leaves it (one run under each shell, each exit 0 with the five result
lines). With the CLI at `v0.5.3-2-g9abeb709` that CID is
`zDvZRwzkzpQY1AFjHNXTAUsh1nYyuHQWMwJsMT5jrPL49gGxWDph`, and the content's
sha256 is `46532c61564f34d62d2b42ea062e6726535c6fc21981247faed5ece258fa059c`;
a different CID from a later CLI means the manifest encoding or the chunking
changed, and every hardcoded CID would change with it.

### Three nodes, and the third has no bootstrap node

The reproduction needs a node that started empty and has not fetched the
content, so it can be neither the publisher nor the fetcher. The reproducer is
started with `--no-bootstrap-node`: it has no peer, so an equal CID can only
have come from the bytes and the pinned values. Giving it the publisher as a
bootstrap node was the alternative; it would leave "it never fetched" resting
on the absence of a request rather than on the absence of a route, and the spec
now requires the reproducer to have no bootstrap node. The two changed-value
uploads go to the reproducer too, so the publisher's store holds exactly the
one dataset the fetcher asks for.

### The manifest is parsed with `sed`

`jq` is not on a stock desktop. The check extracts `"blockSize":<digits>`,
`"filename":"<text>"` and `"mimetype":"<text>"` with three `sed` expressions.
This is safe for these keys because a JSON string cannot contain an unescaped
quote, so no value can forge the `"key":` sequence. It fails closed: no
`blockSize` is "cannot parse", a missing `filename` or `mimetype` is reported
as `none` and is a mismatch, and a value with an escaped quote is captured up
to that quote, backslash included (`[^"]*` matches a backslash), which is not
the pinned value and is a mismatch. The mimetype is compared as the node prints it,
which is **observed** to be `application/octet-stream` with an unescaped `/`; a
node that wrote `\/` would fail the check rather than pass it. A general JSON
reader in `sh` was not attempted.

### Process handling

- **A watchdog bounds every stop.** `stop_node` sends `SIGTERM`, then waits
  with `wait`, with a background subshell that sends `SIGKILL` after ten
  seconds. Polling with `kill -0` cannot do this: it succeeds on a child that
  has exited but not been reaped. Without the watchdog, `wait` blocks for as
  long as a node ignores the signal; the unit test "a node that ignores SIGTERM
  is still stopped" exercises the path.
- **A node leaves the list of running nodes only after it has been reaped.**
  `cleanup` stops whatever is on that list. A signal can interrupt `stop_node`
  while it waits for a node that is slow to die; if the node had already been
  taken off the list, `cleanup` would not stop it, and the check would exit
  with the node alive until the orphaned watchdog killed it up to ten seconds
  later. It is taken off afterwards rather than left on because `cleanup`
  would otherwise signal a pid that has been reaped and may since belong to an
  unrelated process. `cleanup` also ends the interrupted stop's watchdog and
  starts the stop again with a fresh one.
- **`cleanup` ignores `SIGINT` and `SIGTERM` while it runs**, so a second
  Ctrl-C cannot cut the stopping short and leave a node behind. The price is
  that an impatient user waits up to ten seconds per node; the alternative
  breaks the spec's "No node outlives the run".
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

"Watched red" means the guard was removed from a copy of the check and the
named unit test failed, under the default `sh` of the machine it was run on
(bash). Every row was measured against the check as this change leaves it; a
row that says no test turns red is a gap, and says whose.

| Guard | Without it |
|---|---|
| The probe that nothing answers on a node's REST port before the node starts (`require_silent_port`, called for every node) | A foreign server on that port answers the readiness poll for a node that died binding it, and the check carries on against a stranger. Watched red: "a foreign server on the publisher's REST port is refused" and "a foreign server on the fetcher's REST port is refused". Watched red with the probe skipped for the reproducer alone: "a foreign server on the reproducer's REST port is refused", and nothing else. |
| The mimetype comparison in `check_manifest` | A manifest carrying a mimetype the HTTP client chose passes, and the printed CID is one a second publisher cannot reproduce. Watched red: "manifest reports another mimetype" and "manifest reports no mimetype". |
| The scratch parent's absolute form goes to its own variable | The failed `cd` empties the variable the diagnostic prints, so a scratch parent that is not a directory is refused without being named. Watched red: "a scratch parent that does not exist is refused and named" and "a scratch parent that is a file is refused and named". |
| A relative scratch parent is prefixed with `./` before `cd` | `cd -- -` means "the previous directory", so a directory named `-` is not entered. Watched red: "a scratch parent named - is a directory like any other". |
| An empty scratch parent is refused before `cd` | `cd ''` is the current directory in shells that accept it, so the scratch directory would land in the caller's working directory. **Not watched red:** with the refusal removed, "an empty scratch parent is refused" still passed, because bash's `cd ''` fails by itself. The guard is for shells where it does not; no such shell was run with the guard removed. |
| The CID must be letters and digits only | The CID goes into two URLs and the result lines: a multi-line answer could forge a result line, and one with `/` could change the path requested. Watched red with the character class removed and the empty case kept: the five tests "a publisher upload answer … is not a CID" (a slash, a second line, a space, a dot, a hyphen) and "a reproducer upload answer that is not a CID is refused", and nothing else. The reproducer test malforms the third upload there, not the first: a malformed first answer is also not the recorded CID, so the run fails at the re-upload step with or without this guard. |
| A CLI name with no slash is prefixed with `./` | The shell looks the name up on `PATH`, which is the search the spec forbids. Watched red: "a bare name runs the file in the current directory" and "an operand after the option terminator is the storage CLI". |
| `--listen-ip=127.0.0.1` | The node's peer-to-peer listener binds every interface (the CLI's default), so a machine on the same network could reach a node the spec confines to localhost. Watched red: "nodes are confined to localhost", which sees the option on each invocation. No test sees the address a real node binds. |
| `--api-bindaddr=127.0.0.1` | The REST bind address is left to the CLI's lowest-priority default. Watched red, before the option was added: "every node's REST API is bound to localhost and takes no configuration file". |
| `clear_storage_environment` | A `STORAGE_` variable of the caller configures every node. Watched red, before the function existed: "no node is given a STORAGE_ variable from the caller's environment" and "a STORAGE_ line the check cannot remove from the environment stops the run". The refusal on a leftover line was not removed on its own. |
| `env` in the list `require_tools` looks for | Without `env` the clean-up lists nothing and removes nothing, and the run passes with the caller's `STORAGE_` variables given to every node. Watched red, before `env` was added to the list: "env is not available" (exit 0, three invocations). |
| `list_environment` fails when `env` exits non-zero | A failed `env` reads as an environment with no `STORAGE_` variable. Watched red, with the listing still read as `env \| sed`: the three tests "an env that exits non-zero … stops the run" (after printing nothing, the environment, and a listing without the storage variable). |
| The second `list_environment`, after the `unset` | The leftover test would read the listing taken before the `unset`. Watched red with that one call removed: "an env that exits non-zero on its second run stops the run", and also "no node is given a STORAGE_ variable from the caller's environment" and "an env shim that exits zero does not stop the run", which then refuse variables that were in fact removed. |
| The peer record must be `spr:` and a body of base64url characters | The value is one quoted word, `--bootstrap-node=<value>`, so it cannot become a second option. What goes wrong is quieter: an error page or a truncated record starts a fetcher with a bootstrap node it cannot use, the fetcher finds no provider, and the run fails a fetch timeout later with the fetch step blamed. Watched red: "a publisher answer that is not a peer record is refused". "a peer record with no body is refused" was not seen failing: the mutant kept the empty case. |
| `sha256_of` reads the file on standard input and accepts only output that starts with 64 hex digits | On standard input the tool prints no file name, so nothing but the digest can match. Trusting the exit status alone was the alternative: a tool that exits 0 and prints nothing would give two empty digests that compare equal, and a download would "verify" against nothing. Watched red with the length test removed: "sha256 tool prints nothing for the test content". The three other "sha256 tool …" tests stayed green under that mutant: a failing tool is caught by its exit status, and an empty digest for the fetched content alone is a mismatch. |
| `-q` first and `--noproxy '*'` on every `curl` | A user's `~/.curlrc` or a proxy variable sends a localhost request to another machine. Watched red: "every request is made with -q first and --noproxy given *". The stub records the arguments; no test sees a real `curl` honour them. |
| The `SIGKILL` watchdog in `stop_node` | The check waits for as long as a node ignores `SIGTERM`. Watched red: "a node that ignores SIGTERM is still stopped" (the check took the stub's full 90 seconds). |
| A node is forgotten only after `wait` returns | See "Process handling". Watched red, before the fix: "SIGTERM during the stop of a node still leaves no node behind". |
| `cmp` after the sha256 comparison | It is the spec's second comparison, and the only one left when the two digests agree: with a sha256 tool that answers the same for every input, a download that differs from the test content passes. Watched red with the `cmp` call removed: "equal digests do not hide a fetched content that differs", and nothing else. That test runs the check with a sha256 tool that prints one constant digest, because every other test whose content differs fails the sha256 comparison first. |

### A repeated `--scratch-parent` takes its last value

The argument loop assigns on each occurrence, so the last one wins; the spec
now states that. Rejecting a repeat was the alternative. Last-wins is what
lets a wrapper state a default and a caller override it by appending, which is
how the unit suite's own runner and tests use the option.

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

### The test file is linted through the runner, with no file-level directive

`tests/unit/storage-round-trip.test.sh` is sourced by `tests/run.sh`, and
every variable either file reads may be assigned in the other. The lint
command is:

```
shellcheck --shell=sh -x -a tests/integration/storage-round-trip.sh tests/run.sh \
    tests/unit/stubs/storage tests/unit/stubs/curl \
    tests/unit/broken-sha256/sha256sum tests/unit/fixed-sha256/sha256sum
```

`-x` follows the `# shellcheck source=` line in the runner, so each file's
assignments and reads are known to the other; `-a` (`--check-sourced`) reports
what is found in the sourced file. All **observed** with `shellcheck` 0.11.0:

- **Without `-a` the test file is not linted at all.** A misspelt `$scrach`
  planted in it, and a variable it reads left unassigned in the runner, were
  both silent under `-x` alone; only the runner's own unused assignment was
  reported. Every earlier "no output" for this piece was run without `-a` and
  says nothing about the test file.
- **With `-x -a`, both plants are reported** (`SC2154` in the test file, at
  the use; `SC2034` in the runner), with neither file carrying a file-level
  directive.
- **The test file named as its own argument** reports each of the runner's
  variables as unassigned (`SC2154`) and the last assignment of each variable
  only the runner reads as unused (`SC2034`). That is the noise the two
  file-level directives, `disable=SC2034` in the runner and `disable=SC2154`
  in the test file, were written against; they also hid every real misspelling
  in the whole of both files. Both are removed, and the test file is not named
  on the command line.

What remains are per-line directives, each on the one command it is for:
`SC2086` where the shell under test is deliberately word-split, and `SC2016`
on the three `printf` commands whose single-quoted arguments are the source
text of a stand-in program and must not expand where they are written.

Considered: a use-site line such as `: "$stub_cli" "$scratch"` naming the
cross-file variables. It needs keeping in step with both files by hand, and
`-a` makes it unnecessary.

### The scratch directory is made by `mktemp -d` under a 077 umask

The spec asks for a directory the run creates, new for each run, with no
permission for group or others, and never deleted by the check. `mktemp -d`
gives the first two atomically and fails if it cannot, which a `mkdir` of a
name built from `$$` would not: a process id repeats, and the name can be
guessed and created first by another user of a shared `/tmp`. `umask 077` at
the top of the program covers the directory and every file later written under
it, the node logs included. `mktemp` is not in POSIX, so it is one of the tools
the check names and looks for before doing anything.

The check keeps the directory after a pass as after a failure so that a pass
can be inspected the same way; removing it is the caller's.

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
  shell reaping children while it waits for a foreground command. The worst
  case where a shell does not is that a dead node is reported as "not ready"
  after the full wait instead of "exited". Which shells the suite has been run
  under is in `tasks.md`; the macOS `sh` is not among them.
- **Localhost says nothing about the fleet** → Bootstrap from a preset, NAT
  traversal, relay and expiry are all outside this check (spec, Purpose).
- **macOS is unrun** → Everything recorded as observed was seen on Linux
  x86_64. The program avoids GNU-only options, but no BSD userland has run it.

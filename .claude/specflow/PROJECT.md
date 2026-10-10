# specflow project overlay

<!--
Read in full by every specflow agent before its first shell command. It holds
this project's facts; it does not change specflow's rules.
-->

This project is at design stage: no code exists yet, so several sections state
what is planned and say so. Each is revised in the change that introduces the
thing it describes, never ahead of it.

## Test layers

Every layer is plain POSIX `sh`, run through a wrapper rather than an
environment prefix. **None of these layers exists yet**; a row is made real by
the change that adds it.

| Layer | Command | Sees | Cannot see |
|---|---|---|---|
| Static | `nix run .#lint` (`shellcheck`, `shfmt`) | syntax errors and common shell traps in the shipped script and the release tooling | behaviour; a script can pass every check and still skip a verification |
| Unit | `sh tests/run.sh`, or `nix run .#test` | platform detection, sha256 and signature failure paths, the no-seeders prompt and install placement, against a stub storage binary and fake artifacts | the real storage network, a real node, a real DMG |
| macOS | the unit suite plus an `hdiutil` DMG install, on a macOS runner | GNU versus BSD tool differences and the DMG mount and copy step against a locally created DMG | Gatekeeper's verdict on a DMG fetched over the network |
| Integration | build the storage CLI through Nix, then a two-node localhost publish and fetch | the real CID round trip: pinned filename and block size reproduce the same CID, and a fetched file verifies | the fleet's bootstrap, NAT traversal and relay; behaviour with the fleet down |

- **A green unit suite proves nothing about the network path.** Only the
  integration layer exercises a real node, and only on localhost.
- **The signature failure tests must be seen failing.** A test that never
  rejects a bad signature proves nothing; watch it fail against a deliberately
  broken one before trusting it.

## Build

**None yet.** The planned shape is `nix build .#installer`, producing the
shareable file from pinned inputs. It is filled in by the first change that
builds anything, and depends on the fetcher choice and the size measurement
(issues #3 and #1 on GitHub).

- **A binary from a plain Nix build is not portable.** It links `/nix/store`
  paths, so its size, and whether it runs elsewhere, say nothing about what
  ships. The release payloads need a portable or static build.

## Mutation tool

None. There is no practical mutation-testing tool for POSIX shell. Compensate
at review: every verification branch is read for a way to be skipped, and each
failure-path test is watched failing (see Test layers).

## CI gates

**No workflow exists yet.** Target, once it does:

- `lint`, `unit` and `macOS` run on `pull_request` and on pushes to `main`,
  and are the required checks.
- `integration` runs on pull requests that touch the fetcher or release
  paths, and nightly, using a shared Nix cache. It is not a required check at
  first: the storage flake declares no binary cache, so a cold build is slow.
- **Blind spots:** a green `unit` or `macOS` run says nothing about the real
  network; a green `integration` run says nothing about the fleet, NAT or relay
  (see Test layers). A workflow that triggers on `pull_request` only gives a
  branch with no PR no run.
- `main` is unprotected today (read
  `gh api repos/fryorcraken/basecamp-installer/branches/main/protection`).
  Protection is applied only after the first workflow lands, and only when
  the owner says so: this project never changes a GitHub setting on its own.
- **Signing is never a CI step.** CI builds and tests the unsigned file; the
  owner signs offline (see Hazards).

## Never commit

`tmp/`, `result` and `result-*` out-links, downloaded Basecamp artifacts
(AppImage, DMG, `.app.tar.gz`), built storage binaries and assembled payloads,
storage node `data-dir` directories, **any private signing key** and any
generated signature, and the generated installer file itself. The release
tooling reproduces the file from pinned inputs; committing each release would
put 50 to 100 MB blobs in history.

## Hazards

- **The CID depends on more than the bytes.** It is the manifest CID, and the
  manifest holds `filename`, `mimetype` and `blockSize`. A re-upload under a
  different name, or with a different block size, yields a different CID and
  no error. Pin both wherever a CID is produced or checked.
- **Stored content expires.** `block-ttl` defaults to 30 days and deletes
  blocks even when they were downloaded rather than uploaded; the C API cannot
  extend it. A test node that works today loses its data later. Set a very
  large `block-ttl` on any node meant to keep content.
- **GNU and BSD tools differ**: `sed -i`, `stat`, `sha256sum` against
  `shasum -a 256`, and `base64`. A script green on Linux can fail on macOS;
  the `macOS` layer exists for this.
- **Default storage ports collide with a running Basecamp.** The storage
  module defaults to UDP 8090 and TCP 8500, so a local node test can fail for
  a reason unrelated to the change. Choose ports explicitly in tests.
- **A Nix-store binary is not what ships** (see Build). Do not read a size or
  a successful run from one as evidence about a release payload.
- **Never run, read or ask for the signing key in an agent session.** The
  owner signs offline. An agent that needs a signed fixture generates a
  throwaway test key and says so.
- **Read YAML with `yq` and JSON with `jq`, never Python.** A `python3` call
  that parses one costs the owner an approval click where `jq` would not.
- **Never `ls` or `readlink` a `/nix/store` path** to find a build artefact;
  the store is outside the working directories and each probe costs an
  approval click.

## Extra stages

None.

## Lessons

None.

## code-reviewer

This project's output is a file that downloads bytes from a peer-to-peer
network and installs software with the user's own privileges. Review it as a
supply-chain component:

- **All network bytes are untrusted**: the manifest, every block, the
  filename, and anything a peer or mirror sends.
- **Verification precedes everything that acts on the bytes.** The sha256 and
  the signature are checked before any extraction, `chmod`, mount, copy or
  execution. A path where bytes are used before they are verified is a
  critical finding.
- **A mismatch aborts, with no silent fallback.** Falling back to another
  source, skipping a check on error, or proceeding on an unparsable result are
  all critical. The only sanctioned fallback is the interactive GitHub
  prompt, which still verifies against the hardcoded sha256.
- **A crash is not the severe failure here; a skipped verification is.** Weigh
  findings accordingly, and read every error path for whether it fails closed.
- **Check portability as part of correctness**: a bashism or a GNU-only flag
  in the shipped file is a defect, not a style point.

## dev-writer

- **Fail closed.** Any error in verification, parsing or extraction exits
  non-zero before anything is installed.
- **No network bytes reach a shell, `eval`, a path or an `exec` unquoted or
  unvalidated.** Treat filenames from a manifest as hostile.
- **The shipped file is POSIX `sh`**, run on a stock Linux or macOS desktop,
  with no interpreter beyond what a fresh install has. Release tooling follows
  the same rule and uses Nix for everything else.
- **Pin the filename and block size** wherever a CID is produced.
- **Each failure path gets a test, watched failing first.**

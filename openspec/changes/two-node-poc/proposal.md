# Proposal

## Why

The design rests on a path nobody has run: publish a file on one Logos Storage
node, fetch it by CID from another, and get the same CID again from the same
bytes. Every claim about that path in `docs/DESIGN.md` was read from source,
not observed, and the no-seeders fallback only works if the CID is
reproducible. This change runs the path end to end on one machine before
anything is built on top of it.

## What Changes

- Add a round-trip check: a POSIX `sh` program that drives a caller-supplied
  Logos Storage CLI through publish, fetch, verify and re-publish, using nodes
  on localhost only.
- The check pins the filename, block size and mimetype of the content it
  publishes, reports the CID, and confirms the node's manifest carries all
  three pinned values.
- The check fetches the content on a second, ephemeral node without
  advertising it, and verifies the fetched bytes and their sha256 against the
  original.
- The check confirms the same bytes and pinned values give the same CID on a
  node that never held the content, and that a different filename or block
  size gives a different one.
- The check's command line, the tools it needs beyond POSIX, where its scratch
  directory is made and that it is kept, and its refusal of a REST port that
  already answers are part of the contract.
- Every failure exits non-zero and names the step that failed; success is
  reported only when every verification ran and passed.
- The first runnable integration layer for this project comes into existence.

Not in this change: the installer file, any install step, the fleet's
bootstrap, NAT traversal and relay, seeding and `block-ttl`, the signature, a
CI workflow, the choice of fetcher, caller-chosen ports, concurrent runs, and a
CID under a changed mimetype.

## Capabilities

### New Capabilities

- `storage-round-trip`: the localhost check that content published to Logos
  Storage under a pinned filename, block size and mimetype is fetched intact by
  a second node and has a reproducible CID.

### Modified Capabilities

None.

## Impact

- New release-tooling and test code; no shipped installer file exists yet and
  none is produced here.
- A new dependency on a built `logos-storage` CLI, release 0.5.0 or later,
  supplied to the check by its caller. How it is built is the design's concern.
- `docs/DESIGN.md` states several facts as read from source and untested; what
  this change observes about them is recorded there and in `design.md`.
- The overlay's `Integration` test-layer row describes this check as a target.
  The overlay is the owner's file, so making that row real is proposed to the
  owner, not edited here.

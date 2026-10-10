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
- The check pins the filename and block size of the content it publishes,
  reports the CID, and confirms the node's manifest carries both pinned values.
- The check fetches the content on a second, ephemeral node without
  advertising it, and verifies the fetched bytes and their sha256 against the
  original.
- The check confirms the same bytes, filename and block size give the same CID
  on a node that never held the content, and that a different filename or block
  size gives a different one.
- Every failure exits non-zero and names the step that failed; success is
  reported only when every verification ran and passed.
- The first runnable integration layer for this project comes into existence.

Not in this change: the installer file, any install step, the fleet's
bootstrap, NAT traversal and relay, seeding and `block-ttl`, the signature, a
CI workflow, and the choice of fetcher.

## Capabilities

### New Capabilities

- `storage-round-trip`: the localhost check that content published to Logos
  Storage under a pinned filename and block size is fetched intact by a second
  node and has a reproducible CID.

### Modified Capabilities

None.

## Impact

- New release-tooling and test code; no shipped installer file exists yet and
  none is produced here.
- A new dependency on a built `logos-storage` CLI, supplied to the check by its
  caller. How it is built is the design's concern.
- `docs/DESIGN.md` states several facts as read from source and untested; what
  this change observes about them is recorded there and in `design.md`.
- The overlay's `Integration` test-layer row describes this check as a target.
  The overlay is the owner's file, so making that row real is proposed to the
  owner, not edited here.

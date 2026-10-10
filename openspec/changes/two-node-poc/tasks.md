## Stages

- [x] spec — `spec-writer`
- [x] design + code — `dev-writer`
- [ ] tests — `tester`
- [ ] review: correctness — `code-reviewer`
- [ ] review: security — `code-reviewer`
- [ ] review: readability — `code-reviewer`
- [ ] review: architecture — `code-reviewer`
- [ ] review: spec-test — `spec-test-reviewer`
- [ ] review: design — `design-reviewer`
- [ ] findings all ticked, `findings/` deleted — `closer`
- [ ] `openspec validate --strict`, then `archive` — `closer`
- [ ] CI green, title/body checked, PR merged — `closer`

# Tasks

The unit suite is `sh tests/run.sh`; a test is named by the string it prints.
"Real node" means `tests/integration/storage-round-trip.sh` run against a CLI
built as `design.md` describes.

## 1. Preflight and scratch

- [x] 1.1 Refuse a missing, absent or non-executable storage CLI before any node starts, and never look a bare name up on `PATH`; verified by "no storage CLI named", "named path does not exist", "named path is not executable", "a bare name is not looked up on PATH" and "a bare name runs the file in the current directory"
- [x] 1.2 Pick `sha256sum` or `shasum` and fail naming the sha256 tool when neither exists; verified by "no sha256 tool is available"
- [x] 1.3 Create one scratch directory, print its path on standard error and write nothing outside it; verified by "logs survive a failure, and every file is under the scratch directory"
- [x] 1.4 Write deterministic test content longer than one block and not a whole number of blocks, and record its sha256; verified by "uploads carry the pinned values"
- [x] 1.5 Refuse a scratch parent that is not a directory, naming it as given and creating nothing, and take a directory named `-` as a directory; verified by "a scratch parent that does not exist is refused and named", "a scratch parent that is a file is refused and named", "an empty scratch parent is refused" and "a scratch parent named - is a directory like any other"
- [x] 1.6 Keep the scratch directory after a pass; verified by "the scratch directory is kept after a pass"

## 2. Nodes

- [x] 2.1 Start each node with both ports stated, distinct and not reserved, NAT `extip:127.0.0.1`, `--listen-ip=127.0.0.1`, and no `--disc-port` or `--metrics`; verified by "ports are stated, distinct and not reserved" and "nodes are confined to localhost"
- [x] 2.2 Start the publisher and the reproducer with `--no-bootstrap-node` and the fetcher with the publisher's peer record only; verified by "nodes are confined to localhost"
- [x] 2.6 Refuse to start a node whose REST port already answers, naming the node and the port; verified by "a foreign server on the publisher's REST port is refused"
- [x] 2.3 Wait a bounded time for REST, failing with the node named when it exits early or never answers; verified by "node exits during start" and "node never becomes ready"
- [x] 2.4 Stop every node on exit, on failure and on `SIGTERM`, with `SIGKILL` as the fallback; verified by the no-node-left assertion that ends every test, "a node that ignores SIGTERM is still stopped" and "SIGTERM stops the running node and exits non-zero"
- [x] 2.5 Record the reasoning for two ports, the reserved ports and the fixed constants in `design.md`; delivered as "Two ports per node, fixed in the program"

## 3. Publish and manifest

- [x] 3.1 Upload with the pinned filename, block size and mimetype and record the CID, failing at the upload step on an error or an unusable CID; verified by "uploads carry the pinned values", "every upload states the pinned mimetype", "upload is refused" and "upload returns no CID"
- [x] 3.2 Read the publisher's manifest and fail unless it reports the pinned filename, block size and mimetype, with the expected and the reported value in the diagnostic; verified by the tests whose names begin "manifest "
- [x] 3.3 Stop at a failed manifest check without starting the fetcher; verified by "a failed manifest check starts no fetcher"

## 4. Fetch and verify

- [x] 4.1 Start the fetcher on an empty data directory after the CID is recorded, stream the CID with `advertise=false`, and stop the fetcher; verified by "the fetcher starts empty, fetches by CID without advertising, and is stopped"
- [x] 4.2 Fail at the fetch step on an error answer, a short body or a provider that is gone, within a bound; verified by "fetch answers with an error", "download ends before the content is complete" and "publisher is gone when the fetcher asks"
- [x] 4.3 Compare the fetched sha256 with the one computed before the upload and state both on a mismatch; verified by "fetched content differs", "fetched content is truncated" and the two "sha256 tool …" tests
- [ ] 4.4 Compare the fetched bytes with `cmp`. Satisfied by construction, and left unticked because no test can show it: content that differs fails the sha256 comparison first, so only a sha256 collision reaches the `cmp` call in `verify_fetched`.

## 5. Reproduction and result

- [x] 5.1 Re-upload with the pinned values to a node that started empty and never fetched, and fail unless the CID is the recorded one, stating both; verified by "the reproduction node starts empty and never fetched", "CID does not reproduce", "second upload is refused" and "second upload returns no CID"
- [x] 5.2 Upload once with another filename and once with another block size and fail when either returns the recorded CID, naming the value; verified by "a changed filename gives the recorded CID", "a changed block size gives the recorded CID" and "changed-value uploads change exactly one value"
- [x] 5.3 Print the five result lines, and nothing else, on a full pass only; verified by "full pass prints the five result lines and nothing else" and by the no-`cid=` assertion in every failure test

## 6. Against a real node

- [x] 6.1 Run the check against a storage CLI built from `logos-storage-nim` with `sh` and with `busybox sh`; verified by exit 0, the five result lines and the same CID from both runs
- [x] 6.2 Record what was observed, and what was only read from source, in `design.md` and `docs/DESIGN.md`; delivered as the entries marked "Observed"
- [x] 6.3 Lint the check, `tests/run.sh` and the two stubs with `shellcheck --shell=sh -x`; verified by no output

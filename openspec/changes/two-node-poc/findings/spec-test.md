# spec-test findings: two-node-poc

Reviewed: `specs/storage-round-trip/spec.md` against `tests/run.sh`,
`tests/unit/storage-round-trip.test.sh` and the stubs under `tests/unit/`.
The suite is green: `sh tests/run.sh` and `sh tests/run.sh "busybox sh"` both
print `71 tests, 0 failed` on the unmutated tree.

Mutations run, both against `tests/integration/storage-round-trip.sh`, both
restored (`git status --short` is empty). Output read from `sh tests/run.sh`:

1. The fetcher's `--data-dir` pointed at the publisher's data directory
   (`start_node`, the `--data-dir=` line). **Survived**: 71 tests, 0 failed.
2. The `stop_node "$fetcher_pid"` call after `fetch` removed. **Survived**:
   71 tests, 0 failed.

- [ ] **`tester`** — "the fetcher starts empty, fetches by CID without
      advertising, and is stopped" and "the reproduction node starts empty and
      never fetched", `assert_empty_file "$state/data-dir-at-start-*"`;
      `tests/unit/stubs/storage` line 36.
      **Scenario:** the stub node never writes into its data directory, so any
      data directory is empty at start whatever the check did. A check that
      hands the fetcher the publisher's data directory (the fetcher then holds
      the content before it fetches, and the round trip proves nothing) passes
      "Fetcher starts empty" and "Reproducer starts empty and has not fetched".
      Severity high: this is the property that makes the fetch a real network
      fetch.
      **Measured:** mutation 1 above, 71 tests passed. Fix shape: have the stub
      write a marker file into its data directory when it starts and, in the
      test, assert each node's data directory differs from every other node's
      and held nothing before the stub wrote.

- [ ] **`tester`** — "the fetcher starts empty, fetches by CID without
      advertising, and is stopped"; the name promises a stop the body never
      checks. Requirement "The fetcher is ephemeral and does not advertise":
      "MUST stop it once the fetch has ended".
      **Scenario:** a check that leaves the fetcher running until the run exits
      (so the reproducer is uploaded to while the fetcher still holds the
      content and its ports) passes; `assert_no_node_left` runs only after the
      whole check has exited. Severity medium.
      **Measured:** mutation 2 above, 71 tests passed. Fix shape: have the
      stub curl record, at the reproducer's first request, whether
      `listening-fetcher` still exists, and assert it does not; or rename the
      test.

- [ ] **`tester`** — requirement "Fetched content is verified against the
      original": "byte-for-byte identical ... and its sha256 equals". Task 4.4
      says no test can show the byte comparison, and it is left unticked.
      **Scenario:** that is not so. A sha256 shim that prints one constant
      non-empty digest for every input, together with the `fetch-corrupt` knob,
      makes the digests equal while the bytes differ, so only the byte
      comparison can fail the run. The mirror case, identical bytes but a
      different non-empty second digest, would pin the digest comparison
      without the byte comparison masking it; today "fetched content differs"
      fails both comparisons at once, so deleting either one leaves it green.
      Severity medium. **Not measured:** I did not mutate the comparison.

- [ ] **`tester`** — requirement "A REST port that already answers is
      refused": "Before starting a node ... the REST API port that node is to
      be given" (every node).
      **Scenario:** only the publisher's and the fetcher's ports are tested. A
      check that probes the publisher and fetcher but not the reproducer's
      port passes. Also, the stub's foreign server always answers 200
      (`reply 200`); a typical foreign server answers 404 or 401 on
      `/`, and "answers" is not shown to include those. Severity medium.
      **Not measured.**

- [ ] **`tester`** — requirement "The caller chooses where the scratch
      directory is made": "and under `/tmp` otherwise".
      **Scenario:** no test runs with `TMPDIR` unset or empty. `run_check_bare`
      supports an empty `TMPDIR` (its comment says so) but no test sets
      `check_tmpdir` empty, so a check that uses the current directory or
      `$HOME` in that case passes. A test can pin it without writing to `/tmp`
      by putting a recording `mktemp` shim on `PATH`. Severity medium. Also,
      `run_check` does not set `TMPDIR`, so "`--scratch-parent` beats `TMPDIR`"
      is tested only if the caller's own environment happens to set it.

- [ ] **`tester`** — "a relative scratch parent gives an absolute scratch
      directory", `tests/unit/storage-round-trip.test.sh` line 789.
      **Scenario:** `run_check` states `--scratch-parent "$work/scratch"` first
      and the test adds `--scratch-parent scratch` with the current directory
      `$work`; both name the same directory, so a check that ignored the
      relative value and kept the first one, or resolved it against the wrong
      directory into the same place, passes. Use a relative directory distinct
      from the default (as the `chosen`, `from-env` and `-` tests do).
      Severity low.

- [ ] **`tester`** — "nodes are confined to localhost", the publisher and
      reproducer `assert_lacks ... "--bootstrap-node="`.
      **Scenario:** a publisher started with `--bootstrap-node SPR` (value as a
      separate argument) passes, because only the `=` form is searched for;
      `--no-bootstrap-node` does not contain `--bootstrap-node`, so searching for
      that bare string would work. Severity low. The fetcher's side is tight.

- [ ] **`tester`** — requirement "The check is a POSIX sh program", scenario
      "Run by a POSIX shell that is not bash".
      **Scenario:** `sh tests/run.sh` runs the check with whatever `sh` is; on
      this machine that is bash, so the default run never exercises a non-bash
      shell. `sh tests/run.sh "busybox sh"` passes (71 of 71), but nothing runs
      it by default or says `nix run .#test` does. Make the suite run the
      check under `busybox sh` or `dash` when present, or the scenario is
      covered only when someone remembers the argument. Severity low. The
      clause about GNU-only and BSD-only options is not observable by the unit
      suite on Linux; it belongs to the macOS layer, which is not in this
      change.

- [ ] **`tester`** — `NO SPEC:` markers. `grep -rn "NO SPEC" tests` finds only
      the header comment explaining the convention: no test carries one, yet the
      tests pin choices no scenario states. Mark each with `NO SPEC: <choice>`:
      the `--api-port=N` / `--listen-port=N` `=` form (the spec writes `=` only
      for `--nat` and `--listen-ip`); the order of sha256 calls in
      `tests/unit/broken-sha256/sha256sum` (first the test content, second the
      fetched content); a positive `--max-time` on every request ("every
      request carries a time limit", whose own comment says "Not in a
      scenario"); the total of exactly 4 uploads in "every upload states the
      pinned mimetype" (publisher, reproducer and the two changed-value
      uploads);
      `--scratch-parent` stated twice with the later one winning (below).
      Severity low.

- [ ] **`spec-writer`** — requirement "The command line is one operand and one
      option": the form is `[--scratch-parent DIR] [--] STORAGE_CLI`, and the
      spec is silent on a repeated `--scratch-parent`.
      **Scenario:** `run_check` always passes `--scratch-parent "$work/scratch"`
      and the six tests that choose another parent add a second
      `--scratch-parent`, so every one of them depends on the later value
      winning. A check that rejected the repeat, or took the first, would fail
      those tests with no scenario saying which behaviour is right. State the
      rule (later wins, or repeat is an error) and the tests can drop the
      workaround. Severity low.

- [ ] **`spec-writer`** — scenario "Reserved ports are occupied", requirement
      "Ports are chosen explicitly".
      **Scenario:** as written the scenario ("another process holds TCP 8080,
      TCP 8500 and UDP 8090 while the check runs against a working storage CLI")
      cannot be observed by the unit layer, whose stub binds nothing; the unit
      suite pins only the cause (no stated port is 8080, 8090 or 8500). It is
      testable only in the integration layer against a real node. Say so in the
      scenario, or restate it as the checkable consequence. Spec defect, not a
      coverage gap. Severity low.

- [ ] **`spec-writer`** — requirement "Nodes start within a bounded wait" and
      scenario "Publisher is gone": "after a bounded time".
      **Scenario:** the unit suite cannot observe elapsed time for a stub that
      answers at once, so "bounded" is pinned only by the stub curl seeing a
      positive `--max-time` and by a fast `sleep` shim. The spec gives no bound
      (seconds, or "a time limit on every request"), so the tests assert
      "positive". If the spec wants a number, give it; if not, say
      "a time limit is set" so the test is exactly the requirement. Severity
      low.

## Clean

- **Every scenario has a test** except those above: "Reserved ports are
  occupied" (no direct test; spec defect above), "Run by a POSIX shell that is
  not bash" (only by hand), and the `/tmp` branch of "Scratch parent from the
  environment". Layers are right: everything the spec describes beyond the
  real network is observable at the unit layer, and the stubs record what the
  check sent rather than honouring it.
- **Expected values are independent of the implementation.** The result lines
  are compared with the CID the stub recorded and a sha256 taken by the test
  from the file the check wrote; the manifest mismatch bodies are hardcoded and
  differ from a matching one in exactly one value; the stub CID is derived from
  the upload's filename, block size, mimetype and bytes, so the reproduce and
  changed-value tests compare things the upload decided. The two-broken-digest
  tests close the "equal empty digests" hole.
- **Failure paths** each assert non-zero, a step name on standard error and no
  `cid=` line; the node-start, SIGTERM, SIGINT and ignored-SIGTERM tests are
  sound and no node is left after any test.
- **Requirements that moved between capabilities:** none; the change adds one
  capability and removes nothing.
- **Spec against issue #2** (`gh issue view 2`): the spec states nothing the
  issue no longer states. It goes beyond the issue (mimetype, scratch parent,
  reserved ports, the changed-value CID checks); these are refinements of
  "pinned filename and block size", not stale scope.
- `tests/unit/storage-round-trip.test.sh` "a bare name is not looked up on
  PATH" assumes the current directory holds no file called `storage`; running
  the suite from `tests/unit/stubs` would break it. Not worth a box.

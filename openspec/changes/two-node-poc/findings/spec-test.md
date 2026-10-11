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

- [x] **`tester`** — "the fetcher starts empty, fetches by CID without
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
      **Outcome (`tester`): fixed.** `tests/unit/stubs/storage` now writes a
      marker file into its data directory after recording what the directory
      held, so a directory a node shares with an earlier one is not empty at
      start; and the new test "each node is given a data directory of its own"
      compares the three `--data-dir=` values. Predicted and observed: with the
      check changed so every node gets the publisher's `data` directory, "the
      fetcher starts empty ...", "the reproduction node starts empty and never
      fetched" and "each node is given a data directory of its own" fail, and
      nothing else does (mutant 1 of the run; your mutation 1 survived before).

- [x] **`tester`** — "the fetcher starts empty, fetches by CID without
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
      **Outcome (`tester`): fixed**, by the first of your two shapes. The stub
      curl logs every request made while the stub fetcher listens
      (`requests-while-fetcher-up`); the test now asserts the log holds
      requests to the fetcher's port (so the log works) and none to the
      reproducer's. Predicted and observed: with `stop_node "$fetcher_pid"`
      deleted, that test fails, and so does "SIGTERM during the stop of a node
      still leaves no node behind" (its stop never starts); nothing else.

- [x] **`tester`** — requirement "Fetched content is verified against the
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
      **Outcome (`tester`): fixed**, both cases, with a new shim
      `tests/unit/fixed-sha256/sha256sum` that prints one hardcoded digest for
      every call, and a different hardcoded one for the second call under a
      knob. Tests: "equal digests do not hide a fetched content that differs"
      (with `fetch-corrupt`; asserts the byte-for-byte diagnostic),
      "identical bytes do not hide a digest that differs" (asserts the
      hardcoded expected and actual digests, no byte diagnostic, and that the
      bytes are equal) and "equal digests and identical bytes pass" (the shim
      itself does not fail a run). Predicted and observed: with the `cmp` call
      deleted only the first fails; with the digest comparison deleted the
      second fails, and so does "fetched content differs" (its diagnostic
      assertions on the digests). `NO SPEC:` marked, on the shim and on the
      broken-sha256 tool: they depend on the fetched content's digest being the
      second call, which the spec now puts outside the capability. Task 4.4 and
      `design.md`'s `cmp` guard row say no test shows this; that is now stale
      (`dev-writer`'s to prune).

- [x] **`tester`** — requirement "A REST port that already answers is
      refused": "Before starting a node ... the REST API port that node is to
      be given" (every node).
      **Scenario:** only the publisher's and the fetcher's ports are tested. A
      check that probes the publisher and fetcher but not the reproducer's
      port passes. Also, the stub's foreign server always answers 200
      (`reply 200`); a typical foreign server answers 404 or 401 on
      `/`, and "answers" is not shown to include those. Severity medium.
      **Not measured.**
      **Outcome (`tester`): fixed.** The stub curl gained `foreign-after-fetch`
      (a server on the port of the node after the fetcher) and
      `foreign-status`. Tests: "a foreign server on the reproducer's REST port
      is refused" and "a foreign server answering HTTP 404 / 401 on the
      publisher's REST port is refused". Predicted and observed: with the probe
      skipped for the reproducer only the first fails; with the probe made to
      require HTTP 200 only the 404 and 401 tests fail.

- [x] **`tester`** — requirement "The caller chooses where the scratch
      directory is made": "and under `/tmp` otherwise".
      **Scenario:** no test runs with `TMPDIR` unset or empty. `run_check_bare`
      supports an empty `TMPDIR` (its comment says so) but no test sets
      `check_tmpdir` empty, so a check that uses the current directory or
      `$HOME` in that case passes. A test can pin it without writing to `/tmp`
      by putting a recording `mktemp` shim on `PATH`. Severity medium. Also,
      `run_check` does not set `TMPDIR`, so "`--scratch-parent` beats `TMPDIR`"
      is tested only if the caller's own environment happens to set it.
      **Outcome (`tester`): fixed.** `run_check_bare` can now leave `TMPDIR`
      unset, and a recording `mktemp` shim (made at test time, redirecting a
      `/tmp/` template into the test's own directory) shows the template the
      check asked for. Tests: "the scratch directory is under /tmp when TMPDIR
      is not set" and "... when TMPDIR is empty" (both also run from an empty
      directory), and "--scratch-parent beats TMPDIR" (which now sets `TMPDIR`
      itself). Predicted and observed: `${TMPDIR:-/tmp}` changed to
      `${TMPDIR:-.}` fails the two `/tmp` tests; changed to `${TMPDIR-/tmp}`
      fails only the empty one; `--scratch-parent` made to yield to `TMPDIR`
      fails only "--scratch-parent beats TMPDIR".

- [x] **`tester`** — "a relative scratch parent gives an absolute scratch
      directory", `tests/unit/storage-round-trip.test.sh` line 789.
      **Scenario:** `run_check` states `--scratch-parent "$work/scratch"` first
      and the test adds `--scratch-parent scratch` with the current directory
      `$work`; both name the same directory, so a check that ignored the
      relative value and kept the first one, or resolved it against the wrong
      directory into the same place, passes. Use a relative directory distinct
      from the default (as the `chosen`, `from-env` and `-` tests do).
      Severity low.
      **Outcome (`tester`): fixed.** The test now uses a relative directory
      distinct from the default and asserts the default parent gained nothing;
      "a scratch parent given with --scratch-parent ..." gained the same
      assertion, which is scenario "Option given twice". Predicted and
      observed: a check where the first `--scratch-parent` wins fails both of
      them (and, as expected, the four other tests that rely on the later
      value winning).

- [x] **`tester`** — "nodes are confined to localhost", the publisher and
      reproducer `assert_lacks ... "--bootstrap-node="`.
      **Scenario:** a publisher started with `--bootstrap-node SPR` (value as a
      separate argument) passes, because only the `=` form is searched for;
      `--no-bootstrap-node` does not contain `--bootstrap-node`, so searching for
      that bare string would work. Severity low. The fetcher's side is tight.
      **Outcome (`tester`): fixed.** The two assertions search for
      `--bootstrap-node` without the `=`. Predicted and observed: with the
      publisher started with `--no-bootstrap-node --bootstrap-node` only
      "nodes are confined to localhost" fails.

- [x] **`tester`** — requirement "The check is a POSIX sh program", scenario
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
      **Outcome (`tester`): fixed for the shell clause; the option clause is
      deferred to the macOS layer, as you say.** `tests/run.sh` now also runs a
      full pass and a failed run under `dash` and under `busybox sh`, whichever
      is installed and is not already the shell under test ("a full pass under
      busybox sh", "a failed run under busybox sh leaves no node behind"); a
      missing one prints a `skip` line. `dash` is not installed here, so only
      busybox ran. Predicted and observed: with an array assignment
      (`a=(1 2)`, which ash and dash reject) added to the check, both busybox
      tests fail and the rest of the suite, run by bash, passes. `nix run
      .#test` does not exist in the tree, so what it runs is not stated.

- [x] **`tester`** — `NO SPEC:` markers. `grep -rn "NO SPEC" tests` finds only
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
      **Outcome (`tester`): fixed, and four of the five choices are no longer
      unspecified.** The `=` form, the positive `--max-time`, the four uploads
      and the repeated `--scratch-parent` are now requirements, with scenarios,
      so they take no marker (and there is a test for each: "every valued
      option is one --name=value argument", "every request carries a time
      limit", "a full pass makes four uploads, one to the publisher and three
      to the reproducer", the two scratch-parent tests above). The fifth, the
      order of sha256 calls, is outside the capability, and is marked
      `NO SPEC:` in `tests/unit/broken-sha256/sha256sum`, in the new
      `tests/unit/fixed-sha256/sha256sum` and on "sha256 tool fails on the
      fetched content". The two markers the `dev-writer` left (the `STORAGE_`
      line that cannot be removed; the peer record that is not one) were on
      tests that are kept; the spec-writer has since made both requirements,
      so I replaced each marker with a citation of the requirement and
      scenario, which is what the convention asks once the spec speaks. Report:
      `grep -rn "NO SPEC" tests` now finds only the sha256 order and the
      header convention.

- [x] **`spec-writer`** — requirement "The command line is one operand and one
      option": the form is `[--scratch-parent DIR] [--] STORAGE_CLI`, and the
      spec is silent on a repeated `--scratch-parent`.
      **Scenario:** `run_check` always passes `--scratch-parent "$work/scratch"`
      and the six tests that choose another parent add a second
      `--scratch-parent`, so every one of them depends on the later value
      winning. A check that rejected the repeat, or took the first, would fail
      those tests with no scenario saying which behaviour is right. State the
      rule (later wins, or repeat is an error) and the tests can drop the
      workaround. Severity low.
      **Outcome (`spec-writer`): fixed.** The last value wins and a repeat is
      not an error: new requirement "A repeated option takes its last value",
      with scenario "Option given twice". This is what the check
      does today, so no code change follows; the tests' second
      `--scratch-parent` is now specified behaviour, not a workaround, and
      needs no `NO SPEC:` marker.

- [x] **`spec-writer`** — scenario "Reserved ports are occupied", requirement
      "Ports are chosen explicitly".
      **Scenario:** as written the scenario ("another process holds TCP 8080,
      TCP 8500 and UDP 8090 while the check runs against a working storage CLI")
      cannot be observed by the unit layer, whose stub binds nothing; the unit
      suite pins only the cause (no stated port is 8080, 8090 or 8500). It is
      testable only in the integration layer against a real node. Say so in the
      scenario, or restate it as the checkable consequence. Spec defect, not a
      coverage gap. Severity low.
      **Outcome (`spec-writer`): fixed by removing the scenario.** Its
      checkable consequence was already stated twice: scenario "Ports passed to
      each node" (no stated port is 8080, 8090 or 8500) and scenario "Request
      target" (every request goes to a port the check gave a node). Nothing
      automated runs the check against a real node with those ports held, so
      the Purpose now lists "the check's result while another process holds a
      reserved port" as outside the capability.

- [x] **`spec-writer`** — requirement "Nodes start within a bounded wait" and
      scenario "Publisher is gone": "after a bounded time".
      **Scenario:** the unit suite cannot observe elapsed time for a stub that
      answers at once, so "bounded" is pinned only by the stub curl seeing a
      positive `--max-time` and by a fast `sleep` shim. The spec gives no bound
      (seconds, or "a time limit on every request"), so the tests assert
      "positive". If the spec wants a number, give it; if not, say
      "a time limit is set" so the test is exactly the requirement. Severity
      low.
      **Outcome (`spec-writer`): fixed; the spec gives no number.** The Purpose
      now defines "bounded" (a limit fixed in the check, ending without outside
      action) and says the number of seconds is not part of the contract. New
      requirement "Every request carries a time limit" (`--max-time` greater
      than zero on every `curl`), scenario "Request time limit", is exactly
      what the test asserts, so the tester's "positive `--max-time`" marker in
      the entry above is no longer a `NO SPEC:` choice. Scenarios "Node never
      becomes ready" and "Publisher is gone" now say the check exits non-zero
      without being signalled, the second "no later than the fetch request's
      time limit allows".

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

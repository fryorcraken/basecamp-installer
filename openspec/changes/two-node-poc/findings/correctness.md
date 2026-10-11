# Findings: correctness

Dimension covered: correctness only (the prompt named it). Security,
readability and architecture are other instances.

Method: read `tests/integration/storage-round-trip.sh` against the spec; ran
`sh tests/run.sh` under `sh` (bash), `busybox sh` and dash 0.5.13.2 (71 tests,
0 failed each); reproduced one interrupt race by hand; ran seven mutants.
The overlay names no mutation tool for POSIX shell, so the mutants were made by
hand, on copies of `tests/` under `tmp/` (an edit of the tracked check in this
tree was refused by the permission checker, and was not worked around). The
real-node runs the design records could not be repeated: no built storage CLI
is available here.

- [x] **`dev-writer`** — `tests/integration/storage-round-trip.sh:68-75` —
      `stop_node` forgets a node before the node is dead, so a signal that
      arrives while it waits lets the check exit with the node still running.
      **Scenario:** the fetcher is being stopped after the fetch (`stop_node
      "$fetcher_pid"` in `main`); lines 70-73 drop its pid from `node_pids`, then
      `wait "$1"` is interrupted by `SIGTERM`; the trap exits 143 and `cleanup`
      walks a `node_pids` that no longer holds the fetcher, so it is neither
      waited for nor killed by the check. The spec requirement "No node outlives
      the run" says the check stops every node before it exits, on `SIGINT` and
      `SIGTERM` too.
      **Measured:** by hand, with the stub fetcher set to ignore `SIGTERM` and
      `SIGTERM` sent to the check two seconds into that stop: the check exited
      143 and the fetcher process was still running at that moment; it was gone
      only about ten seconds later, killed by the orphaned watchdog subshell
      after the check had gone. With a real node, which exits on `SIGTERM` in
      under a second, the window is short and the node usually dies on its own;
      with a node that ignores the signal the violation lasts `STOP_TIMEOUT`.
      **Severity:** low, genuine defect. The fix is to drop the pid from
      `node_pids` only after `wait` returns.
      **Fixed** in `4df3bd3`: `stop_node` calls `forget_node` after `wait`
      returns, and `cleanup` ends the interrupted stop's watchdog before it
      stops the node again. Test "SIGTERM during the stop of a node still
      leaves no node behind", watched failing before the fix ("stub node … is
      still running") and passing after, under `sh` and `busybox sh`.

- [x] **`dev-writer`** — `tests/integration/storage-round-trip.sh:169-181` —
      the readiness bound counts loop iterations, not seconds, so the diagnostic
      "not ready after 30 seconds" can be wrong by a factor of three.
      **Scenario:** a node that is running and accepts the TCP connection but
      never answers the `/spr` request: each iteration waits up to the
      2-second `--max-time` of `rest` plus the 1-second `sleep`, so 30 iterations
      take up to 90 seconds (derived from the constants, not measured), and
      the message still says 30. The wait is bounded, so the spec requirement
      holds; the message is false, and a caller that sets its own timeout from
      it is misled.
      **Severity:** low, cosmetic-to-genuine; either count real time or word the
      message as a number of attempts.
      **Fixed** in `4df3bd3`: the bound is `START_ATTEMPTS`, and the diagnostic
      reads "not ready after N attempts, which is at most M seconds", M worked
      out from the constants. Counting real time was not taken: POSIX `sh` has
      no clock (`design.md`, "The bounds, and what would move them"). Test
      "node never becomes ready" now compares the number in the diagnostic
      with the readiness requests the stub curl recorded; watched failing
      against the old "after 30 seconds" wording.

- [x] **`tester`** — `tests/integration/storage-round-trip.sh:373` — mutation
      survivor: deleting `stop_node "$fetcher_pid"` (the stop right after the
      fetch) leaves all 71 unit tests passing.
      **Scenario:** the fetcher then stays up through verification and the whole
      reproduction, and is stopped only by `cleanup` at exit. The spec says the
      check MUST stop it "once the fetch has ended"; the test "the fetcher
      starts empty, fetches by CID without advertising, and is stopped" only
      sees that it is gone when the check has exited, which `cleanup` also
      guarantees.
      **Measured:** 71 of 71 tests pass under this mutation (mutant run on a copy
      of `tests/` under `tmp/`).
      **Severity:** a test gap, not a code defect.
      **Outcome (`tester`): fixed**, the same gap as the spec-test entry on the
      fetcher's stop: "the fetcher starts empty, fetches by CID without
      advertising, and is stopped" now asserts no request reached the
      reproducer while the stub fetcher still listened. Observed failing with
      `stop_node "$fetcher_pid"` deleted (it and "SIGTERM during the stop of a
      node still leaves no node behind" fail; nothing else).

- [x] **`tester`** — `tests/integration/storage-round-trip.sh:94` — mutation
      survivor: deleting `kill "$request_pid"` from `cleanup` leaves all 71
      tests passing.
      **Scenario:** a `SIGTERM` that arrives while a request is in flight (the
      60-second fetch is the long one) leaves that `curl` running after the
      check has exited, still holding its output file in the scratch directory
      and for up to its `--max-time`. The two interrupt tests send the signal
      while the node is still starting and `curl` returns at once on a refused
      connection, so no test has a request in flight when the signal arrives.
      **Measured:** 71 of 71 tests pass under this mutation (mutant run on a copy
      of `tests/` under `tmp/`).
      **Severity:** a test gap; the behaviour it guards (the design's "curl runs
      in the background" decision) is a stated reason for the structure.
      **Outcome (`tester`): fixed.** New stub curl knob `fetch-hangs`: the
      download request stays alive, keeps a witness file `request-running`,
      and removes it when sent `SIGTERM`. Test "SIGTERM during a request leaves
      no request running" sends `SIGTERM` once the witness exists and waits up
      to five seconds for it to go. Predicted and observed: with
      `kill "$request_pid"` deleted from `cleanup`, that test and no other
      fails.

## Areas that held

- **Argument and tool handling.** `--`, a hyphen-led operand, a missing option
  value, a bare name (prefixed `./`), an empty scratch parent and a scratch
  parent named `-` all behave as the spec says; tool checks run before the
  scratch directory exists.
- **Verification fails closed.** An unparsable manifest, a missing filename or
  mimetype, a sha256 tool that prints nothing or fails, a short stream (curl
  exit 18) and a non-200 answer are each a failure at the named step. Mutants
  that removed the curl-exit check, the HTTP-status check or the sha256 length
  check were each caught by a test (3 of 3).
- **Portability of the shell.** The suite passes under bash, busybox ash and
  dash 0.5.13.2, including the early-exit detection with `kill -0` that
  `design.md` records as "not seen with dash": it passes there.
- **Process handling in the normal paths.** A failing run that cleans up a
  cooperative node exits in about one second under all three shells; a node
  that ignores `SIGTERM` is killed by the watchdog.
- **Result output.** Standard output holds only the five lines on a pass; every
  diagnostic goes to standard error.
- **Payload.** 10000 lines of 35 bytes is 350000 bytes, more than one block of
  131072 and not a whole number of them.

## Not covered

- The real-node behaviour (REST routes, option names, CID values) rests on the
  runs recorded in `design.md`; they were not repeated here.
- macOS and BSD userland were not run. Reading the check found no GNU-only
  option (`sed`, `wc`, `mktemp`, `kill`, `awk`, `cmp` are used in forms the BSD
  variants accept).

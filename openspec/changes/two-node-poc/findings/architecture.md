# Architecture review: two-node-poc

Dimension covered: **architecture** only (the prompt named it). Judged against
"How to shape a change" in `CLAUDE.md`. Nothing here is a correctness or
security defect; every entry is a maintainability finding, and each says whether
it is a genuine departure from the rules or a preference.

- [x] **`dev-writer`** — `tests/integration/storage-round-trip.sh:142-182` — `start_node` does four jobs and hides two of them behind its name. **Genuine departure** from "one function, one job" and "a guard is a job".
      **Scenario:** one body creates the node's directories, runs the "nothing already answers on this port" guard, launches the process and polls for readiness; its own header comment joins two of them with "and waits". The next change that touches any one (a second guard, a different readiness signal, a data-directory option) edits a function whose other three jobs it must re-read, and "is the port guard run for every node?" can only be answered by reading the whole body. Split into `require_port_free NAME PORT`, the launch, and `wait_until_ready NAME PID PORT`; `start_node` then reads as the three calls in order.
      **Severity:** low. **Measured:** the 71 unit tests pass as is, so the split is a pure refactor with a gate behind it.
      **Fixed** in `e2d3bbb`, a refactor commit on which the suite is green: `start_node` is `require_silent_port`, `launch_node` and `wait_until_ready` in that order. One ordering changed with it: the port is probed before the node's directory is made, so a refused port leaves no empty directory. No test fails without a refactor; the guard's own test is "a foreign server on the publisher's REST port is refused".

- [x] **`dev-writer`** — `tests/integration/storage-round-trip.sh:142-166,371` — `start_node` takes its arguments two ways and hands its result back through an unnamed global. **Genuine, minor.**
      **Scenario:** `$1` and `$2` are copied to `node_name`/`node_api_port` on entry, but `$3` and `$4` are used in place 20 lines later, after the reader has been told the parameters were named; `$4` is a single option string that is quoted but could be empty. The pid comes back as `started_pid`, which `main` copies to `fetcher_pid` on the very next line; for the other two nodes it is never read. A future caller that calls `start_node` twice before reading `started_pid` gets the second pid with no error.
      **Fix shape:** name all four parameters on entry, and either return the pid in a variable named for the node or drop it, since `stop_node` is the only consumer and the fetcher is the only node stopped by pid.
      **Severity:** low.
      **Fixed** in `e2d3bbb` for the parameters: `launch_node` and `wait_until_ready` name every one on entry. **Rejected** for the pid's shape: it cannot be dropped, because the fetcher is stopped by it, and a variable named for the node needs `eval` or a per-node `case` in POSIX `sh`. It is now `last_started_pid`, and `start_node`'s header says it holds only until the next start and that a caller copies it at once, which `main` does on the next line.

- [x] **`dev-writer`** — `tests/integration/storage-round-trip.sh:68-73` — `stop_node` also deregisters the pid from `node_pids`, and nothing says why. **Missing "why" comment.**
      **Scenario:** a reader sees a stop function rewrite a list and asks whether it can be dropped. It cannot: `cleanup` would stop the fetcher a second time, and `kill` on a reaped pid can signal an unrelated process that was given the number since. The header comment says "ends one node and reaps it" and is silent on both the deregistration and the reason, which is what a later edit to `cleanup` would break.
      **Severity:** low. Comment, or move the deregistration into its own `forget_node` so the name carries it.
      **Fixed** in `e2d3bbb`: `forget_node`, with a header that gives the reason (a reaped pid may be reused). `4df3bd3` then moved the call to after `wait`, for the correctness finding on the same lines; the reasoning is in `design.md`, "Process handling".

- [x] **`dev-writer`** — `tests/integration/storage-round-trip.sh:301-349` — the stage functions take their inputs from ambient state, so the data flow of `main` is invisible at the call sites. **Departure from "pass what it needs; do not reach for ambient state"; preference-strength for a one-shot script.**
      **Scenario:** `check_manifest` reads `$cid` and `PUBLISHER_API_PORT`, `fetch` reads `$cid` and `FETCHER_API_PORT`, `verify_fetched` reads `$fetched`, `$payload` and `$payload_sha256`, `check_cid_reproduces` reads `$cid`. `main` shows `fetch` followed by `verify_fetched` and nothing says that the first writes the file the second reads, or that `sha256_of` leaves its answer in a variable named `sha256` that `verify_fetched` then compares with `payload_sha256`. Reordering two lines of `main` (verify before fetch) fails only at run time, as "cannot compute the sha256", which names the wrong cause.
      **Fix shape:** `check_manifest CID`, `fetch CID`, `verify_fetched FILE EXPECTED_SHA256`. The ports can stay constants.
      **Severity:** low.
      **Fixed** in `e2d3bbb` (refactor, suite green): `check_manifest CID`, `fetch CID OUT_FILE`, `verify_fetched FETCHED_FILE ORIGINAL_FILE EXPECTED_SHA256`, `check_cid_reproduces CID`, `check_cid_changes CID`; `main` names the fetched file and passes it to both. `sha256_of` still leaves its answer in `sha256`, because a function that may call `fail` cannot be used in a command substitution.

- [x] **`dev-writer`** — `tests/integration/storage-round-trip.sh:305-318` — `check_manifest` repeats one extract-and-compare shape three times, and the pinned values are listed again in `upload` and in the final `printf`. **The "fourth slightly-different copy" signal, at three.**
      **Scenario:** the spec already grew from two pinned values to three (the mimetype), and each growth cost another `sed` expression, another `[ ... ] || fail` and another edit to the result line. A fourth pinned value (the dataset size, say) is another copy of all three. The two numeric/string extractions differ only in the pattern. A helper `manifest_field KEY` plus a loop over the pinned name/value pairs makes "add a pinned value" one line, and puts the "none" fallback for a missing key in one place instead of two (`filename`, `mimetype`) with `blockSize` as a third, differently-handled case.
      **Severity:** low; **preference** until a fourth value is asked for, at which point it is the refactor-first commit.
      **Rejected** for this change, on the entry's own terms: `CLAUDE.md` says not to refactor speculatively, and no fourth pinned value is asked for. The three checks are also not one shape: an absent `blockSize` is "cannot parse" while an absent `filename` or `mimetype` is a mismatch reported as `none`, which the spec's scenarios distinguish. The helper is the refactor-first commit of the change that adds a value.

- [x] **`dev-writer`** — `tests/integration/storage-round-trip.sh:336-349` — `check_cid_reproduces` and the two halves of `check_cid_changes` are the same upload-then-compare three times, with the sense of the comparison and the step name as the only differences. **Preference.**
      **Scenario:** one helper, `expect_cid STEP same|different FILENAME BLOCK_SIZE`, would hold the diagnostic wording once. Today the three messages have drifted in shape ("the CID does not reproduce: recorded X, re-upload returned Y" against "changing the filename to F still returned the recorded CID X"), which is harmless but is the first sign of copies diverging.
      **Severity:** low.
      **Rejected.** The messages differ because the spec asks for different things: "CID does not reproduce" must state both CIDs, "A changed value gives the recorded CID" must name which value was changed. One helper would take the sense, the step and the wording as parameters, which is the three call sites again with a `case` added. The shared part, upload and validate the CID, is already one function, `upload`.

- [x] **`dev-writer`** — `tests/integration/storage-round-trip.sh:290-299` — `read_publisher_spr` validates with a three-arm `case` whose middle arm is a no-op and sets the same variable empty twice, and carries no comment saying why the character set is restricted.
      **Scenario:** a reader cannot tell whether `spr:?*) ;;` is a mistake or the pass case, nor why base64url is the allow-list. The reason (the value becomes an argument on the fetcher's command line, so it must not be able to carry an option or a space) is only in `design.md`'s guard table, which the design itself says no test turns red for. Collapse to one rejecting pattern, `'' | spr: | spr:*[!A-Za-z0-9_=-]*) publisher_spr= ;;`, and state the reason in one line.
      **Severity:** low. **Preference** on the `case`; the missing comment is the genuine part, because this is a guard no test would catch being loosened.
      **Fixed** in `e2d3bbb`: one rejecting arm over the record's body, and a header giving the reason. The reason stated is not the one in this entry: the value is one quoted word and cannot carry an option; what the guard prevents is a fetcher started on an unusable bootstrap node and a failure blamed on the fetch. `4df3bd3` adds the test, "a publisher answer that is not a peer record is refused", watched failing with the character check removed.

- [x] **`dev-writer`** — `tests/integration/storage-round-trip.sh:90-99` — `cleanup` ignores `INT` and `TERM` for its whole run and re-exits with the saved status, and neither choice is explained. **Missing "why" comment.**
      **Scenario:** `trap '' INT TERM` means a second Ctrl-C during the up-to-`STOP_TIMEOUT`-per-node wait is swallowed, so a user who thinks the check hung has no way out but `SIGKILL`, and leaves nodes running. That may be exactly the intent (finish stopping the nodes), but a maintainer reading it will either "fix" it or copy it. One line saying which it is.
      **Severity:** low.
      **Fixed** in `e2d3bbb`: `cleanup`'s header says the signals are ignored on purpose, so a second Ctrl-C cannot leave a node running, and why it exits with the saved status. Also in `design.md`, "Process handling". A comment; no test.

- [x] **`tester`** — `tests/run.sh:11-12` and `tests/unit/storage-round-trip.test.sh:5` — blanket file-level `shellcheck disable=SC2034` / `SC2154` hide every unused or unassigned variable in the whole file, not just the handful this split needs. **Genuine, minor; the lint gate is blind to what it was disabled for.**
      **Scenario:** `run.sh` assigns `stub_cli`, `scratch`, `repo` and others that only the sourced file reads, and the sourced file reads variables only `run.sh` assigns, so both directives are needed. But a typo such as `scrach=` in either file, or a dropped assignment in `begin`, is now invisible to `shellcheck`, which is the one static check the overlay's Test layers row relies on for these files. Replace with per-line disables on the few assignments, or with a single `: "$stub_cli" "$scratch" ...` use-site line that names the cross-file variables, so the directive's scope equals the intent.
      **Severity:** low. **Measured:** `shellcheck` is not installed in this tree, so the claim that nothing else is hidden was not run; the suite itself passes, 71 tests.
      **Outcome (`tester`): deferred.** Narrowing a lint directive can only be
      checked by running `shellcheck`, which is not installed in this tree and
      which I was not to run (no `nix`); an edit I cannot lint could make the
      lint gate fail or, worse, hide more. Where: the next session with
      `shellcheck` (`nix run .#lint`, or `shellcheck --shell=sh -x tests/run.sh
      tests/unit/*.sh`), which should first try the directives removed
      altogether, since `-x` follows `# shellcheck source=` and may already see
      the cross-file uses. This round added no new file-level directive.
      The new code in `tests/run.sh` and the test file was written to avoid
      unquoted expansions, but was not linted either.
      **Re-read in the last `tester` pass: still deferred.** `shellcheck` is
      still not among the commands this pass may run, so neither narrowing nor
      removing the directives can be checked. This pass added no directive,
      file-level or per-line: the three per-line `SC2086` disables (where
      `$shell_under_test` is deliberately word-split) stay on the lines that
      now call `under_stubs`, and none of the new code was linted. The next
      session with `shellcheck` should run `shellcheck --shell=sh -x
      tests/run.sh tests/unit/*.sh tests/unit/stubs/*` first with the two
      file-level directives deleted.
      **Settled by the `dev-writer`, with `shellcheck` 0.11.0
      (`nix run nixpkgs#shellcheck`): fixed.** Both file-level directives are
      deleted, and nothing replaces them at file level. What was measured:
      with both deleted, `shellcheck --shell=sh -x tests/run.sh` prints
      nothing, as the `tester` expected, but for a second reason nobody had
      seen: under `-x` alone the sourced test file is used for its assignments
      and reads and is not itself reported on. A misspelt `$scrach` planted in
      the test file, and `stub_cli` misspelt where the runner assigns it, gave
      one warning, `SC2034` on the runner's line; the two `SC2154` in the test
      file were silent. With `-a` (`--check-sourced`) added, all three were
      reported, and the test file's six `SC2016` notes with them. So the lint
      is now `-x -a` over the runner, and the test file is not named on the
      command line: named there, it is read without the runner and reports
      nine of the runner's variables as unassigned and four assignments as
      unused, which is the noise the directives were written for. The six
      `SC2016` are single-quoted source text of stand-in programs and take
      three per-line directives, one per `printf`. No test fails without
      this; what shows it is the lint with the two plants, run and then
      reverted. Suite after the edit: green under `sh` and under
      `busybox sh`. The reasoning is in `design.md`, "The test file is linted
      through the runner, with no file-level directive".

## Areas that were clean

- **Shape of the whole.** One check script, one runner, one stub CLI, one stub `curl`, one broken-digest tool; the integration layer is separate from the unit layer and the unit suite drives the real script unchanged (no test-only hooks in the shipped path). The check's step order lives in `main` alone, and `fail` is the single exit for a failure.
- **Data over logic where it counts.** The six ports and the pinned values are constants in one block, so "distinct and not reserved" is read off one place, and a test asserts it from the recorded command lines, not from the same constants.
- **Guards are separate functions.** `require_storage_cli`, `require_tools`, `create_scratch`, `parse_arguments` and the upload CID check each do one thing and are called from one place; "is it called everywhere?" has an answer.
- **No dependency added.** The check needs `curl`, `awk`, `sed`, `cmp`, `wc`, `mktemp` and a sha256 tool, all checked before any node starts; `design.md` records why `curl` and why no `jq`. Nothing to license.
- **Process handling is bounded and documented.** The watchdog in `stop_node`, the background `curl` with `wait`, and "never call `fail` in a command substitution" are each explained in `design.md` and in comments, and each is exercised by a named test.
- **CI.** `.github/workflows/` does not exist, so there is no gate measuring a moved path; `tests/run.sh` and `tests/integration/` match the overlay's Test layers rows. `tmp/` is ignored.
- **Stub coupling is deliberate.** The stubs assign roles by start order and the broken-digest tool by call number, which ties them to the check's step order; the stub headers say so, and a reorder fails loudly rather than silently, so no box is opened.

## What could not be measured

The overlay names no mutation tool for POSIX shell, and none was run. `dash`
and `shellcheck` are not installed here, so the suite was run only under the
default `sh`; the design records `bash` and `busybox sh` runs and says the macOS
`sh` and `dash` were not seen.

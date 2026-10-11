# Readability review: two-node-poc

Dimension covered: **readability** only (the prompt named it). Judged against
"How to shape a change" in `CLAUDE.md`: one function one job, comments say what a
command cannot, a repeated shape is a signal. Reviewed on the reworked code and
tests. Nothing below is a correctness or security defect, and I ran no code
(the brief forbade it), so every claim is from reading. Nothing from
`findings/architecture.md` is re-raised: the settled entries there (the
`start_node` split, the argument naming, `forget_node`, the stage functions'
ambient inputs, the three-way manifest check, the `cleanup` comment, the
`shellcheck` directive scope) are not repeated here.

Each entry says whether it is a **genuine** readability defect (a reader is
misled or must read elsewhere to answer an ordinary question) or a
**preference**. Counts are by hand from the files as read.

## For `dev-writer` (`tests/integration/storage-round-trip.sh`)

- [ ] **`dev-writer`** — `storage-round-trip.sh:158` — `rest_ok` reads `$rest_out`, a variable that appears nowhere in `rest_ok`. **Genuine, low.**
      **Scenario:** `rest_ok`'s header names `OUT_FILE` as its second parameter, and the body does `shift` and `rest "$@"`; line 158 then prints `see $rest_out`. A reader looking for where `rest_out` is set finds it only inside `rest` (line 132), whose header documents `rest_exit` and `rest_status` as results but not `rest_out`. Someone who edits `rest_ok` to take the file from `$2` directly, or renames `rest`'s locals, breaks the diagnostic with no error: `set -u` is on, so it would fail as "unbound variable" inside `fail`, which hides the real failure message.
      **Fix shape:** have `rest_ok` name its parameters on entry (`rest_ok_out=$2`) as the architecture round did for the node functions, or say in `rest`'s header that it leaves `rest_out` behind.

- [ ] **`dev-writer`** — `storage-round-trip.sh:136-138,168,213` and the messages at 156 and 212 — `curl-errors.log` is told to the reader as "the place to look" but holds expected refusals too. **Genuine, low.**
      **Scenario:** `rest` appends curl's `--show-error` text to one log for every request. `require_silent_port` runs once per node (3 times in a pass) and is meant to see "connection refused"; `wait_until_ready` polls until the node answers and every poll before that is a refusal. So a normal run leaves at least 3 refusal lines in the log. A failure message that says "see .../curl-errors.log" sends the reader to a file whose first lines are routine, and nothing says which lines are the failure. A reader who sees `Failed to connect ... port 28481` first blames the port that was supposed to be refused.
      **Fix shape:** one comment on `rest` saying the log mixes expected probes with real errors and the last line is the one a failure refers to; or send the probes' stderr elsewhere.

- [ ] **`dev-writer`** — `storage-round-trip.sh:76-82,89-105,176-198,200-222,316-325` — the convention that every function prefixes its variables is real but unstated, and not kept everywhere. **Genuine, low.**
      **Scenario:** POSIX `sh` has no `local`, so the file prefixes (`launch_name`, `ready_dir`, `rest_max`, `known_pid`). A new contributor copying `wait_until_ready` writes `name=$1` and silently overwrites a name some other function reads. The convention is not written down, and four unprefixed names break it: `attempts` (line 209), `manifest` (376, a global that `check_manifest` leaves for the diagnostic), `tool` (275) and `payload`/`payload_size` (328, 332, globals `main` and `verify_fetched` read). A reader cannot tell which unprefixed names are deliberate globals shared with `main` (`payload`, `payload_sha256`, `uploaded_cid`, `publisher_spr`, `last_started_pid`) and which are accidents.
      **Fix shape:** one comment above the first function: no `local`, so a function's variables carry its name; the globals that are results are listed (`rest_status`, `rest_exit`, `sha256`, `uploaded_cid`, `last_started_pid`, `publisher_spr`, `payload`, `payload_sha256`).

- [ ] **`dev-writer`** — `storage-round-trip.sh:13,183` — `umask 077` and `mkdir -m 700` both appear and neither says why. **Genuine "why" gap, low.**
      **Scenario:** `umask 077` already makes `mkdir` create `700` directories, so a reader sees `-m 700` on the data directory as either redundant or load-bearing and cannot tell which. If the storage CLI refuses a data directory with wider permissions, the `-m` is deliberate and a "cleanup" that drops it fails only against a real node, which the unit layer cannot see. If it is redundant, the next reader keeps it forever.
      **Fix shape:** one line at each: what the umask protects (the scratch directory and the logs it holds), and whether the node needs the explicit mode.

- [ ] **`dev-writer`** — `storage-round-trip.sh:332-333` — `payload_size=$((payload_size + 0))` has no comment. **Genuine "why" gap, low.**
      **Scenario:** the line looks like a no-op. It exists because BSD `wc -c` pads its answer with spaces (the overlay's Hazards names the GNU and BSD differences), which would break the later `-gt` and `%` only on macOS. A maintainer who removes it as dead code passes every Linux gate and fails on macOS. The stub `curl` has the same expression at its line 177 (`$((size + 0))`) without a reason either.
      **Fix shape:** one comment on the line.

- [ ] **`dev-writer`** — `storage-round-trip.sh:453` — nothing in `main` says why the fetcher is stopped there. **Genuine "why" gap, low.**
      **Scenario:** `stop_node "$fetcher_pid"` sits between `fetch` and `verify_fetched`. The reader asks whether it is cleanup, a precondition for verification, or a requirement (the spec's "ephemeral" fetcher). The comment on the reproducer (456-457) explains the reproducer and says nothing of the fetcher. The reason is that the fetcher must be gone before the reproducer starts, so the reproducer's equal CID cannot have come from a node that held the content. The test file carries it (lines 436-438); the script does not. Moving the call to the end, as `cleanup` would do anyway, passes the unit suite's no-node-left assertion and changes the experiment.
      **Fix shape:** one sentence above the call.

- [ ] **`dev-writer`** — `storage-round-trip.sh:444-445,459` — `main` copies `uploaded_cid` into `cid` with no word on why. **Genuine, low.**
      **Scenario:** `upload` leaves its result in `uploaded_cid`, and `main` then uses a differently named `cid` for the recorded one, which `check_cid_reproduces` compares with the next `uploaded_cid`. The two names are one letter-group apart and a reader reading line 414 (`[ "$uploaded_cid" = "$1" ]`) has to work out that `$1` is the older upload and `uploaded_cid` the newest. The copy is the whole point (the next upload overwrites the variable), and it is not said.
      **Fix shape:** a comment on `cid=$uploaded_cid`, or name it `recorded_cid`, the name the message at line 415 and the unit tests already use.

- [ ] **`dev-writer`** — `storage-round-trip.sh:379-384` — the manifest is parsed with `sed` on a JSON body and no comment says why that is safe or why not `jq`. **Preference, low.**
      **Scenario:** a reader sees three `sed` expressions pulling fields out of JSON, which the next person will "fix" with `jq` (not guaranteed on a stock desktop, and the shipped-file rule bars it). The reason (no `jq`, the manifest is one line and the keys appear once) is in `design.md`, which the file's header points to only in general. The assumption that the keys are unique and unnested is what the three expressions rest on, and nothing in the file states it.
      **Fix shape:** a two-line comment above the first `sed`: why no `jq`, and the assumption the patterns make.

- [ ] **`dev-writer`** — `storage-round-trip.sh:275` — the list of tools `require_tools` checks does not say what it is the list of. **Preference, low.**
      **Scenario:** the loop checks `curl awk sed cmp wc mktemp`. The script also runs `cat` (lines 143, 350, 363), `sleep` (218), `mkdir` (183), `env` (286, 292) and `kill`. A reader assumes the list is the script's dependencies and finds five missing; it is in fact the tools whose absence is plausible on a stock desktop, or the ones the author remembered. A tool that `PATH` lacks fails the run mid-way, not at the preflight the name promises.
      **Fix shape:** either a comment saying the list is the non-universal tools, or list them all.

## For `tester` (`tests/run.sh`, `tests/unit/`)

- [ ] **`tester`** — `tests/unit/storage-round-trip.test.sh:210` — `assert_lacks "$state/requests" "OFF-HOST"` can never fail, and reads as if it could. **Genuine, low; it is a dead assertion that misleads.**
      **Scenario:** the line implies the stub `curl` writes `OFF-HOST` into the request log for a request to another host. It does not: `tests/unit/stubs/curl` has no such string anywhere (read in full). An off-host URL makes the stub print "is not on 127.0.0.1" to standard error and answer `000` with exit 6, and the request is logged as an ordinary line. The assertion on line 211-212, which looks for a request line not starting `http://127.0.0.1:`, is what actually pins the property. A reader trusts line 210 as a second guard and removes the real one as "redundant", or leaves a marker nobody emits.
      **Fix shape:** delete line 210, or make the stub emit the marker and say so in its header.

- [ ] **`tester`** — `tests/run.sh:63-66,83-86` and `tests/unit/storage-round-trip.test.sh:929-931` — the environment the check is run under is written out three times, and the third differs silently. **Genuine, low; the "fourth slightly-different copy" signal at three.**
      **Scenario:** `run_check`, `run_check_bare` and `interrupt_check` each spell `PATH=$check_path STUB_STATE=$state STUB_REAL_SLEEP=$real_sleep ...`. The first two also pass `STUB_REAL_SHA256`; `interrupt_check` does not. A test that combines the broken or fixed sha256 tool with an interrupt fails with `STUB_REAL_SHA256 is not set` from inside the tool, which reads as a defect in the check. Adding one more stub variable is three edits, and the one in the test file is the one that is forgotten.
      **Fix shape:** the variable list in one place (an `export` in `begin`, or a function that runs a command under the stub environment).

- [ ] **`tester`** — `tests/unit/storage-round-trip.test.sh:413,414,433,439,473,577` — "the REST port of the Nth node" is extracted the same long way six times. **Genuine, low.**
      **Scenario:** each is `sed -n Np "$state/invocations" | tr ' ' '\n' | sed -n 's/^--api-port=//p'` (6 occurrences, counted by hand; five more whole-file variants at 303, 330, 337, 348 and 596 differ only in the output). The stub already writes `$state/args-publisher`, `args-fetcher` and `args-reproducer`, one argument per line, so `sed -n 's/^--api-port=//p' "$state/args-reproducer"` does the same and names the role instead of a line number. The numbered form ties each test to the start order silently: `3` means the reproducer, and a reader must know the order to read it.
      **Fix shape:** a helper in `run.sh`, `api_port_of ROLE`.

- [ ] **`tester`** — `tests/unit/storage-round-trip.test.sh:67-69,158-160,167-169,1029-1031,1097-1099,1129-1131,1207-1209,1221-1223,1265-1267` — `cd DIR || exit 2`, `run_check`, `cd "$repo" || exit 2` is written out 9 times (counted by hand). **Preference, low.**
      **Scenario:** each test that needs a working directory re-states both `cd`s, and a test that fails an assertion between them cannot leave the next test in the wrong directory only because the file has no `set -e`. A new test that forgets the second `cd` runs every later test from the wrong place, and `"$repo/tmp"`-relative assumptions fail far from the cause.
      **Fix shape:** `run_check_in DIR ARGUMENT...`, which runs in a subshell.

- [ ] **`tester`** — `tests/unit/storage-round-trip.test.sh:183-213` — "nodes are confined to localhost" also pins the bootstrap topology, so its name misleads on a failure. **Genuine, low.**
      **Scenario:** lines 190-196 and 204-208 assert that the publisher and reproducer have `--no-bootstrap-node` and that the fetcher has exactly one `--bootstrap-node` equal to the publisher's record. That is the topology requirement (tasks.md 2.2 cites this very test for it), not confinement. Someone who changes the bootstrap wiring sees "FAIL nodes are confined to localhost: the fetcher's bootstrap node is not the publisher" and looks at addresses. The same test also asserts the absence of `--network`, which is a third property.
      **Fix shape:** split out "the fetcher is bootstrapped from the publisher alone"; tasks.md 2.2 then cites the right test.

- [ ] **`tester`** — `tests/unit/storage-round-trip.test.sh:422-444` — "the fetcher starts empty, fetches by CID without advertising, and is stopped" is three tests in one body, named by an "and" list. **Preference, low.**
      **Scenario:** the body checks the empty data directory, the URL of the fetch, the order of the fetcher's first contact after the upload, and that the fetcher was gone before the reproducer was contacted. The name lists three; the order check (430-435) is a fourth and is not named. A failure at line 435 prints `FAIL ...: the fetcher was contacted before the upload` under a title about being empty and stopped, and the first `flunk` is the only one the title can be blamed for.
      **Fix shape:** split at the comments that already introduce each part (lines 430 and 436).

- [ ] **`tester`** — `tests/unit/stubs/storage:1-12,26-48` — the stub says it "records how it was invoked" and does not say what it writes or what the stub `curl` takes from it. **Genuine, low.**
      **Scenario:** the stub `curl`'s header lists every log it writes and every knob. The storage stub lists only its knobs. The files the tests read (`invocations`, `args-ROLE`, `environment-ROLE`, `data-dir-at-start-ROLE`) and the files the two stubs share (`role-PORT`, `listening-ROLE`, `pid-ROLE`, `pids`) are found only by reading the body, and the contract between the stubs (the storage stub marks a port listening, `curl` answers for it by looking up `role-PORT`) is split across two files with no sentence naming the other side's half. A change to one stub that renames a shared file breaks the other with `curl` answering "connection refused" for a running node, which reads as a failure of the check.
      **Fix shape:** a "Files written" list in the storage stub's header, matching the stub `curl`'s.

- [ ] **`tester`** — `tests/unit/storage-round-trip.test.sh:1-5` — the header says `run.sh` defines "begin, knob, run_check, the assertions and end" and omits the variables a test reads. **Preference, low.**
      **Scenario:** every test body reads `$work`, `$state`, `$scratch`, `$status`, `$stub_cli`, `$stubs`, `$tests_dir`, `$repo`, `$check_path`, `$shell_under_test` and `$real_sha256`, assigned in `run.sh`. The file disables SC2154 so none is flagged. A new test author copying one test learns the names by pattern. A typo in one (`$scrach`) is an empty string and `assert_contains "$scrach/..."` greps a path that does not exist, which `assert_contains` reports as a missing text, not as a mistake.
      **Fix shape:** list the ambient variables in the header, with `$status` and `$scratch` marked as "set by `run_check`".

## What I read and found clean

- **The shape of `main`.** It reads as the steps in order, with one function per step, and the guards (`require_storage_cli`, `require_tools`, `clear_storage_environment`, `create_scratch`, `read_publisher_spr`, the CID character check in `upload`) are separate and each called once, so "is it called everywhere?" has an answer.
- **The comments on the hard parts are good**: `stop_node` (why a watchdog, why `kill -0` cannot be used), `cleanup` (why the signals are ignored and the saved status re-exited), `rest` (why curl runs in the background), `fail` (never inside a command substitution), `clear_storage_environment` (the guard and the bind-address example), `read_publisher_spr` (the first pattern is the record itself), and the constant blocks (35 is odd; ports fixed and reserved; bounds in attempts and in seconds). These are "why this and not the obvious" comments, not restatements.
- **Naming of functions** is plain and verb-led, with no `handle` or `process`; the only function name with an `and` risk, `start_node`, is a three-call sequence after the architecture round.
- **Diagnostics** all follow `storage-round-trip: <step>: <message>` and name the file to read.
- **`tests/run.sh`** is short, its header says what the suite cannot see, and each helper has a header saying what it sets. `flunk` / `assert_*` / `end` are a consistent small vocabulary, and the first-failure-only bookkeeping in `flunk` is commented.
- **The test file** names the requirement or scenario above nearly every test, uses `NO SPEC:` where the spec is silent, and says in comments why each stub knob exists (for example the 90-second sleep, the fixed digest, "watched failing with the character check removed"). The broken and fixed digest tools state their order assumption as a `NO SPEC` in their headers.
- **The stub `curl`** documents every log and every knob at the top; the two copies of the "foreign server" reply block (lines 129-144) are three near-identical arms, but each carries its own reason in a comment, so I did not open a box.

## What was not measured

I ran nothing: the brief for this review forbade running tests, linters and
counting tools, so the counts above are by hand from the files as read and
`shellcheck` and `shfmt` results are unknown. The overlay names no mutation tool
for POSIX shell.

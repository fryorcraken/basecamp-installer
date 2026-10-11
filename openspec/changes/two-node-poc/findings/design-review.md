# Design review: two-node-poc

The recorded decisions are in good shape. I found no place where the code
contradicts one: the ports and the `--listen-ip`, `--nat` and bootstrap options
match the "Two ports" and "Three nodes" entries, the three-value pin and the
`sed` manifest parse match their entries, and the stop, `curl`-in-background
and `fail`-outside-substitution rules in "Process handling" are all in
`tests/integration/storage-round-trip.sh`. The departure from the issue (the
reproduction runs on a third node, and the mimetype is pinned as a third value)
is argued in `design.md`. The findings below are gaps and thin entries.

- [x] **`dev-writer`** — `design.md:270` the peer-record guard's "Without it" is
      overstated. It says whatever the publisher's REST port returned "becomes a
      command-line argument of the fetcher". The code (`storage-round-trip.sh:370`)
      builds `"--bootstrap-node=$publisher_spr"`, one quoted word, so the value
      cannot become a separate option or argument. The real cost is a garbage
      bootstrap value that makes the fetcher find no provider, and the failure is
      then blamed on the fetch step. Name that mechanism. The row also says "No
      test turns red", so this is a guard with no test behind it; say so as a gap,
      or add a test with a malformed record.
      **Fixed** in `d989ac4` (the row now names the mechanism: one quoted
      word, an unusable bootstrap node, a failure blamed on the fetch) and
      `4df3bd3` (stub knob `spr-body-ROLE` and the test "a publisher answer
      that is not a peer record is refused", watched failing with the
      character check removed). "a peer record with no body is refused" was
      not seen failing; the row says so.

- [x] **`dev-writer`** — `design.md` Guards table: a bounds decision is
      unrecorded. `START_TIMEOUT=30`, `REQUEST_TIMEOUT=30`, the 2-second
      readiness request and the 1-second poll (`storage-round-trip.sh:41-44,154,173`)
      are constants whose values matter, but Decisions explains only the 60 and
      the 10. The "Fetch is bounded twice" entry argues 60 against an observed 27
      seconds; no entry says why 30 suffices for a node to start, or that a slow
      CI runner is the thing that would force a change.
      **Fixed** in `d989ac4`: new Decisions entry "The bounds, and what would
      move them", one bullet per constant. The start bound became a number of
      attempts in `4df3bd3` and the 2 seconds a named constant in `e2d3bbb`.
      Documentation; no test.

- [x] **`dev-writer`** — `storage-round-trip.sh:148` each node's data directory
      is made with `mkdir -m 700`, and the check makes the node's own directory
      with plain `mkdir` under the 077 umask. Nothing in Decisions says whether the
      CLI requires a restrictive data directory or whether this is only the
      spec's no-group-or-other rule. If the CLI refuses a looser mode, that is a
      fact about the node worth one line; if not, say it is the spec's rule.
      **Fixed** in `d989ac4`: Decisions entry "A node's data directory is made
      with mode 700". Read from `storage/utils/fileutils.nim`,
      `checkAndCreateDataDir`: the node requires `0o700` and, given a looser
      directory, warns and tightens it itself rather than refusing.

- [x] **`dev-writer`** — `design.md` Guards table has no row for `sha256_of`
      (`storage-round-trip.sh:250-259`). It reads the digest from standard input,
      not the file name, so the tool prints no file name, and it accepts the
      output only if it starts with 64 hex digits. That is a choice with an
      alternative (trust exit status alone), and it has a purpose-built stub,
      `tests/unit/broken-sha256/sha256sum`, and tests ("sha256 tool …") named in
      `tasks.md` 4.3. Add the row, with whether those tests were watched red.
      **Fixed** in `d989ac4`: row added. Measured with the 64-digit test
      removed: "sha256 tool prints nothing for the test content" failed; the
      three other "sha256 tool …" tests stayed green, and the row says why.

- [x] **`dev-writer`** — `design.md` Guards table is missing guards the code and
      tests already carry, so the mutation evidence the format asks for is absent
      for them: `-q` and `--noproxy '*'` on every `curl` (the prose gives the
      reason, test "every request is made with -q first and --noproxy given *"
      exists, but no "without it" or red/not-red claim), the same pre-start probe
      on the fetcher's port (test at `storage-round-trip.test.sh:393`), and the
      SIGKILL watchdog (named test, but not marked watched red or not). Four
      rows that are in the table say "Test, not watched red" or "Nothing
      observable" (CID letters and digits, bare-name `./`, the `spr:` check,
      `cmp`). Where removing the guard is cheap to try, watch the test fail and
      say so; a guard pinned only by a test never seen failing was not shown to
      be pinned.
      **Fixed** in `d989ac4`: the table was re-measured whole, each guard
      removed from a copy of the check and the suite run under `sh` (bash).
      Rows added for `-q`/`--noproxy`, the fetcher's port probe and the
      watchdog, all watched red. Of the four named: bare-name `./` and the
      `spr:` check are now watched red; the CID character check and `cmp`
      turn nothing red, and their rows say so and point at the open `tester`
      entries. One row got worse on measurement: the empty-scratch-parent
      refusal is not pinned under bash, whose `cd ''` fails by itself.

- [x] **`dev-writer`** — `design.md:232` "a value with an escaped quote stops at
      the backslash" is wrong about the mechanism: `[^"]*` matches the backslash,
      so the captured value keeps it and stops at the quote. The outcome the
      entry claims (a mismatch, failing closed) is the same, but the sentence
      names a mechanism the `sed` expression does not have. Correct it.
      **Fixed** in `d989ac4`: the sentence now says the value is captured up
      to the quote, backslash included, and is a mismatch.

- [x] **`dev-writer`** — `storage-round-trip.sh:31-38` a trap that belongs where
      the next toucher of this file will look is only in the archived entry "Two
      ports per node, fixed in the program": the six ports are fixed, so two
      concurrent runs, or any other test that later picks a port in 28481-28486,
      collide and fail at node start. The constants block says the ports are
      distinct and not reserved, and nothing about concurrency. Add one line to
      the comment above the constants.
      **Fixed** in `e2d3bbb`: the comment above the six constants says that
      two runs at once, or another test picking a port from 28481 to 28486,
      collide.

- [ ] **`owner`** — `.claude/specflow/PROJECT.md` `## Hazards`, first bullet, and
      `## dev-writer` / `## spec-writer`: all say to pin the filename and block
      size. This change shows the CID also depends on `mimetype` (`design.md`
      "Why the mimetype is a pinned value"; the same bullet already names
      `mimetype` as part of the manifest). The next piece that produces a CID
      reads the overlay, not the archive, and would pin two of three. The overlay
      is the owner's, so this is a proposal, not an edit: reword "pin both" and
      the two role rules to name the mimetype as well. The hazard exists in
      `docs/DESIGN.md` already, but the overlay is what agents read first.

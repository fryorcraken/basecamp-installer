# Security review: two-node-poc

Dimension: security only. No mutation tool exists for POSIX shell (overlay),
so I read every path for a skippable check and mutated three guards by hand.

- [x] **`spec-writer`** — `tests/integration/storage-round-trip.sh:158-165`, spec
      "Nodes are confined to localhost" — the node's ambient `STORAGE_*`
      environment can undo the confinement and the spec never says to prevent it.
      **Scenario:** the CLI loads its options with `envVarsPrefix = "storage"`
      (`logos-storage-nim/storage.nim:50`). `--api-bindaddr` is not passed by the
      check, and its default is a lowest-priority config source
      (`storage.nim:41,56-57`), so `STORAGE_API_BINDADDR=0.0.0.0` in the caller's
      environment makes all three nodes serve the unauthenticated REST API
      (upload, download, delete) on every interface for the whole run. Every
      request the check makes goes to 127.0.0.1, which 0.0.0.0 includes, so it
      still reports a full pass. `STORAGE_METRICS=true` likewise contradicts "MUST
      NOT enable a node's metrics server" (and the fixed port 8008 would collide
      across the three nodes); `STORAGE_MIX_ENABLED` / `STORAGE_DHT_MIX_PROXY`
      route lookups through other peers. Fleet bootstrap cannot be reached this
      way (`--no-bootstrap-node` wins, `storage.nim:407-409`).
      **Fix direction:** the spec should either require the check to state
      `--api-bindaddr=127.0.0.1` and to run the node with no `STORAGE_*` variable
      in its environment, or put the ambient environment out of scope. The
      code then follows (`dev-writer`).
      **Severity:** low to medium; the caller must set the variable themselves, so
      this is hardening, not an exploit. Read from source; not run against a real
      node.
      **Outcome (`spec-writer`): fixed in the spec, both halves.** Confirmed
      against `logos-storage-nim/storage.nim:41,50,56-57` and
      `storage/conf.nim:83,258`. (1) New requirement "A node's REST API is
      bound to localhost" requires `--api-bindaddr=127.0.0.1` on every node,
      scenario "REST API bind address". (2) New requirement "A node takes no
      setting from the caller's environment": no variable whose name begins
      with `STORAGE_` is in any node's environment, and no `--config-file` is
      given, with scenarios "Caller's environment carries storage variables"
      and "No configuration file". The ambient environment was not put out of scope: one
      rule covers the bind address, metrics, mix and `STORAGE_CONFIG_FILE`
      alike, and a recording stub can observe it. The code does neither yet;
      that is the `dev-writer` entry below.

- [x] **`dev-writer`** — `tests/integration/storage-round-trip.sh:158-165` —
      same defect, code side: the check inherits the caller's environment into
      every node. Apply once the spec above says what is required.
      **Scenario:** as above. **Severity:** low to medium.
      **Fixed** in `4df3bd3`: every node is started with
      `--api-bindaddr=127.0.0.1`, and `clear_storage_environment` unsets every
      `STORAGE_` variable in the check's own shell before any node starts,
      exiting non-zero when a `STORAGE_` line is still listed afterwards.
      Tests "every node's REST API is bound to localhost and takes no
      configuration file" and "no node is given a STORAGE_ variable from the
      caller's environment", both watched failing before the fix. The
      cannot-remove case is not in the spec; its test is marked `NO SPEC:`.
      A real node was run with the new option (its log reads
      `REST service started address=127.0.0.1:28481`); none was run with a
      `STORAGE_` variable set. Reasoning in `design.md`, "The REST API is
      bound explicitly, and `STORAGE_` variables are removed".

- [x] **`tester`** — `tests/integration/storage-round-trip.sh:286` — the CID
      character check in `upload` is not pinned by any test.
      **Scenario:** the CID goes into URLs (`check_manifest`, `fetch`) and into
      the result lines. A node answering `abc/../x` or a body with a newline and
      a fake `sha256=` line would be refused by the check at line 286.
      **Measured:** replacing `'' | *[!A-Za-z0-9]*)` with `'')` leaves all 71
      tests passing. The stub returns only well-formed CIDs.
      **Outcome (`tester`): fixed.** Stub curl knob `upload-body-ROLE-N`
      answers a node's Nth upload with a chosen body. Tests: publisher answers
      with a slash (`abc/../x`), a second line carrying a fake `sha256=` line,
      a space, a dot and a hyphen are each refused at the upload step with the
      CLI invoked once and no manifest requested; the third reproducer upload
      (compared only for difference) answering `abc def` is refused; and
      "a CID followed by newlines is a CID" pins the "apart from trailing
      newlines" clause from the other side. Predicted and observed: with the
      character class removed all five publisher tests and the reproducer test
      fail; with an over-strict check that rejects a trailing newline only the
      newline test fails. Not testable as its own scenario: the spec's
      "second upload returns something that is not a CID" for the first
      reproducer upload, because a malformed answer there is also not the
      recorded CID and the run fails at the same step either way (I wrote
      those two tests, saw them survive the mutant, and removed them); that
      is a note on the spec's scenario, not a defect to fix.

- [x] **`tester`** — `tests/integration/storage-round-trip.sh:290-299` — the peer
      record validation in `read_publisher_spr` is not pinned by any test, and
      the spec has no scenario for it.
      **Scenario:** the publisher's `spr` body is placed in the fetcher's
      `--bootstrap-node=` argument. A body that is not `spr:` plus a base64url
      string (an HTML error page, a value containing `,` or a space) must stop
      the run at "publisher start".
      **Measured:** with the two validating `case` arms replaced by `*) ;;` (any
      non-empty body accepted) all 71 tests pass. The argument is always quoted,
      so this is not an injection; the risk is a fetcher started on a garbage
      bootstrap value and a failure reported at the wrong step.
      **Severity:** low.
      **Outcome (`tester`): fixed.** The spec now has the requirement and three
      scenarios. Tests: the two the `dev-writer` wrote (an HTML body; `spr:`
      with no body), plus bodies with a space, a comma and a slash, and a
      record without the `spr:` prefix (each: refused at "publisher start",
      CLI invoked once), plus "a peer record of every accepted character class
      is passed to the fetcher" (`spr:AZaz09-_=` reaches `--bootstrap-node=`
      unchanged). Predicted and observed, three mutants of the `case`: with the
      character-class arm removed the space, comma and slash tests fail; with
      the prefix arm removed only the prefix test fails; with `=` dropped from
      the accepted set only the accepted-class test fails. The html and
      no-body tests survive all three (the empty-body arm catches them); that
      is the `dev-writer`'s coverage and I kept it.

## Areas read and found clean

- **Shell injection:** every expansion that reaches a command is quoted. The
  CID is restricted to letters and digits before it is placed in a URL. The
  peer record is restricted to `spr:` plus `[A-Za-z0-9_=-]`, and is passed as one
  quoted argument. The constants (filename, block size, mimetype) are fixed.
- **Option injection:** a storage CLI beginning with `-` is only accepted after
  `--` and is then prefixed `./`, so it is never read as an option. A scratch
  parent beginning with `-` is prefixed `./` before `cd`.
- **Scratch directory:** `umask 077`, `mktemp -d` (mode 700, unpredictable
  name), data directories `mkdir -m 700`. No file is written outside it. The
  kept private keys of the ephemeral nodes sit in that private directory.
- **Fail closed:** every verification step ends in `fail`, which exits; none
  runs inside a command substitution. `sha256_of` rejects a tool failure, empty
  output and anything under 64 hex digits. An unparsable manifest, an empty
  body, a non-200 answer and a curl failure all stop the run. No fallback source
  exists. The result lines are printed only after the last check.
- **curl hardening:** `-q` first, `--noproxy '*'`, 127.0.0.1 only, bounded by
  `--max-time`. Cleanup is bounded by a `SIGKILL` watchdog and ignores a second
  signal while it runs.
- **Fixed ports:** a local hostile process could take a node's P2P port or the
  REST port after the foreign-server guard has looked, and make the run fail or
  mislead it. The spec puts that race out of scope. This check is a developer
  and CI test, not a trust boundary, so I do not raise it.
- **Dependencies:** none added. **CI:** no `.github/workflows/` exists yet, so
  no gate is affected.

## Mutations left in the tree

`tests/integration/storage-round-trip.sh`: the peer-record `case` in
`read_publisher_spr` accepts any value (the last of the three mutations above;
the CID-character mutation was put back).

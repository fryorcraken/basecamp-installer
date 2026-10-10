# Spec Delta

## Purpose

The round-trip check proves, against real Logos Storage nodes on one machine,
that content published under a pinned filename and block size is fetched intact
by a second node and has a reproducible CID. It covers localhost only: the
fleet's bootstrap, NAT traversal, relay, seeding, content expiry, the installer
file and any install step are outside it, as are Windows, macOS x86_64, a
custom bootstrap and a Basecamp self-update.

In this capability, the **publisher** is the node the content is first uploaded
to, the **fetcher** is the node that downloads it by CID, and the **pinned
values** are the filename `poc-payload.bin` and the block size 131072 bytes.

This capability is written against the Logos Storage CLI from release 0.5.0
on. A node of that CLI listens on two TCP ports, the REST API port
(`--api-port`) and the peer-to-peer listen port (`--listen-port`), plus a
metrics port only when the metrics server is enabled; it has no separate
discovery port and no `--disc-port` option. An earlier CLI, whose node also
opens a UDP discovery port, is outside this capability.

The **reserved ports** are TCP 8080, which that CLI gives the REST API when
none is stated, and TCP 8500 and UDP 8090, which the Basecamp storage module
uses by default.

## ADDED Requirements

### Requirement: The check is a POSIX sh program
The round-trip check MUST be a POSIX `sh` program that runs on a stock Linux or
macOS desktop. It MUST NOT depend on a shell feature outside POSIX `sh`, nor on
a tool option that exists only in the GNU or only in the BSD variant of that
tool.

#### Scenario: Run by a POSIX shell that is not bash
- **WHEN** the check is run by a POSIX `sh` that is not `bash`
- **THEN** it behaves as every other requirement of this capability states

#### Scenario: No sha256 tool is available
- **WHEN** neither `sha256sum` nor `shasum` is available to the check
- **THEN** it exits non-zero without reporting success, and its diagnostic
  names the missing sha256 tool

### Requirement: The storage CLI is supplied by the caller
The check MUST drive the Logos Storage CLI executable its caller names, and
MUST NOT search for, download or build one itself. It MUST exit non-zero,
before starting any node, when the caller names none or names a path that is
not an executable file.

#### Scenario: No storage CLI named
- **WHEN** the check is run without a storage CLI named
- **THEN** it exits non-zero, starts no node, and its diagnostic says a storage
  CLI is required

#### Scenario: Named path is not executable
- **WHEN** the check is run with a path that does not exist or is not
  executable
- **THEN** it exits non-zero, starts no node, and its diagnostic names that
  path

### Requirement: Nodes are confined to localhost
The check MUST start the publisher with no bootstrap node and with NAT set to
the external address `127.0.0.1`. Every other node it starts MUST be given
bootstrap nodes started by the same run only, and the same NAT setting. The
check MUST NOT give any node a fleet preset or an address off the local
machine.

#### Scenario: Publisher start
- **WHEN** the check starts the publisher
- **THEN** the storage CLI is invoked with no bootstrap node and with NAT
  `extip:127.0.0.1`

#### Scenario: Fetcher start
- **WHEN** the check starts the fetcher
- **THEN** the storage CLI is invoked with NAT `extip:127.0.0.1`, and every
  bootstrap node it is given is a node this run started

### Requirement: Ports are chosen explicitly
The check MUST state, in every node's invocation, both ports that node listens
on: the REST API port with `--api-port` and the peer-to-peer listen port with
`--listen-port`. Each stated port MUST be a number from 1 to 65535 that is not
a reserved port, and the check MUST NOT give two ports of one run the same
number, whether to one node or to two. The check MUST NOT enable a node's
metrics server, and MUST NOT pass `--disc-port`.

#### Scenario: Ports passed to each node
- **WHEN** the check starts a node
- **THEN** the storage CLI invocation carries `--api-port` and `--listen-port`,
  each with a non-zero port that is none of 8080, 8090 and 8500 and that no
  other port of the same run uses

#### Scenario: No other listener is requested
- **WHEN** the check starts a node
- **THEN** the storage CLI invocation carries neither `--disc-port` nor
  `--metrics`

#### Scenario: Reserved ports are occupied
- **WHEN** another process holds TCP 8080, TCP 8500 and UDP 8090 while the
  check runs against a working storage CLI
- **THEN** the check's result is unaffected by it

### Requirement: Nodes start within a bounded wait
The check MUST wait for each node it starts to accept REST requests, for a
bounded time, before using it. It MUST exit non-zero when a node exits early or
is not ready when the wait ends.

#### Scenario: Node exits during start
- **WHEN** the storage CLI exits before its node accepts REST requests
- **THEN** the check exits non-zero and its diagnostic names the node that
  failed to start

#### Scenario: Node never becomes ready
- **WHEN** the storage CLI keeps running but its node never accepts REST
  requests
- **THEN** the check stops waiting after a bounded time, exits non-zero, and
  its diagnostic names the node that did not become ready

### Requirement: Content is published under the pinned values
The check MUST upload its test content to the publisher with the filename
`poc-payload.bin` and the block size 131072 bytes, both stated explicitly in
the upload, and MUST record the CID the publisher returns. The test content
MUST be longer than one block and MUST NOT be a whole number of blocks.

#### Scenario: Upload succeeds
- **WHEN** the publisher accepts the upload
- **THEN** the upload request carried the filename `poc-payload.bin` and the
  block size 131072, and the check records the returned CID

#### Scenario: Upload is refused
- **WHEN** the publisher answers the upload with an error
- **THEN** the check exits non-zero and its diagnostic names the upload step

#### Scenario: Upload returns no CID
- **WHEN** the publisher answers the upload successfully with an empty body
- **THEN** the check exits non-zero and its diagnostic names the upload step

### Requirement: The manifest carries the pinned values
After the upload, the check MUST read the manifest the publisher holds for the
recorded CID and MUST exit non-zero unless it reports the filename
`poc-payload.bin` and the block size 131072. A manifest that cannot be read or
parsed is a failure.

#### Scenario: Manifest matches
- **WHEN** the manifest for the recorded CID reports filename
  `poc-payload.bin` and block size 131072
- **THEN** the check continues to the fetch

#### Scenario: Manifest reports another block size
- **WHEN** the manifest for the recorded CID reports a block size other than
  131072
- **THEN** the check exits non-zero and its diagnostic states the expected and
  the reported block size

#### Scenario: Manifest reports another filename
- **WHEN** the manifest for the recorded CID reports a filename other than
  `poc-payload.bin`, or none
- **THEN** the check exits non-zero and its diagnostic states the expected and
  the reported filename

#### Scenario: Manifest is unreadable
- **WHEN** the manifest request fails or its answer cannot be parsed
- **THEN** the check exits non-zero and its diagnostic names the manifest step

### Requirement: The fetcher is ephemeral and does not advertise
The check MUST start the fetcher only after the CID is recorded, with a data
directory that is empty at start, and MUST stop it once the fetch has ended.
The fetcher MUST download the content by the recorded CID over the network
from the publisher, with `advertise=false`.

#### Scenario: Fetch request
- **WHEN** the check asks the fetcher for the content
- **THEN** the request names the recorded CID and carries `advertise=false`

#### Scenario: Fetcher starts empty
- **WHEN** the check starts the fetcher
- **THEN** the data directory it is given holds nothing

#### Scenario: Fetch fails
- **WHEN** the fetcher answers the download with an error, or the download
  ends before the content is complete
- **THEN** the check exits non-zero and its diagnostic names the fetch step

#### Scenario: Publisher is gone
- **WHEN** the publisher is no longer running when the fetcher asks for the
  content
- **THEN** the check exits non-zero after a bounded time rather than waiting
  indefinitely

### Requirement: Fetched content is verified against the original
The check MUST compute the sha256 of its test content before uploading it. It
MUST exit non-zero unless the fetched content is byte-for-byte identical to the
test content and its sha256 equals the one computed before the upload. A sha256
that cannot be computed or parsed is a failure.

#### Scenario: Fetched content is intact
- **WHEN** the fetched content equals the test content byte for byte
- **THEN** both comparisons pass and the check continues

#### Scenario: Fetched content differs
- **WHEN** the fetched content differs from the test content in at least one
  byte
- **THEN** the check exits non-zero and its diagnostic states the expected and
  the actual sha256

#### Scenario: Fetched content is truncated
- **WHEN** the fetched content is a strict prefix of the test content
- **THEN** the check exits non-zero and its diagnostic names the verification
  step

#### Scenario: sha256 cannot be computed
- **WHEN** the sha256 tool fails or prints nothing for the fetched content
- **THEN** the check exits non-zero without reporting success

### Requirement: The CID reproduces from the same bytes and pinned values
The check MUST upload the same test content, with the pinned values, to a node
whose data directory was empty at start and which has not fetched the content.
It MUST exit non-zero unless the CID that node returns equals the recorded CID.

#### Scenario: CID reproduces
- **WHEN** the second upload returns the recorded CID
- **THEN** the check continues

#### Scenario: CID does not reproduce
- **WHEN** the second upload returns a CID other than the recorded one
- **THEN** the check exits non-zero and its diagnostic states both CIDs

#### Scenario: Second upload fails
- **WHEN** the second upload is refused or returns no CID
- **THEN** the check exits non-zero and its diagnostic names the re-upload step

### Requirement: The CID changes when a pinned value changes
The check MUST upload the same test content once with a filename other than
`poc-payload.bin` and block size 131072, and once with filename
`poc-payload.bin` and a block size other than 131072. It MUST exit non-zero
unless each of those two CIDs differs from the recorded CID.

#### Scenario: Different filename, different CID
- **WHEN** the same content is uploaded with another filename and block size
  131072
- **THEN** the returned CID differs from the recorded CID and the check
  continues

#### Scenario: Different block size, different CID
- **WHEN** the same content is uploaded with filename `poc-payload.bin` and
  another block size
- **THEN** the returned CID differs from the recorded CID and the check
  continues

#### Scenario: A changed value gives the recorded CID
- **WHEN** an upload with a changed filename or a changed block size returns
  the recorded CID
- **THEN** the check exits non-zero and its diagnostic names which value was
  changed

### Requirement: Success is reported only after every verification
The check MUST exit zero only when the manifest check, the fetch verification,
the reproduction check and both changed-value checks have all run and passed.
On success it MUST print to standard output one line each of the form
`cid=<value>`, `filename=<value>`, `block_size=<value>` and `sha256=<value>`,
carrying the recorded CID, the pinned values and the sha256 of the test
content.

#### Scenario: Full pass
- **WHEN** every step passes
- **THEN** the check exits zero and standard output carries the four lines,
  with `filename=poc-payload.bin` and `block_size=131072`

#### Scenario: A failure prints no result lines
- **WHEN** any step fails
- **THEN** the check exits non-zero, standard output carries no `cid=` line,
  and the diagnostic is on standard error

### Requirement: Failure stops the run
The check MUST stop at the first failed step: it MUST NOT continue to a later
step, retry against another source, or treat a missing or unparsable answer as
a pass.

#### Scenario: Later steps are not attempted
- **WHEN** the manifest check fails
- **THEN** no fetcher is started and no fetch is requested

### Requirement: No node outlives the run
The check MUST stop every node it started before it exits, whether it exits
zero, exits non-zero, or is interrupted by `SIGINT` or `SIGTERM`.

#### Scenario: Exit after success
- **WHEN** the check exits zero
- **THEN** no storage process it started is still running

#### Scenario: Exit after failure
- **WHEN** the check exits non-zero after having started a node
- **THEN** no storage process it started is still running

#### Scenario: Interrupted
- **WHEN** the check receives `SIGTERM` while a node is running
- **THEN** it stops that node and exits non-zero

### Requirement: Files stay in one scratch directory
The check MUST create every file it writes, including node data directories,
node logs, the test content and the fetched content, under a single scratch
directory, and MUST print that directory's path on standard error. It MUST NOT
write anywhere else.

#### Scenario: Run leaves the tree untouched
- **WHEN** the check has run, passing or failing
- **THEN** every file it created is under the scratch directory it printed

#### Scenario: Logs survive a failure
- **WHEN** the check exits non-zero after having started a node
- **THEN** that node's log is still present under the scratch directory

# Spec Delta

## Purpose

The round-trip check proves, against real Logos Storage nodes on one machine,
that content published under a pinned filename, block size and mimetype is
fetched intact by a second node and has a reproducible CID. It covers localhost
only: the fleet's bootstrap, NAT traversal, relay, seeding, content expiry, the
installer file and any install step are outside it, as are Windows, macOS
x86_64, a custom bootstrap and a Basecamp self-update.

In this capability, the **publisher** is the node the content is first uploaded
to, the **fetcher** is the node that downloads it by CID, and the
**reproducer** is the node the same content is uploaded to again. The **pinned
values** are the filename `poc-payload.bin`, the block size 131072 bytes and
the mimetype `application/octet-stream`. A run starts these three nodes and no
other.

This capability is written against the Logos Storage CLI from release 0.5.0
on. A node of that CLI listens on two TCP ports, the REST API port
(`--api-port`) and the peer-to-peer listen port (`--listen-port`), plus a
metrics port only when the metrics server is enabled; it has no separate
discovery port and no `--disc-port` option. An earlier CLI, whose node also
opens a UDP discovery port, is outside this capability.

That CLI also takes the value of any of its options from an environment
variable whose name begins with `STORAGE_`, and from a configuration file named
with `--config-file`.

A wait or a time is **bounded** when its limit is fixed in the check and it
ends without any outside action. The number of seconds of a bound is not part
of this contract.

The **reserved ports** are TCP 8080, which that CLI gives the REST API when
none is stated, and TCP 8500 and UDP 8090, which the Basecamp storage module
uses by default.

Also outside this capability:

- **A CID under a changed mimetype.** The check states the pinned mimetype in
  every upload and confirms the manifest reports it; it does not upload under
  another mimetype to show the CID changes.
- **Ports chosen by the caller, and a search for free ports.** The ports of a
  run are the check's own.
- **The check's result while another process holds a reserved port.** The
  check states ports that are not reserved; no run with a reserved port held is
  part of this contract.
- **Two runs at the same time on one machine.**
- **A server that starts answering on a node's REST port after the check has
  found that port silent** and before the node binds it.
- **Signals other than `SIGINT` and `SIGTERM`.** Whether a node outlives a
  check ended by any other signal is not stated.
- **Removing the scratch directory.** The check never deletes it; that is its
  caller's.

## ADDED Requirements

### Requirement: The check is a POSIX sh program
The round-trip check MUST be a POSIX `sh` program that runs on a stock Linux or
macOS desktop. It MUST NOT depend on a shell feature outside POSIX `sh`, nor on
a tool option that exists only in the GNU or only in the BSD variant of that
tool.

#### Scenario: Run by a POSIX shell that is not bash
- **WHEN** the check is run by a POSIX `sh` that is not `bash`
- **THEN** it behaves as every other requirement of this capability states

### Requirement: Tools outside POSIX are named and checked first
Beyond the utilities POSIX specifies, the check MUST depend on nothing but
`curl` as its HTTP client, `mktemp`, and one of `sha256sum` and `shasum`. It
MUST exit non-zero, before starting any node and before creating its scratch
directory, when one of them is not available, and its diagnostic MUST name the
missing tool.

#### Scenario: No sha256 tool is available
- **WHEN** neither `sha256sum` nor `shasum` is available to the check
- **THEN** it exits non-zero without reporting success, starts no node, and its
  diagnostic names the missing sha256 tool

#### Scenario: Only shasum is available
- **WHEN** `shasum` is available to the check and `sha256sum` is not
- **THEN** the check's result is the same as with `sha256sum`

#### Scenario: curl is not available
- **WHEN** `curl` is not available to the check
- **THEN** it exits non-zero, starts no node, and its diagnostic names `curl`

#### Scenario: mktemp is not available
- **WHEN** `mktemp` is not available to the check
- **THEN** it exits non-zero, starts no node, and its diagnostic names `mktemp`

### Requirement: The command line is one operand and one option
The check MUST accept a command line of the form
`[--scratch-parent DIR] [--] STORAGE_CLI`. `STORAGE_CLI` is the
single operand; an argument after `--` is the operand even when it begins with
`-`. The check MUST exit non-zero, before starting any node and before creating
its scratch directory, when it is given an option other than
`--scratch-parent`, `--scratch-parent` with no value after it, or more than one
operand.

#### Scenario: Unknown option
- **WHEN** the check is run with an option other than `--scratch-parent`
- **THEN** it exits non-zero, starts no node, and its diagnostic names that
  option

#### Scenario: Option without its value
- **WHEN** the check is run with `--scratch-parent` as its last argument
- **THEN** it exits non-zero, starts no node, and its diagnostic says
  `--scratch-parent` needs a directory

#### Scenario: More than one operand
- **WHEN** the check is run with two operands
- **THEN** it exits non-zero and starts no node

#### Scenario: Operand after the option terminator
- **WHEN** the check is run with `--` followed by a path that begins with `-`
- **THEN** that path is taken as the storage CLI, not as an option

### Requirement: A repeated option takes its last value
When `--scratch-parent` is given more than once, the check MUST use the value
of the last one and MUST NOT treat the repeat as an error.

#### Scenario: Option given twice
- **WHEN** the check is run with `--scratch-parent` twice, naming two different
  directories
- **THEN** the scratch directory it prints is a direct child of the second
  directory, and the run adds no entry to the first

### Requirement: The storage CLI is supplied by the caller
The check MUST drive the Logos Storage CLI executable its caller names, and
MUST NOT search for, download or build one itself. It MUST exit non-zero,
before starting any node, when the caller names none or names a path that is
not an executable file. A name that contains no `/` MUST be taken as a file in
the current directory and MUST NOT be looked up on `PATH`.

#### Scenario: No storage CLI named
- **WHEN** the check is run without a storage CLI named, or with an empty one
- **THEN** it exits non-zero, starts no node, and its diagnostic says a storage
  CLI is required

#### Scenario: Named path is not executable
- **WHEN** the check is run with a path that does not exist or is not
  executable
- **THEN** it exits non-zero, starts no node, and its diagnostic names that
  path

#### Scenario: Bare name that is only on PATH
- **WHEN** the check is run with a name that contains no `/`, no file of that
  name is in the current directory, and `PATH` holds an executable of that name
- **THEN** it exits non-zero and the executable on `PATH` is not run

#### Scenario: Bare name that is in the current directory
- **WHEN** the check is run with a name that contains no `/`, an executable
  file of that name is in the current directory, and `PATH` holds another
  executable of that name
- **THEN** the file in the current directory is the one run

### Requirement: Nodes are confined to localhost
The check MUST start every node with NAT set to the external address
`127.0.0.1` and with its peer-to-peer listener bound to `127.0.0.1`
(`--listen-ip=127.0.0.1`). It MUST start the publisher and the reproducer with
`--no-bootstrap-node` and with no `--bootstrap-node`. It MUST give the fetcher
exactly one bootstrap node, the signed peer record the publisher of the same
run returned. The check MUST NOT give any node a fleet preset (`--network`) or
an address off the local machine.

#### Scenario: Publisher start
- **WHEN** the check starts the publisher
- **THEN** the storage CLI is invoked with `--no-bootstrap-node`, with no
  `--bootstrap-node`, with `--nat=extip:127.0.0.1` and with
  `--listen-ip=127.0.0.1`

#### Scenario: Fetcher start
- **WHEN** the check starts the fetcher
- **THEN** the storage CLI is invoked with `--nat=extip:127.0.0.1`, with
  `--listen-ip=127.0.0.1`, and with exactly one `--bootstrap-node`, whose value
  is the peer record the publisher returned

#### Scenario: Reproducer start
- **WHEN** the check starts the reproducer
- **THEN** the storage CLI is invoked with `--no-bootstrap-node`, with no
  `--bootstrap-node`, with `--nat=extip:127.0.0.1` and with
  `--listen-ip=127.0.0.1`

#### Scenario: No fleet preset
- **WHEN** the check starts a node
- **THEN** the storage CLI invocation carries no `--network`

### Requirement: A node's REST API is bound to localhost
The check MUST start every node with its REST API bound to `127.0.0.1`, stated
in the invocation as `--api-bindaddr=127.0.0.1`.

#### Scenario: REST API bind address
- **WHEN** the check starts a node
- **THEN** the storage CLI invocation carries `--api-bindaddr=127.0.0.1`

### Requirement: A node takes no setting from the caller's environment
The check MUST start every node with an environment that holds no variable
whose name begins with `STORAGE_`, whatever the check's own environment holds.
It MUST NOT give any node a configuration file (`--config-file`).

#### Scenario: No configuration file
- **WHEN** the check starts a node
- **THEN** the storage CLI invocation carries no `--config-file`

#### Scenario: Caller's environment carries storage variables
- **WHEN** the check is run with `STORAGE_API_BINDADDR=0.0.0.0` and
  `STORAGE_METRICS=true` in its environment
- **THEN** the environment of every storage CLI invocation holds no variable
  whose name begins with `STORAGE_`

### Requirement: Requests stay on the local machine
The check MUST address every HTTP request it makes to `127.0.0.1`, at the REST
API port of a node of the same run. So that neither a `curl` configuration
file of the user nor a proxy variable in the environment applies to a request,
the check MUST invoke `curl` with `-q` as its first argument and with
`--noproxy` given `*`.

#### Scenario: Request target
- **WHEN** the check makes an HTTP request
- **THEN** the URL's host is `127.0.0.1` and its port is a REST API port the
  check gave a node of this run

#### Scenario: User configuration and proxies are bypassed
- **WHEN** the check makes an HTTP request
- **THEN** `curl` is invoked with `-q` as its first argument and with
  `--noproxy` given `*`

### Requirement: Every request carries a time limit
The check MUST invoke `curl`, for every HTTP request it makes, with
`--max-time` given a number of seconds greater than zero.

#### Scenario: Request time limit
- **WHEN** the check makes an HTTP request
- **THEN** `curl` is invoked with `--max-time` given a number greater than zero

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

### Requirement: The ports of a run are the check's own
The check MUST NOT take a port from its caller or from its environment, and
MUST use the same ports on every run.

#### Scenario: Ports do not vary between runs
- **WHEN** the check is run twice, one run after the other
- **THEN** each node is given the same two ports in the second run as in the
  first

### Requirement: A REST port that already answers is refused
Before starting a node, the check MUST ask whether anything already answers an
HTTP request on `127.0.0.1` at the REST API port that node is to be given. When
something does, whatever the HTTP status of its answer, the check MUST exit
non-zero without starting that node.

#### Scenario: Foreign server on the publisher's REST port
- **WHEN** a server that the check did not start answers HTTP requests on the
  publisher's REST API port
- **THEN** the check exits non-zero, the storage CLI is never invoked, and its
  diagnostic names the publisher and that port

#### Scenario: Foreign server on a later node's REST port
- **WHEN** a server that the check did not start answers HTTP requests on the
  fetcher's REST API port, and nothing answers on the publisher's
- **THEN** the check exits non-zero, the storage CLI is not invoked for the
  fetcher, and its diagnostic names the fetcher and that port

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
- **THEN** the check stops waiting without being signalled, exits non-zero,
  and its diagnostic names the node that did not become ready

### Requirement: Content is published under the pinned values
The check MUST upload its test content to the publisher with the filename
`poc-payload.bin`, the block size 131072 bytes and the mimetype
`application/octet-stream`, all three stated explicitly in the upload, and MUST
record the CID the publisher returns. The mimetype MUST be stated as the
upload's `Content-Type`, in every upload the check makes to any node. The test
content MUST be longer than one block and MUST NOT be a whole number of blocks.

#### Scenario: Upload succeeds
- **WHEN** the publisher accepts the upload
- **THEN** the upload request carried the filename `poc-payload.bin`, the
  block size 131072 and `Content-Type: application/octet-stream`, and the check
  records the returned CID

#### Scenario: Every upload states the mimetype
- **WHEN** the check has run to a full pass
- **THEN** every upload request it made, to the publisher and to the
  reproducer, carried `Content-Type: application/octet-stream`

#### Scenario: Upload is refused
- **WHEN** the publisher answers the upload with an error
- **THEN** the check exits non-zero and its diagnostic names the upload step

#### Scenario: Upload returns no CID
- **WHEN** the publisher answers the upload successfully with an empty body
- **THEN** the check exits non-zero and its diagnostic names the upload step

### Requirement: The manifest carries the pinned values
After the upload, the check MUST read the manifest the publisher holds for the
recorded CID and MUST exit non-zero unless it reports the filename
`poc-payload.bin`, the block size 131072 and the mimetype
`application/octet-stream`. A manifest that cannot be read or parsed is a
failure.

#### Scenario: Manifest matches
- **WHEN** the manifest for the recorded CID reports filename
  `poc-payload.bin`, block size 131072 and mimetype `application/octet-stream`
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

#### Scenario: Manifest reports another mimetype
- **WHEN** the manifest for the recorded CID reports the pinned filename and
  block size, and a mimetype other than `application/octet-stream`, or none
- **THEN** the check exits non-zero and its diagnostic states the expected and
  the reported mimetype

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
- **THEN** the check exits non-zero without being signalled, no later than the
  fetch request's time limit allows

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
The check MUST upload the same test content, with the pinned values, to the
reproducer: a node that is neither the publisher nor the fetcher, whose data
directory was empty at start and which has not fetched the content. It MUST
exit non-zero unless the CID that node returns equals the recorded CID.

#### Scenario: Reproducer starts empty and has not fetched
- **WHEN** the check uploads the test content to the reproducer
- **THEN** the data directory the reproducer was given held nothing at start,
  and the check has made no download request to the reproducer

#### Scenario: CID reproduces
- **WHEN** the second upload returns the recorded CID
- **THEN** the check continues

#### Scenario: CID does not reproduce
- **WHEN** the second upload returns a CID other than the recorded one
- **THEN** the check exits non-zero and its diagnostic states both CIDs

#### Scenario: Second upload fails
- **WHEN** the second upload is refused or returns no CID
- **THEN** the check exits non-zero and its diagnostic names the re-upload step

### Requirement: The CID changes when the filename or the block size changes
The check MUST upload the same test content once with a filename other than
`poc-payload.bin` and block size 131072, and once with filename
`poc-payload.bin` and a block size other than 131072, each with the pinned
mimetype. It MUST exit non-zero unless each of those two CIDs differs from the
recorded CID.

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
On success it MUST print to standard output exactly five lines, of the forms
`cid=<value>`, `filename=<value>`, `block_size=<value>`, `mimetype=<value>` and
`sha256=<value>` in that order, carrying the recorded CID, the pinned values
and the sha256 of the test content.

#### Scenario: Full pass
- **WHEN** every step passes
- **THEN** the check exits zero and standard output carries the five lines and
  nothing else, with `filename=poc-payload.bin`, `block_size=131072` and
  `mimetype=application/octet-stream`

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
zero, exits non-zero, or is interrupted by `SIGINT` or `SIGTERM`. A node that
does not exit when asked to MUST be killed after a bounded wait.

#### Scenario: Exit after success
- **WHEN** the check exits zero
- **THEN** no storage process it started is still running

#### Scenario: Exit after failure
- **WHEN** the check exits non-zero after having started a node
- **THEN** no storage process it started is still running

#### Scenario: Interrupted
- **WHEN** the check receives `SIGTERM` while a node is running
- **THEN** it stops that node, exits non-zero, and standard output carries no
  `cid=` line

#### Scenario: Node ignores the request to stop
- **WHEN** the check exits while a node it started ignores `SIGTERM`
- **THEN** the check still exits, after a bounded time, and that node is no
  longer running

### Requirement: Files stay in one scratch directory
The check MUST create every file it writes, including node data directories,
node logs, the test content and the fetched content, under a single scratch
directory, and MUST print that directory's absolute path on standard error. It
MUST NOT write anywhere else. The scratch directory MUST be a directory the run
itself creates, new for each run, and MUST grant no permission to group or
others.

#### Scenario: Run leaves the tree untouched
- **WHEN** the check has run, passing or failing
- **THEN** every file it created is under the scratch directory it printed

#### Scenario: Each run has its own scratch directory
- **WHEN** the check is run twice with the same scratch parent
- **THEN** the two runs print different scratch directories, and the first
  run's files are unchanged by the second

#### Scenario: Scratch directory is private
- **WHEN** the check has created its scratch directory
- **THEN** the directory's mode grants no read, write or search permission to
  group or others

### Requirement: The caller chooses where the scratch directory is made
The check MUST create its scratch directory directly under the directory given
with `--scratch-parent`. Without that option it MUST create it under the
directory `TMPDIR` names when `TMPDIR` is set and not empty, and under `/tmp`
otherwise. The scratch parent MUST already be a directory: the check MUST NOT
create it, and MUST exit non-zero, before starting any node, when it is not
one.

#### Scenario: Scratch parent given
- **WHEN** the check is run with `--scratch-parent DIR` and `DIR` is a
  directory
- **THEN** the scratch directory it prints is a direct child of `DIR`, and the
  run adds no other entry to `DIR`

#### Scenario: Relative scratch parent
- **WHEN** the check is run with a relative path as the scratch parent
- **THEN** the scratch directory it prints is an absolute path

#### Scenario: Scratch parent from the environment
- **WHEN** the check is run without `--scratch-parent` and `TMPDIR` names a
  directory
- **THEN** the scratch directory it prints is a direct child of that directory

#### Scenario: Option beats the environment
- **WHEN** the check is run with `--scratch-parent DIR` and `TMPDIR` names
  another directory
- **THEN** the scratch directory it prints is a direct child of `DIR`, and the
  run adds no entry to the directory `TMPDIR` names

#### Scenario: TMPDIR is not set
- **WHEN** the check is run without `--scratch-parent` and `TMPDIR` is not set
- **THEN** the directory it asks `mktemp` to create is directly under `/tmp`

#### Scenario: TMPDIR is empty
- **WHEN** the check is run without `--scratch-parent` and `TMPDIR` is set to
  the empty string
- **THEN** the directory it asks `mktemp` to create is directly under `/tmp`

#### Scenario: Scratch parent is not a directory
- **WHEN** the check is run with a scratch parent that does not exist or is
  not a directory
- **THEN** it exits non-zero, starts no node, does not create that path, and
  its diagnostic names it

### Requirement: The scratch directory is kept
The check MUST NOT delete its scratch directory or any file under it, whether
it exits zero or non-zero.

#### Scenario: Files survive a pass
- **WHEN** the check exits zero
- **THEN** the test content, the fetched content and every node's log are
  still present under the scratch directory

#### Scenario: Logs survive a failure
- **WHEN** the check exits non-zero after having started a node
- **THEN** that node's log is still present under the scratch directory

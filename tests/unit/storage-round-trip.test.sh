# Unit tests for tests/integration/storage-round-trip.sh, sourced by
# tests/run.sh, which defines begin, knob, run_check, the assertions and end.
# Each test names the spec requirement or scenario it pins; NO SPEC marks a
# behaviour the spec does not state.
# shellcheck shell=sh disable=SC2154

# --- The storage CLI is supplied by the caller -------------------------------

begin "no storage CLI named"
run_check
assert_failed_at usage
assert_contains "$work/stderr" "a storage CLI is required"
assert_line_count "$state/invocations" 0
assert_no_scratch_made
end

begin "an empty storage CLI is refused as none named"
run_check ''
assert_failed_at usage
assert_contains "$work/stderr" "a storage CLI is required"
assert_line_count "$state/invocations" 0
assert_no_scratch_made
end

begin "named path does not exist"
run_check "$work/no-such-cli"
assert_failed_at "storage CLI"
assert_contains "$work/stderr" "$work/no-such-cli"
assert_line_count "$state/invocations" 0
assert_no_scratch_made
end

begin "named path is not executable"
cp "$stub_cli" "$work/plain-file"
chmod a-x "$work/plain-file"
run_check "$work/plain-file"
assert_failed_at "storage CLI"
assert_contains "$work/stderr" "$work/plain-file"
assert_line_count "$state/invocations" 0
assert_no_scratch_made
end

# An executable directory is a path the shell can run nothing from.
begin "named path is a directory"
run_check "$work/state"
assert_failed_at "storage CLI"
assert_contains "$work/stderr" "$work/state"
assert_line_count "$state/invocations" 0
assert_no_scratch_made
end

# The check must not search for a CLI: a bare name that is not a file here is
# refused even though PATH holds an executable of that name.
begin "a bare name is not looked up on PATH"
run_check storage
assert_failed_at "storage CLI"
assert_line_count "$state/invocations" 0
assert_no_scratch_made
end

# The other half: a bare name that is a file here runs that file, not the
# executable of the same name on PATH.
begin "a bare name runs the file in the current directory"
mkdir "$work/cwd"
printf '#!/bin/sh\n: >"$STUB_STATE/local-cli-ran"\nexit 1\n' >"$work/cwd/storage"
chmod +x "$work/cwd/storage"
cd "$work/cwd" || exit 2
run_check storage
cd "$repo" || exit 2
assert_failed_at "publisher start"
[ -f "$state/local-cli-ran" ] || flunk "the file in the current directory was not run"
assert_line_count "$state/invocations" 0
end

# --- The check is a POSIX sh program -----------------------------------------

begin "no sha256 tool is available"
make_toolbox "$work/toolbox"
rm "$work/toolbox/sha256sum"
check_path=$work/toolbox
run_check "$stub_cli"
assert_failed_at tools
assert_contains "$work/stderr" "sha256"
assert_line_count "$state/invocations" 0
assert_no_scratch_made
end

# The stand-in shasum accepts only the invocation shasum documents for SHA-256,
# `shasum -a 256` reading standard input, and passes it to the real digest tool.
begin "only shasum is available"
make_toolbox "$work/toolbox"
rm "$work/toolbox/sha256sum"
printf '%s\n' '#!/bin/sh' \
	'[ "$#" -eq 2 ] && [ "$1" = -a ] && [ "$2" = 256 ] ||' \
	'	{ echo "shasum: unexpected arguments: $*" >&2; exit 2; }' \
	': >"$STUB_STATE/shasum-ran"' \
	"exec $real_sha256" >"$work/toolbox/shasum"
chmod +x "$work/toolbox/shasum"
check_path=$work/toolbox
run_check "$stub_cli"
assert_status_zero
[ -f "$state/shasum-ran" ] || flunk "the check did not use shasum"
assert_result_lines
end

begin "curl is not available"
make_toolbox "$work/toolbox"
rm "$work/toolbox/curl"
check_path=$work/toolbox
run_check "$stub_cli"
assert_failed_at tools
assert_contains "$work/stderr" "curl"
assert_line_count "$state/invocations" 0
assert_no_scratch_made
end

begin "mktemp is not available"
make_toolbox "$work/toolbox"
rm "$work/toolbox/mktemp"
check_path=$work/toolbox
run_check "$stub_cli"
assert_failed_at tools
assert_contains "$work/stderr" "mktemp"
assert_line_count "$state/invocations" 0
assert_no_scratch_made
end

# --- The command line is one operand and one option --------------------------

begin "unknown option"
run_check --bogus "$stub_cli"
assert_failed_at usage
assert_contains "$work/stderr" "--bogus"
assert_line_count "$state/invocations" 0
assert_no_scratch_made
end

# run_check states --scratch-parent first, so the option the test adds is last.
begin "option without its value"
run_check --scratch-parent
assert_failed_at usage
assert_contains "$work/stderr" "--scratch-parent needs a directory"
assert_line_count "$state/invocations" 0
assert_no_scratch_made
end

begin "more than one operand"
run_check "$stub_cli" "$stub_cli"
assert_failed_at usage
assert_line_count "$state/invocations" 0
assert_no_scratch_made
end

# The file is named -cli and sits in the current directory, so it is a bare name
# that begins with a hyphen: only the terminator can make it an operand.
begin "an operand after the option terminator is the storage CLI"
cp "$stub_cli" "$work/-cli"
cd "$work" || exit 2
run_check -- -cli
cd "$repo" || exit 2
assert_status_zero
assert_line_count "$state/invocations" 3
end

begin "a hyphen-led operand without the terminator is an unknown option"
cp "$stub_cli" "$work/-cli"
cd "$work" || exit 2
run_check -cli
cd "$repo" || exit 2
assert_failed_at usage
assert_contains "$work/stderr" "-cli"
assert_line_count "$state/invocations" 0
end

# --- Full pass ---------------------------------------------------------------

begin "full pass prints the five result lines and nothing else"
run_check "$stub_cli"
assert_status_zero
assert_result_lines
end

begin "nodes are confined to localhost"
run_check "$stub_cli"
assert_status_zero
assert_line_count "$state/invocations" 3
sed -n 1p "$state/invocations" >"$work/publisher-args"
sed -n 2p "$state/invocations" >"$work/fetcher-args"
sed -n 3p "$state/invocations" >"$work/reproducer-args"
for unbootstrapped in publisher reproducer; do
	assert_contains "$work/$unbootstrapped-args" "--no-bootstrap-node"
	assert_lacks "$work/$unbootstrapped-args" "--bootstrap-node="
done
assert_lacks "$work/fetcher-args" "--no-bootstrap-node"
for node in publisher fetcher reproducer; do
	tr ' ' '\n' <"$work/$node-args" >"$work/$node-arg-lines"
	grep -x -- '--nat=extip:127\.0\.0\.1' "$work/$node-arg-lines" >/dev/null ||
		flunk "the $node lacks --nat=extip:127.0.0.1: $(cat "$work/$node-args")"
	grep -x -- '--listen-ip=127\.0\.0\.1' "$work/$node-arg-lines" >/dev/null ||
		flunk "the $node lacks --listen-ip=127.0.0.1: $(cat "$work/$node-args")"
done
# The stub publisher's peer record is spr:STUB-publisher, and nothing else is.
tr ' ' '\n' <"$work/fetcher-args" | grep -- '^--bootstrap-node' >"$work/fetcher-bootstrap"
assert_line_count "$work/fetcher-bootstrap" 1
grep -x -- '--bootstrap-node=spr:STUB-publisher' "$work/fetcher-bootstrap" >/dev/null ||
	flunk "the fetcher's bootstrap node is not the publisher: $(cat "$work/fetcher-bootstrap")"
assert_lacks "$state/invocations" "--network"
assert_lacks "$state/requests" "OFF-HOST"
grep -v ' http://127\.0\.0\.1:' "$state/requests" >"$work/off-host-requests"
assert_line_count "$work/off-host-requests" 0
end

begin "ports are stated, distinct and not reserved"
run_check "$stub_cli"
assert_status_zero
tr ' ' '\n' <"$state/invocations" |
	sed -n -e 's/^--api-port=//p' -e 's/^--listen-port=//p' >"$work/ports"
assert_line_count "$work/ports" 6
while read -r port; do
	case $port in
	'' | *[!0-9]*) flunk "port '$port' is not a number" ;;
	8080 | 8090 | 8500) flunk "port $port is reserved" ;;
	*) { [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; } || flunk "port $port is out of range" ;;
	esac
done <"$work/ports"
[ -z "$(sort "$work/ports" | uniq -d)" ] || flunk "a port is used twice: $(cat "$work/ports")"
while read -r invocation; do
	case $invocation in
	*--api-port=*--listen-port=* | *--listen-port=*--api-port=*) ;;
	*) flunk "an invocation lacks a port: $invocation" ;;
	esac
done <"$state/invocations"
assert_lacks "$state/invocations" "--disc-port"
assert_lacks "$state/invocations" "--metrics"
end

# Scenario "The ports of a run are the check's own": the same two ports for
# each node on a second run. The stub's state is cleared between the runs so
# that it assigns the roles again; the scratch parent is not.
begin "the ports do not vary between runs"
run_check "$stub_cli"
assert_status_zero
tr ' ' '\n' <"$state/invocations" |
	sed -n -e 's/^--api-port=/api /p' -e 's/^--listen-port=/listen /p' >"$work/first-run-ports"
assert_line_count "$work/first-run-ports" 6
rm -rf "$state"
mkdir "$state"
run_check "$stub_cli"
assert_status_zero
tr ' ' '\n' <"$state/invocations" |
	sed -n -e 's/^--api-port=/api /p' -e 's/^--listen-port=/listen /p' >"$work/second-run-ports"
cmp -s "$work/first-run-ports" "$work/second-run-ports" ||
	flunk "the ports differ: $(cat "$work/first-run-ports") then $(cat "$work/second-run-ports")"
end

# Scenario "Request target": every request is to a REST port that this run gave
# a node. The ports are read from the invocations the stub recorded.
begin "requests are addressed to the REST ports of this run"
run_check "$stub_cli"
assert_status_zero
tr ' ' '\n' <"$state/invocations" | sed -n 's/^--api-port=//p' >"$work/api-ports"
assert_line_count "$work/api-ports" 3
sed -n 's|^[A-Z]* http://127\.0\.0\.1:\([0-9]*\)/.*|\1|p' "$state/requests" >"$work/request-ports"
request_count=$(grep -c '' "$state/requests")
assert_line_count "$work/request-ports" "$request_count"
while read -r port; do
	grep -x -F -- "$port" "$work/api-ports" >/dev/null ||
		flunk "a request went to port $port, which is no node's REST port: $(cat "$work/api-ports")"
done <"$work/request-ports"
end

# Scenario "User configuration and proxies are bypassed". The stub does not
# honour the arguments, it records them; the expected line is hardcoded here.
begin "every request is made with -q first and --noproxy given *"
run_check "$stub_cli"
assert_status_zero
request_count=$(grep -c '' "$state/requests")
assert_line_count "$state/curl-calls" "$request_count"
grep -v ' first=-q noproxy=\* ' "$state/curl-calls" >"$work/unbypassed-calls"
assert_line_count "$work/unbypassed-calls" 0
end

# Not in a scenario: Failure stops the run, and "Publisher is gone" asks for a
# bounded wait. The stub cannot time out, so the test sees that the fetch, and
# every other request, carried a positive --max-time.
begin "every request carries a time limit"
run_check "$stub_cli"
assert_status_zero
request_count=$(grep -c '' "$state/requests")
grep -E ' max-time=[1-9][0-9]*$' "$state/curl-calls" >"$work/limited-calls"
assert_line_count "$work/limited-calls" "$request_count"
grep -F '/network/stream' "$work/limited-calls" >"$work/limited-fetch"
assert_line_count "$work/limited-fetch" 1
end

begin "uploads carry the pinned values"
run_check "$stub_cli"
assert_status_zero
sed -n 1p "$state/uploads" >"$work/first-upload"
assert_contains "$work/first-upload" " poc-payload.bin 131072 "
grep -F 'POST ' "$state/requests" | sed -n 1p >"$work/first-upload-request"
assert_contains "$work/first-upload-request" "blockSize=131072"
assert_contains "$work/first-upload-request" 'filename="poc-payload.bin"'
assert_contains "$work/first-upload-request" '[Content-Type: application/octet-stream]'
payload_size=$(wc -c <"$scratch/poc-payload.bin")
[ "$payload_size" -gt 131072 ] || flunk "the test content is $payload_size bytes, not more than one block"
[ $((payload_size % 131072)) -ne 0 ] || flunk "the test content is a whole number of blocks"
end

# Scenario "Every upload states the mimetype": the upload to the publisher and
# the three to the reproducer.
begin "every upload states the pinned mimetype"
run_check "$stub_cli"
assert_status_zero
grep -F 'POST ' "$state/requests" >"$work/upload-requests"
assert_line_count "$work/upload-requests" 4
grep -F '[Content-Type: application/octet-stream]' "$work/upload-requests" >"$work/typed-uploads"
assert_line_count "$work/typed-uploads" 4
end

begin "the fetcher starts empty, fetches by CID without advertising, and is stopped"
run_check "$stub_cli"
assert_status_zero
assert_empty_file "$state/data-dir-at-start-fetcher"
recorded_cid=$(sed -n '1s/^publisher \([^ ]*\) .*/\1/p' "$state/uploads")
grep -F '/network/stream' "$state/requests" >"$work/fetch-requests"
assert_line_count "$work/fetch-requests" 1
assert_contains "$work/fetch-requests" "/api/storage/v1/data/$recorded_cid/network/stream?advertise=false"
# The fetcher is started only after the CID is recorded: its first request
# comes after the publisher's upload in the request log.
upload_line=$(grep -n 'POST ' "$state/requests" | sed -n '1s/:.*//p')
fetcher_port=$(sed -n 2p "$state/invocations" | tr ' ' '\n' | sed -n 's/^--api-port=//p')
fetcher_line=$(grep -n "127\.0\.0\.1:$fetcher_port/" "$state/requests" | sed -n '1s/:.*//p')
[ "$upload_line" -lt "$fetcher_line" ] || flunk "the fetcher was contacted before the upload"
end

begin "the reproduction node starts empty and never fetched"
run_check "$stub_cli"
assert_status_zero
assert_empty_file "$state/data-dir-at-start-reproducer"
assert_contains "$state/fetched-by" "fetcher"
assert_lacks "$state/fetched-by" "reproducer"
grep '^reproducer .* poc-payload.bin 131072 ' "$state/uploads" >"$work/pinned-reuploads"
assert_line_count "$work/pinned-reuploads" 1
# No download request of any kind went to the reproducer's REST port.
reproducer_port=$(sed -n 3p "$state/invocations" | tr ' ' '\n' | sed -n 's/^--api-port=//p')
grep -F "127.0.0.1:$reproducer_port/" "$state/requests" >"$work/reproducer-requests"
[ -s "$work/reproducer-requests" ] || flunk "the reproducer was sent no request"
assert_lacks "$work/reproducer-requests" "/network/"
end

# --- Nodes start within a bounded wait ---------------------------------------

begin "node exits during start"
knob exit-at-start-publisher
run_check "$stub_cli"
assert_failed_at "publisher start"
assert_contains "$work/stderr" "exited"
end

begin "node never becomes ready"
knob deaf-publisher
# A sleep that returns at once, so the bounded wait is bounded in test time too.
mkdir "$work/fast"
printf '#!/bin/sh\nexit 0\n' >"$work/fast/sleep"
chmod +x "$work/fast/sleep"
check_path=$work/fast:$stubs:$PATH
run_check "$stub_cli"
assert_failed_at "publisher start"
assert_contains "$work/stderr" "not ready"
end

# --- A REST port that already answers is refused -----------------------------

# Scenario "Foreign server on the publisher's REST port". The stub CLI would
# exit at once if it were started, so only the refusal can produce "already
# answers" with no invocation.
begin "a foreign server on the publisher's REST port is refused"
knob foreign-everywhere
knob exit-at-start-publisher
run_check "$stub_cli"
assert_failed_at "publisher start"
assert_contains "$work/stderr" "already answers"
assert_line_count "$state/invocations" 0
# The port the check asked about, as the stub curl logged it.
probed_port=$(sed -n '1s|^GET http://127\.0\.0\.1:\([0-9]*\)/.*|\1|p' "$state/requests")
[ -n "$probed_port" ] || flunk "the check made no request before starting the publisher"
assert_contains "$work/stderr" "127.0.0.1:$probed_port"
end

# Scenario "Foreign server on a later node's REST port": nothing answers on the
# publisher's port, so the publisher starts; the fetcher's port is then taken.
begin "a foreign server on the fetcher's REST port is refused"
knob foreign-after-publisher
run_check "$stub_cli"
assert_failed_at "fetcher start"
assert_contains "$work/stderr" "already answers"
assert_contains "$work/stderr" "fetcher"
# Only the publisher was started.
assert_line_count "$state/invocations" 1
publisher_port=$(sed -n 1p "$state/invocations" | tr ' ' '\n' | sed -n 's/^--api-port=//p')
# The port the check asked about last, as the stub curl logged it.
probed_port=$(sed -n '$s|^GET http://127\.0\.0\.1:\([0-9]*\)/.*|\1|p' "$state/requests")
[ -n "$probed_port" ] || flunk "the last request was not a probe of a port"
[ "$probed_port" != "$publisher_port" ] || flunk "the refused port is the publisher's"
assert_contains "$work/stderr" "127.0.0.1:$probed_port"
end

# --- Content is published under the pinned values ----------------------------

begin "upload is refused"
knob upload-status-publisher 500
run_check "$stub_cli"
assert_failed_at upload
end

begin "upload returns no CID"
knob upload-empty-publisher
run_check "$stub_cli"
assert_failed_at upload
end

# --- The manifest carries the pinned values ----------------------------------

# Each mismatch body differs from a matching manifest in the one value its test
# names, so the diagnostic cannot come from another value's check.

begin "manifest reports another block size"
knob manifest-body '{"cid":"zX","manifest":{"blockSize":65536,"filename":"poc-payload.bin","mimetype":"application/octet-stream"}}'
run_check "$stub_cli"
assert_failed_at manifest
assert_contains "$work/stderr" "expected block size 131072"
assert_contains "$work/stderr" "reports 65536"
end

begin "manifest reports another filename"
knob manifest-body '{"cid":"zX","manifest":{"blockSize":131072,"filename":"other.bin","mimetype":"application/octet-stream"}}'
run_check "$stub_cli"
assert_failed_at manifest
assert_contains "$work/stderr" "expected filename poc-payload.bin"
assert_contains "$work/stderr" "reports other.bin"
end

begin "manifest reports no filename"
knob manifest-body '{"cid":"zX","manifest":{"blockSize":131072,"mimetype":"application/octet-stream"}}'
run_check "$stub_cli"
assert_failed_at manifest
assert_contains "$work/stderr" "expected filename poc-payload.bin"
end

begin "manifest reports another mimetype"
knob manifest-body '{"cid":"zX","manifest":{"blockSize":131072,"filename":"poc-payload.bin","mimetype":"application/x-www-form-urlencoded"}}'
run_check "$stub_cli"
assert_failed_at manifest
assert_contains "$work/stderr" "expected mimetype application/octet-stream"
assert_contains "$work/stderr" "reports application/x-www-form-urlencoded"
assert_line_count "$state/invocations" 1
end

begin "manifest reports no mimetype"
knob manifest-body '{"cid":"zX","manifest":{"blockSize":131072,"filename":"poc-payload.bin"}}'
run_check "$stub_cli"
assert_failed_at manifest
assert_contains "$work/stderr" "expected mimetype application/octet-stream"
assert_contains "$work/stderr" "reports none"
assert_line_count "$state/invocations" 1
end

begin "manifest request fails"
knob manifest-status 404
run_check "$stub_cli"
assert_failed_at manifest
end

begin "manifest cannot be parsed"
knob manifest-body 'not json at all'
run_check "$stub_cli"
assert_failed_at manifest
end

# Failure stops the run: after a failed manifest check no fetcher is started
# and no fetch is requested.
begin "a failed manifest check starts no fetcher"
knob manifest-status 500
run_check "$stub_cli"
assert_failed_at manifest
assert_line_count "$state/invocations" 1
assert_lacks "$state/requests" "/network/stream"
end

# --- The fetcher is ephemeral and does not advertise -------------------------

begin "fetch answers with an error"
knob fetch-status 404
run_check "$stub_cli"
assert_failed_at fetch
end

begin "download ends before the content is complete"
knob fetch-partial
run_check "$stub_cli"
assert_failed_at fetch
end

begin "publisher is gone when the fetcher asks"
knob kills-publisher-fetcher
run_check "$stub_cli"
assert_failed_at fetch
end

# --- Fetched content is verified against the original ------------------------

begin "fetched content differs"
knob fetch-corrupt
run_check "$stub_cli"
assert_failed_at verification
expected_sha256=$($real_sha256 <"$scratch/poc-payload.bin")
actual_sha256=$($real_sha256 <"$scratch/fetched.bin")
assert_contains "$work/stderr" "expected ${expected_sha256%% *}"
assert_contains "$work/stderr" "actual ${actual_sha256%% *}"
[ "${expected_sha256%% *}" != "${actual_sha256%% *}" ] || flunk "the stub did not corrupt the download"
end

begin "fetched content is truncated"
knob fetch-truncate
run_check "$stub_cli"
assert_failed_at verification
end

begin "sha256 tool fails on the fetched content"
check_path=$tests_dir/unit/broken-sha256:$stubs:$PATH
run_check "$stub_cli"
assert_failed_at verification
end

begin "sha256 tool prints nothing for the fetched content"
knob sha-prints-nothing
check_path=$tests_dir/unit/broken-sha256:$stubs:$PATH
run_check "$stub_cli"
assert_failed_at verification
end

# Both calls broken: a check that took "no digest" for a digest would find the
# two equal and pass. The check must fail before it ever uploads.
begin "sha256 tool fails on the test content"
knob sha-broken-from-first
check_path=$tests_dir/unit/broken-sha256:$stubs:$PATH
run_check "$stub_cli"
assert_failed_at "test content"
assert_line_count "$state/invocations" 0
end

begin "sha256 tool prints nothing for the test content"
knob sha-broken-from-first
knob sha-prints-nothing
check_path=$tests_dir/unit/broken-sha256:$stubs:$PATH
run_check "$stub_cli"
assert_failed_at "test content"
assert_line_count "$state/invocations" 0
end

# --- The CID reproduces, and changes with a pinned value ---------------------

begin "CID does not reproduce"
knob cid-salt-reproducer
run_check "$stub_cli"
assert_failed_at re-upload
recorded_cid=$(sed -n '1s/^publisher \([^ ]*\) .*/\1/p' "$state/uploads")
other_cid=$(sed -n '1s/^reproducer \([^ ]*\) .*/\1/p' "$state/uploads")
assert_contains "$work/stderr" "$recorded_cid"
assert_contains "$work/stderr" "$other_cid"
[ "$recorded_cid" != "$other_cid" ] || flunk "the stub reproduced the CID"
end

begin "second upload is refused"
knob upload-status-reproducer 500
run_check "$stub_cli"
assert_failed_at re-upload
end

begin "second upload returns no CID"
knob upload-empty-reproducer
run_check "$stub_cli"
assert_failed_at re-upload
end

begin "a changed filename gives the recorded CID"
knob cid-ignores-filename
run_check "$stub_cli"
assert_failed_at "changed filename upload"
end

begin "a changed block size gives the recorded CID"
knob cid-ignores-block-size
run_check "$stub_cli"
assert_failed_at "changed block size upload"
end

begin "changed-value uploads change exactly one value"
run_check "$stub_cli"
assert_status_zero
grep -v ' poc-payload.bin 131072 ' "$state/uploads" >"$work/changed-uploads"
assert_line_count "$work/changed-uploads" 2
grep ' poc-payload.bin ' "$work/changed-uploads" >"$work/changed-block-size"
grep ' 131072 ' "$work/changed-uploads" >"$work/changed-filename"
assert_line_count "$work/changed-block-size" 1
assert_line_count "$work/changed-filename" 1
end

# --- No node outlives the run; files stay in one scratch directory -----------
# Every test above ends with assert_no_node_left, after success and failure.

# The stub node sleeps 90 seconds through SIGTERM. A check that waits for it to
# give up takes that long and leaves it gone all the same, so the exit time is
# what shows the node was killed rather than waited for.
begin "a node that ignores SIGTERM is still stopped"
knob ignore-term-publisher
knob upload-status-publisher 500
started_at=$(date +%s)
run_check "$stub_cli"
elapsed=$(($(date +%s) - started_at))
assert_failed_at upload
[ "$elapsed" -lt 45 ] || flunk "the check took $elapsed seconds to exit; the node ignores SIGTERM for 90"
end

# interrupt_check SIGNAL: starts the check against a node that never becomes
# ready, sends it SIGNAL once the node is running, and sets status. The check is
# started under env --default-signal because a shell started in the background
# of a script ignores SIGINT and then cannot trap it.
interrupt_check() {
	reset_signals=
	env --default-signal=INT true 2>/dev/null && reset_signals="env --default-signal=INT"
	# shellcheck disable=SC2086
	PATH=$check_path STUB_STATE=$state STUB_REAL_SLEEP=$real_sleep \
		$reset_signals $shell_under_test "$check" --scratch-parent "$work/scratch" "$stub_cli" \
		>"$work/stdout" 2>"$work/stderr" &
	check_pid=$!
	waited=0
	while [ ! -f "$state/pids" ] && [ "$waited" -lt 20 ]; do
		sleep 1
		waited=$((waited + 1))
	done
	[ -f "$state/pids" ] || flunk "the check started no node within 20 seconds"
	kill -s "$1" "$check_pid"
	wait "$check_pid"
	status=$?
}

begin "SIGTERM stops the running node and exits non-zero"
knob deaf-publisher
interrupt_check TERM
assert_status_nonzero
assert_lacks "$work/stdout" "cid="
end

if env --default-signal=INT true 2>/dev/null; then
	begin "SIGINT stops the running node and exits non-zero"
	knob deaf-publisher
	interrupt_check INT
	assert_status_nonzero
	assert_lacks "$work/stdout" "cid="
	end
else
	printf 'skip SIGINT stops the running node and exits non-zero: env has no --default-signal\n'
fi

begin "logs survive a failure, and every file is under the scratch directory"
knob upload-status-publisher 500
run_check "$stub_cli"
assert_failed_at upload
assert_contains "$scratch/publisher/node.log" "stub storage node: publisher"
case $scratch in
"$work/scratch"/*) ;;
*) flunk "the scratch directory '$scratch' is not under the parent it was given" ;;
esac
# The scratch parent holds the one scratch directory and nothing else.
ls -A "$work/scratch" >"$work/scratch-entries"
assert_line_count "$work/scratch-entries" 1
end

# Scenario "Files survive a pass".
begin "the scratch directory is kept after a pass"
run_check "$stub_cli"
assert_status_zero
[ -f "$scratch/poc-payload.bin" ] || flunk "the test content is gone after a pass"
[ -f "$scratch/fetched.bin" ] || flunk "the fetched content is gone after a pass"
for node in publisher fetcher reproducer; do
	assert_contains "$scratch/$node/node.log" "stub storage node: $node"
done
end

# Scenario "Run leaves the tree untouched", for a pass: run from an empty
# directory, which is still empty, and the scratch parent gained one entry.
begin "a pass writes nothing outside the scratch directory"
mkdir "$work/cwd"
cd "$work/cwd" || exit 2
run_check "$stub_cli"
cd "$repo" || exit 2
assert_status_zero
ls -A "$work/cwd" >"$work/cwd-entries"
assert_line_count "$work/cwd-entries" 0
ls -A "$work/scratch" >"$work/scratch-entries"
assert_line_count "$work/scratch-entries" 1
end

# Scenario "Scratch directory is private". The mode is read with ls, whose
# first field is the expected ten characters, plus a marker some systems add.
begin "the scratch directory grants nothing to group or others"
run_check "$stub_cli"
assert_status_zero
mode=$(ls -ld -- "$scratch")
mode=${mode%% *}
case $mode in
drwx------ | drwx------. | drwx------+) ;;
*) flunk "the scratch directory's mode is $mode, expected drwx------" ;;
esac
end

# Scenario "Each run has its own scratch directory". The state is cleared
# between the runs so that the stub assigns its roles again.
begin "two runs with one scratch parent have two scratch directories"
run_check "$stub_cli"
assert_status_zero
first_scratch=$scratch
cksum "$first_scratch/poc-payload.bin" "$first_scratch/fetched.bin" \
	"$first_scratch/publisher/node.log" >"$work/first-run-files"
rm -rf "$state"
mkdir "$state"
run_check "$stub_cli"
assert_status_zero
[ "$scratch" != "$first_scratch" ] || flunk "both runs used $scratch"
ls -A "$work/scratch" >"$work/scratch-entries"
assert_line_count "$work/scratch-entries" 2
cksum "$first_scratch/poc-payload.bin" "$first_scratch/fetched.bin" \
	"$first_scratch/publisher/node.log" >"$work/first-run-files-after"
cmp -s "$work/first-run-files" "$work/first-run-files-after" ||
	flunk "the second run changed the first run's files"
end

# --- The caller chooses where the scratch directory is made ------------------
# run_check states a scratch parent of its own first; the one a test adds comes
# later on the command line and is the one the check uses.

begin "a scratch parent that does not exist is refused and named"
run_check --scratch-parent "$work/no-such-parent" "$stub_cli"
assert_failed_at scratch
assert_contains "$work/stderr" "$work/no-such-parent"
[ ! -e "$work/no-such-parent" ] || flunk "the check created the scratch parent"
assert_line_count "$state/invocations" 0
end

begin "a scratch parent that is a file is refused and named"
: >"$work/parent-file"
run_check --scratch-parent "$work/parent-file" "$stub_cli"
assert_failed_at scratch
assert_contains "$work/stderr" "$work/parent-file"
assert_line_count "$state/invocations" 0
end

# An empty scratch parent is not a directory; it must not come to mean the
# current directory.
begin "an empty scratch parent is refused"
mkdir "$work/cwd"
cd "$work/cwd" || exit 2
run_check --scratch-parent '' "$stub_cli"
cd "$repo" || exit 2
assert_failed_at scratch
assert_line_count "$state/invocations" 0
ls -A "$work/cwd" >"$work/cwd-entries"
assert_line_count "$work/cwd-entries" 0
end

begin "a scratch parent given with --scratch-parent holds the scratch directory"
mkdir "$work/chosen"
run_check --scratch-parent "$work/chosen" "$stub_cli"
assert_status_zero
case $scratch in
"$work/chosen"/*/*) flunk "the scratch directory '$scratch' is not a direct child of $work/chosen" ;;
"$work/chosen"/*) ;;
*) flunk "the scratch directory '$scratch' is not under $work/chosen" ;;
esac
ls -A "$work/chosen" >"$work/chosen-entries"
assert_line_count "$work/chosen-entries" 1
assert_line_count "$state/invocations" 3
end

begin "a relative scratch parent gives an absolute scratch directory"
cd "$work" || exit 2
run_check --scratch-parent scratch "$stub_cli"
cd "$repo" || exit 2
assert_status_zero
case $scratch in
"$work/scratch"/*) ;;
*) flunk "the scratch directory '$scratch' is not the absolute path of a child of $work/scratch" ;;
esac
end

begin "the scratch parent comes from TMPDIR when none is given"
mkdir "$work/from-env"
check_tmpdir=$work/from-env
run_check_bare "$stub_cli"
assert_status_zero
case $scratch in
"$work/from-env"/*) ;;
*) flunk "the scratch directory '$scratch' is not under TMPDIR $work/from-env" ;;
esac
end

# A directory may be named "-", which cd would read as "the previous directory".
begin "a scratch parent named - is a directory like any other"
mkdir -p "$work/cwd/-"
cd "$work/cwd" || exit 2
run_check --scratch-parent - "$stub_cli"
cd "$repo" || exit 2
assert_status_zero
case $scratch in
"$work/cwd/-"/*) ;;
*) flunk "the scratch directory '$scratch' is not under $work/cwd/-" ;;
esac
end

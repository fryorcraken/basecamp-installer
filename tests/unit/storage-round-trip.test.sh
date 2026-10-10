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
end

begin "named path does not exist"
run_check "$work/no-such-cli"
assert_failed_at "storage CLI"
assert_contains "$work/stderr" "$work/no-such-cli"
assert_line_count "$state/invocations" 0
end

begin "named path is not executable"
cp "$stub_cli" "$work/plain-file"
chmod a-x "$work/plain-file"
run_check "$work/plain-file"
assert_failed_at "storage CLI"
assert_contains "$work/stderr" "$work/plain-file"
assert_line_count "$state/invocations" 0
end

# The check must not search for a CLI: a bare name that is not a file here is
# refused even though PATH holds an executable of that name.
begin "a bare name is not looked up on PATH"
run_check storage
assert_failed_at "storage CLI"
assert_line_count "$state/invocations" 0
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
toolbox=$work/toolbox
mkdir "$toolbox"
for tool in "${shell_under_test%% *}" awk sed cmp wc mktemp cat mkdir sleep; do
	ln -s "$(command -v "$tool")" "$toolbox/$tool"
done
ln -s "$stubs/curl" "$toolbox/curl"
check_path=$toolbox
run_check "$stub_cli"
assert_failed_at tools
assert_contains "$work/stderr" "sha256"
assert_line_count "$state/invocations" 0
end

# --- Full pass ---------------------------------------------------------------

begin "full pass prints the four result lines"
run_check "$stub_cli"
assert_status_zero
recorded_cid=$(sed -n '1s/^publisher \([^ ]*\) .*/\1/p' "$state/uploads")
# Derived here from the file the check wrote, not from what the check printed.
expected_sha256=$($real_sha256 <"$scratch/poc-payload.bin")
expected_sha256=${expected_sha256%% *}
printf 'cid=%s\nfilename=poc-payload.bin\nblock_size=131072\nsha256=%s\n' \
	"$recorded_cid" "$expected_sha256" >"$work/expected-stdout"
[ -n "$recorded_cid" ] || flunk "the stub publisher recorded no upload"
cmp -s "$work/expected-stdout" "$work/stdout" ||
	flunk "stdout is: $(cat "$work/stdout"); expected: $(cat "$work/expected-stdout")"
end

begin "nodes are confined to localhost"
run_check "$stub_cli"
assert_status_zero
assert_line_count "$state/invocations" 3
sed -n 1p "$state/invocations" >"$work/publisher-args"
sed -n 2p "$state/invocations" >"$work/fetcher-args"
assert_contains "$work/publisher-args" "--no-bootstrap-node"
assert_lacks "$work/publisher-args" "--bootstrap-node="
assert_contains "$work/publisher-args" "--nat=extip:127.0.0.1"
assert_contains "$work/fetcher-args" "--nat=extip:127.0.0.1"
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

begin "uploads carry the pinned values"
run_check "$stub_cli"
assert_status_zero
sed -n 1p "$state/uploads" >"$work/first-upload"
assert_contains "$work/first-upload" " poc-payload.bin 131072 "
grep -F 'POST ' "$state/requests" | sed -n 1p >"$work/first-upload-request"
assert_contains "$work/first-upload-request" "blockSize=131072"
assert_contains "$work/first-upload-request" 'filename="poc-payload.bin"'
payload_size=$(wc -c <"$scratch/poc-payload.bin")
[ "$payload_size" -gt 131072 ] || flunk "the test content is $payload_size bytes, not more than one block"
[ $((payload_size % 131072)) -ne 0 ] || flunk "the test content is a whole number of blocks"
end

# NO SPEC: the spec pins the filename and the block size only, but the manifest
# also holds the mimetype, so it changes the CID too. Every upload states
# application/octet-stream.
begin "NO SPEC: every upload states the same mimetype"
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

# NO SPEC: the spec does not say what happens when something else already
# answers on a port the check is about to give a node. The check refuses to
# start the node, so a foreign server is never mistaken for it.
begin "NO SPEC: a foreign server on the REST port is refused"
knob foreign-everywhere
knob exit-at-start-publisher
run_check "$stub_cli"
assert_failed_at "publisher start"
assert_contains "$work/stderr" "already answers"
assert_line_count "$state/invocations" 0
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

begin "manifest reports another block size"
knob manifest-body '{"cid":"zX","manifest":{"blockSize":65536,"filename":"poc-payload.bin"}}'
run_check "$stub_cli"
assert_failed_at manifest
assert_contains "$work/stderr" "131072"
assert_contains "$work/stderr" "65536"
end

begin "manifest reports another filename"
knob manifest-body '{"cid":"zX","manifest":{"blockSize":131072,"filename":"other.bin"}}'
run_check "$stub_cli"
assert_failed_at manifest
assert_contains "$work/stderr" "poc-payload.bin"
assert_contains "$work/stderr" "other.bin"
end

begin "manifest reports no filename"
knob manifest-body '{"cid":"zX","manifest":{"blockSize":131072}}'
run_check "$stub_cli"
assert_failed_at manifest
assert_contains "$work/stderr" "expected filename poc-payload.bin"
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

begin "a node that ignores SIGTERM is still stopped"
knob ignore-term-publisher
knob upload-status-publisher 500
run_check "$stub_cli"
assert_failed_at upload
end

begin "SIGTERM stops the running node and exits non-zero"
knob deaf-publisher
# shellcheck disable=SC2086
PATH=$check_path STUB_STATE=$state STUB_REAL_SLEEP=$real_sleep \
	$shell_under_test "$check" --scratch-parent "$work/scratch" "$stub_cli" \
	>"$work/stdout" 2>"$work/stderr" &
check_pid=$!
waited=0
while [ ! -f "$state/pids" ] && [ "$waited" -lt 20 ]; do
	sleep 1
	waited=$((waited + 1))
done
[ -f "$state/pids" ] || flunk "the check started no node within 20 seconds"
kill -TERM "$check_pid"
wait "$check_pid"
status=$?
assert_status_nonzero
assert_lacks "$work/stdout" "cid="
end

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

# NO SPEC: the spec does not say whether the scratch directory survives a pass.
# It is left in place either way, so a pass can be inspected like a failure.
begin "NO SPEC: the scratch directory is kept after a pass"
run_check "$stub_cli"
assert_status_zero
[ -f "$scratch/fetched.bin" ] || flunk "the fetched content is gone after a pass"
end

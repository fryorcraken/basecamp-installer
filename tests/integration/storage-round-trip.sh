#!/bin/sh
# storage-round-trip.sh: publish a file on one Logos Storage node, fetch it by
# CID from a second, and reproduce the CID on a third, all on localhost.
#
# usage: storage-round-trip.sh [--scratch-parent DIR] [--] STORAGE_CLI
#
# The behaviour contract is the storage-round-trip capability spec; the
# reasons for the choices below are in the two-node-poc change's design.md.
# Diagnostics go to standard error as "storage-round-trip: <step>: <message>".
# Standard output carries the five result lines, and only on a full pass.

set -u
umask 077

PROGRAM=storage-round-trip

# A CID is the manifest CID, and the manifest holds the filename, the block
# size and the mimetype. All three are stated in every upload and checked in
# the publisher's manifest.
PINNED_FILENAME=poc-payload.bin
PINNED_BLOCK_SIZE=131072
PINNED_MIMETYPE=application/octet-stream
CHANGED_FILENAME=poc-payload-renamed.bin
CHANGED_BLOCK_SIZE=65536

# The test content is PAYLOAD_LINES lines of 35 bytes. 35 is odd, so the total
# is a whole number of 131072-byte blocks only if PAYLOAD_LINES is a multiple
# of 131072; write_payload checks the result rather than trusting this.
PAYLOAD_LINES=10000

# Every port of a run, in one place: distinct, and none of the reserved 8080
# (the CLI's REST default), 8090 and 8500 (the Basecamp storage module).
PUBLISHER_API_PORT=28481
PUBLISHER_LISTEN_PORT=28482
FETCHER_API_PORT=28483
FETCHER_LISTEN_PORT=28484
REPRODUCER_API_PORT=28485
REPRODUCER_LISTEN_PORT=28486

# Bounds, in seconds.
START_TIMEOUT=30
REQUEST_TIMEOUT=30
FETCH_TIMEOUT=60
STOP_TIMEOUT=10

storage_cli=
scratch_parent=${TMPDIR:-/tmp}
scratch=
node_pids=
request_pid=

note() {
	printf '%s: %s\n' "$PROGRAM" "$*" >&2
}

# fail STEP MESSAGE: the only way the check gives up. It must never be called
# inside a command substitution, where exit would leave only the subshell.
fail() {
	printf '%s: %s: %s\n' "$PROGRAM" "$1" "$2" >&2
	exit 1
}

# --- processes ---------------------------------------------------------------

# stop_node PID: ends one node and reaps it, with SIGKILL after STOP_TIMEOUT.
# A watchdog bounds the wait because a reaped-or-not child cannot be polled
# portably: kill -0 succeeds on a zombie.
stop_node() {
	remaining_pids=
	for known_pid in $node_pids; do
		[ "$known_pid" = "$1" ] || remaining_pids="$remaining_pids $known_pid"
	done
	node_pids=$remaining_pids

	kill "$1" 2>/dev/null
	(
		trap 'kill "$sleep_pid" 2>/dev/null; exit 0' TERM
		sleep "$STOP_TIMEOUT" &
		sleep_pid=$!
		wait "$sleep_pid"
		kill -KILL "$1" 2>/dev/null
	) >/dev/null 2>&1 &
	watchdog_pid=$!
	wait "$1" 2>/dev/null
	kill "$watchdog_pid" 2>/dev/null
	wait "$watchdog_pid" 2>/dev/null
	return 0
}

cleanup() {
	exit_status=$?
	trap '' INT TERM
	trap - EXIT
	[ -n "$request_pid" ] && kill "$request_pid" 2>/dev/null
	for node_pid in $node_pids; do
		stop_node "$node_pid"
	done
	exit "$exit_status"
}

# --- REST --------------------------------------------------------------------

# rest OUT_FILE MAX_SECONDS CURL_ARGUMENT...: one REST request.
# Returns curl's exit status, also left in rest_exit, and sets rest_status to
# the HTTP status, or to 000 when no answer came. curl runs in the background
# so that a trapped signal interrupts the wait instead of queueing behind it.
rest() {
	rest_out=$1
	rest_max=$2
	shift 2
	rest_status=000
	curl -q --silent --show-error --noproxy '*' --max-time "$rest_max" \
		--output "$rest_out" --write-out '%{http_code}' "$@" \
		>"$scratch/rest-status" 2>>"$scratch/curl-errors.log" &
	request_pid=$!
	wait "$request_pid"
	rest_exit=$?
	request_pid=
	rest_answer=$(cat "$scratch/rest-status" 2>/dev/null)
	case $rest_answer in
	[0-9][0-9][0-9]) rest_status=$rest_answer ;;
	esac
	return "$rest_exit"
}

# rest_ok STEP OUT_FILE MAX_SECONDS CURL_ARGUMENT...: a request that must be
# answered with HTTP 200, or the run fails at STEP.
rest_ok() {
	rest_step=$1
	shift
	rest "$@" ||
		fail "$rest_step" "request failed (curl exit $rest_exit, HTTP $rest_status); see $scratch/curl-errors.log"
	[ "$rest_status" = 200 ] ||
		fail "$rest_step" "node answered HTTP $rest_status; see $rest_out"
}

# --- nodes -------------------------------------------------------------------

# start_node NAME API_PORT LISTEN_PORT BOOTSTRAP_OPTION: starts one node
# confined to localhost, with an empty data directory, and waits until it
# accepts REST requests.
start_node() {
	node_name=$1
	node_api_port=$2
	node_dir=$scratch/$node_name
	node_step="$node_name start"

	if ! mkdir "$node_dir" || ! mkdir -m 700 "$node_dir/data"; then
		fail "$node_step" "cannot create $node_dir/data"
	fi

	# Guard: without it, a foreign server already on the API port would answer
	# the readiness poll for a node that died binding the port.
	if rest "$scratch/rest-discard" 2 "http://127.0.0.1:$node_api_port/"; then
		fail "$node_step" "something already answers on 127.0.0.1:$node_api_port, so the $node_name node cannot use it"
	fi

	"$storage_cli" \
		--data-dir="$node_dir/data" \
		--api-port="$node_api_port" \
		--listen-port="$3" \
		--listen-ip=127.0.0.1 \
		--nat=extip:127.0.0.1 \
		"$4" \
		>"$node_dir/node.log" 2>&1 &
	started_pid=$!
	node_pids="$node_pids $started_pid"

	waited=0
	while [ "$waited" -lt "$START_TIMEOUT" ]; do
		kill -0 "$started_pid" 2>/dev/null ||
			fail "$node_step" "the $node_name node exited before accepting REST requests; see $node_dir/node.log"
		if rest "$node_dir/spr" 2 --header 'Accept: text/plain' \
			"http://127.0.0.1:$node_api_port/api/storage/v1/spr" &&
			[ "$rest_status" = 200 ]; then
			return 0
		fi
		sleep 1
		waited=$((waited + 1))
	done
	fail "$node_step" "the $node_name node was not ready after $START_TIMEOUT seconds; see $node_dir/node.log"
}

# --- steps -------------------------------------------------------------------

parse_arguments() {
	while [ $# -gt 0 ]; do
		case $1 in
		--scratch-parent)
			[ $# -ge 2 ] || fail usage "--scratch-parent needs a directory"
			scratch_parent=$2
			shift 2
			;;
		--)
			shift
			break
			;;
		-*) fail usage "unknown option $1" ;;
		*) break ;;
		esac
	done
	[ $# -ge 1 ] && [ -n "$1" ] ||
		fail usage "a storage CLI is required: $PROGRAM.sh [--scratch-parent DIR] [--] STORAGE_CLI"
	[ $# -eq 1 ] || fail usage "exactly one storage CLI is expected, got $#"
	storage_cli=$1
}

require_storage_cli() {
	[ -f "$storage_cli" ] && [ -x "$storage_cli" ] ||
		fail "storage CLI" "$storage_cli is not an executable file"
	# A name with no slash would be looked up on PATH, which is a search.
	case $storage_cli in
	*/*) ;;
	*) storage_cli=./$storage_cli ;;
	esac
}

require_tools() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256_tool=sha256sum
	elif command -v shasum >/dev/null 2>&1; then
		sha256_tool=shasum
	else
		fail tools "no sha256 tool: neither sha256sum nor shasum is available"
	fi
	for tool in curl awk sed cmp wc mktemp; do
		command -v "$tool" >/dev/null 2>&1 || fail tools "$tool is not available"
	done
}

create_scratch() {
	# cd reads the operand "-" as "the previous directory", and refuses an
	# empty one in some shells only. Neither reaches it.
	case $scratch_parent in
	'') fail scratch "the scratch parent is empty, which is not a directory" ;;
	/*) parent_to_enter=$scratch_parent ;;
	*) parent_to_enter=./$scratch_parent ;;
	esac
	# An absolute path, so the printed directory means the same from anywhere.
	# It goes to its own variable: the diagnostic needs the path as given.
	absolute_parent=$(CDPATH='' cd -- "$parent_to_enter" 2>/dev/null && pwd) ||
		fail scratch "$scratch_parent is not a directory"
	scratch=$(mktemp -d "$absolute_parent/$PROGRAM.XXXXXX") && [ -d "$scratch" ] ||
		fail scratch "cannot create a scratch directory under $absolute_parent"
	note "scratch directory: $scratch"
}

# sha256_of FILE: sets sha256 to the file's digest. Fails when the tool fails
# or prints anything that does not start with 64 hex digits.
sha256_of() {
	sha256=
	case $sha256_tool in
	sha256sum) sha256_output=$(sha256sum <"$1" 2>/dev/null) || return 1 ;;
	shasum) sha256_output=$(shasum -a 256 <"$1" 2>/dev/null) || return 1 ;;
	*) return 1 ;;
	esac
	sha256=${sha256_output%%[!0-9a-f]*}
	[ "${#sha256}" -eq 64 ]
}

write_payload() {
	payload=$scratch/$PINNED_FILENAME
	awk -v lines="$PAYLOAD_LINES" \
		'BEGIN { for (i = 0; i < lines; i++) printf "%07d storage-round-trip payload\n", i }' \
		>"$payload" || fail "test content" "cannot write $payload"
	payload_size=$(wc -c <"$payload")
	payload_size=$((payload_size + 0))
	[ "$payload_size" -gt "$PINNED_BLOCK_SIZE" ] &&
		[ $((payload_size % PINNED_BLOCK_SIZE)) -ne 0 ] ||
		fail "test content" "$payload_size bytes is not more than one block of $PINNED_BLOCK_SIZE and a partial one"
	sha256_of "$payload" || fail "test content" "cannot compute the sha256 of $payload"
	payload_sha256=$sha256
}

# upload STEP API_PORT FILENAME BLOCK_SIZE: uploads the test content and sets
# uploaded_cid. The CID is later placed in a URL, so anything but letters and
# digits is refused here.
upload() {
	rest_ok "$1" "$scratch/upload-response" "$REQUEST_TIMEOUT" \
		--header "Content-Type: $PINNED_MIMETYPE" \
		--header "Content-Disposition: attachment; filename=\"$3\"" \
		--data-binary "@$payload" \
		"http://127.0.0.1:$2/api/storage/v1/data?blockSize=$4"
	uploaded_cid=$(cat "$scratch/upload-response" 2>/dev/null)
	case $uploaded_cid in
	'' | *[!A-Za-z0-9]*) fail "$1" "the node returned no usable CID; see $scratch/upload-response" ;;
	esac
}

read_publisher_spr() {
	publisher_spr=$(cat "$scratch/publisher/spr" 2>/dev/null)
	case $publisher_spr in
	spr:*[!A-Za-z0-9_=-]*) publisher_spr= ;;
	spr:?*) ;;
	*) publisher_spr= ;;
	esac
	[ -n "$publisher_spr" ] ||
		fail "publisher start" "the publisher returned no usable peer record; see $scratch/publisher/spr"
}

check_manifest() {
	manifest=$scratch/manifest.json
	rest_ok manifest "$manifest" "$REQUEST_TIMEOUT" \
		"http://127.0.0.1:$PUBLISHER_API_PORT/api/storage/v1/data/$cid/network/manifest"
	reported_block_size=$(sed -n \
		's/.*"blockSize"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$manifest")
	reported_filename=$(sed -n \
		's/.*"filename"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest")
	reported_mimetype=$(sed -n \
		's/.*"mimetype"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest")
	[ -n "$reported_block_size" ] ||
		fail manifest "cannot parse the manifest; see $manifest"
	[ "$reported_block_size" = "$PINNED_BLOCK_SIZE" ] ||
		fail manifest "expected block size $PINNED_BLOCK_SIZE, the manifest reports $reported_block_size"
	[ "$reported_filename" = "$PINNED_FILENAME" ] ||
		fail manifest "expected filename $PINNED_FILENAME, the manifest reports ${reported_filename:-none}"
	[ "$reported_mimetype" = "$PINNED_MIMETYPE" ] ||
		fail manifest "expected mimetype $PINNED_MIMETYPE, the manifest reports ${reported_mimetype:-none}"
}

fetch() {
	fetched=$scratch/fetched.bin
	rest_ok fetch "$fetched" "$FETCH_TIMEOUT" \
		"http://127.0.0.1:$FETCHER_API_PORT/api/storage/v1/data/$cid/network/stream?advertise=false"
}

verify_fetched() {
	sha256_of "$fetched" ||
		fail verification "cannot compute the sha256 of the fetched content"
	[ "$sha256" = "$payload_sha256" ] ||
		fail verification "sha256 mismatch: expected $payload_sha256, actual $sha256"
	cmp -s "$payload" "$fetched" ||
		fail verification "the fetched content is not byte-for-byte the test content"
}

check_cid_reproduces() {
	upload re-upload "$REPRODUCER_API_PORT" "$PINNED_FILENAME" "$PINNED_BLOCK_SIZE"
	[ "$uploaded_cid" = "$cid" ] ||
		fail re-upload "the CID does not reproduce: recorded $cid, re-upload returned $uploaded_cid"
}

check_cid_changes() {
	upload "changed filename upload" "$REPRODUCER_API_PORT" "$CHANGED_FILENAME" "$PINNED_BLOCK_SIZE"
	[ "$uploaded_cid" != "$cid" ] ||
		fail "changed filename upload" "changing the filename to $CHANGED_FILENAME still returned the recorded CID $cid"
	upload "changed block size upload" "$REPRODUCER_API_PORT" "$PINNED_FILENAME" "$CHANGED_BLOCK_SIZE"
	[ "$uploaded_cid" != "$cid" ] ||
		fail "changed block size upload" "changing the block size to $CHANGED_BLOCK_SIZE still returned the recorded CID $cid"
}

main() {
	parse_arguments "$@"
	require_storage_cli
	require_tools

	trap cleanup EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM

	create_scratch
	write_payload

	start_node publisher "$PUBLISHER_API_PORT" "$PUBLISHER_LISTEN_PORT" --no-bootstrap-node
	read_publisher_spr
	upload upload "$PUBLISHER_API_PORT" "$PINNED_FILENAME" "$PINNED_BLOCK_SIZE"
	cid=$uploaded_cid
	note "recorded CID $cid"
	check_manifest

	start_node fetcher "$FETCHER_API_PORT" "$FETCHER_LISTEN_PORT" "--bootstrap-node=$publisher_spr"
	fetcher_pid=$started_pid
	fetch
	stop_node "$fetcher_pid"
	verify_fetched

	# The reproducer has no bootstrap node, so it cannot have obtained the
	# content from the publisher: an equal CID comes from the bytes alone.
	start_node reproducer "$REPRODUCER_API_PORT" "$REPRODUCER_LISTEN_PORT" --no-bootstrap-node
	check_cid_reproduces
	check_cid_changes

	printf 'cid=%s\nfilename=%s\nblock_size=%s\nmimetype=%s\nsha256=%s\n' \
		"$cid" "$PINNED_FILENAME" "$PINNED_BLOCK_SIZE" "$PINNED_MIMETYPE" "$payload_sha256"
}

main "$@"

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
# The scratch directory and every file written under it, the node logs and the
# fetched content included, grant nothing to group or others.
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
# They are fixed, so two runs at once on one machine collide, and so does any
# other test that later picks a port from 28481 to 28486.
PUBLISHER_API_PORT=28481
PUBLISHER_LISTEN_PORT=28482
FETCHER_API_PORT=28483
FETCHER_LISTEN_PORT=28484
REPRODUCER_API_PORT=28485
REPRODUCER_LISTEN_PORT=28486

# Bounds. A node's start is bounded by a number of readiness attempts, each
# one request of at most PROBE_TIMEOUT seconds and a pause of POLL_INTERVAL;
# the rest are seconds.
START_ATTEMPTS=30
POLL_INTERVAL=1
PROBE_TIMEOUT=2
REQUEST_TIMEOUT=30
FETCH_TIMEOUT=60
STOP_TIMEOUT=10

# Variables. POSIX sh has no "local": every variable is global. A function's
# working variables are therefore named after the function or the thing it
# handles (launch_name, ready_dir, rest_max, reported_filename), and a new one
# must not take a name another function uses. The names that are shared on
# purpose are the six set just below, and these results, each set by the
# function named and read by its callers:
#   rest_exit, rest_status          rest
#   last_started_pid                launch_node
#   sha256_tool                     require_tools
#   sha256                          sha256_of
#   payload, payload_sha256         write_payload
#   uploaded_cid                    upload
#   publisher_spr                   read_publisher_spr
storage_cli=
scratch_parent=${TMPDIR:-/tmp}
scratch=
node_pids=
request_pid=
watchdog_pid=

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

# forget_node PID: takes one pid off the list cleanup walks. A node that was
# stopped and reaped must leave the list: cleanup would otherwise signal its
# pid again, and the kernel may have given that number to an unrelated process
# since.
forget_node() {
	remaining_pids=
	for known_pid in $node_pids; do
		[ "$known_pid" = "$1" ] || remaining_pids="$remaining_pids $known_pid"
	done
	node_pids=$remaining_pids
}

# stop_node PID: ends one node and reaps it, with SIGKILL after STOP_TIMEOUT.
# A watchdog bounds the wait because a reaped-or-not child cannot be polled
# portably: kill -0 succeeds on a zombie. The node is forgotten only once the
# wait has returned: a signal that interrupts the wait runs cleanup, which must
# still find the node on the list and stop it.
stop_node() {
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
	forget_node "$1"
	kill "$watchdog_pid" 2>/dev/null
	wait "$watchdog_pid" 2>/dev/null
	watchdog_pid=
	return 0
}

# cleanup: the EXIT trap. It ignores INT and TERM while it runs, on purpose: a
# second Ctrl-C must not cut the stopping short and leave a node running. The
# wait this costs is bounded by STOP_TIMEOUT for each node. It then exits with
# the status the run ended with, which the calls below would otherwise replace.
cleanup() {
	exit_status=$?
	trap '' INT TERM
	trap - EXIT
	[ -n "$request_pid" ] && kill "$request_pid" 2>/dev/null
	# A stop that a signal interrupted left its watchdog behind; the stop is
	# done again below with a watchdog of its own.
	[ -n "$watchdog_pid" ] && kill "$watchdog_pid" 2>/dev/null
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
# curl's error text for every request is appended to one file, curl-errors.log.
# A run that passes leaves refusals there: the probe of each node's port before
# its start is meant to be refused, and so is each readiness poll before the
# node listens. The text a failure refers to is at the end of the file.
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
	rest_ok_step=$1
	rest_ok_out=$2
	shift
	rest "$@" ||
		fail "$rest_ok_step" "request failed (curl exit $rest_exit, HTTP $rest_status); see $scratch/curl-errors.log"
	[ "$rest_status" = 200 ] ||
		fail "$rest_ok_step" "node answered HTTP $rest_status; see $rest_ok_out"
}

# --- nodes -------------------------------------------------------------------

# require_silent_port NAME API_PORT: fails unless nothing answers an HTTP
# request on the REST port the NAME node is about to be given. Without it, a
# foreign server already on that port would answer the readiness poll for a
# node that died binding the port, and the run would carry on against it.
require_silent_port() {
	if rest "$scratch/rest-discard" "$PROBE_TIMEOUT" "http://127.0.0.1:$2/"; then
		fail "$1 start" "something already answers on 127.0.0.1:$2, so the $1 node cannot use it"
	fi
}

# launch_node NAME API_PORT LISTEN_PORT BOOTSTRAP_OPTION: starts one node
# confined to localhost on a new, empty data directory, and sets
# last_started_pid. It does not wait for the node.
launch_node() {
	launch_name=$1
	launch_api_port=$2
	launch_listen_port=$3
	launch_bootstrap_option=$4
	launch_dir=$scratch/$launch_name

	# The umask already gives the data directory mode 700; -m states it so
	# that it does not rest on the umask line. The node does not refuse a
	# looser directory: it logs a warning and tightens the mode itself.
	if ! mkdir "$launch_dir" || ! mkdir -m 700 "$launch_dir/data"; then
		fail "$launch_name start" "cannot create $launch_dir/data"
	fi

	"$storage_cli" \
		--data-dir="$launch_dir/data" \
		--api-port="$launch_api_port" \
		--listen-port="$launch_listen_port" \
		--listen-ip=127.0.0.1 \
		--api-bindaddr=127.0.0.1 \
		--nat=extip:127.0.0.1 \
		"$launch_bootstrap_option" \
		>"$launch_dir/node.log" 2>&1 &
	last_started_pid=$!
	node_pids="$node_pids $last_started_pid"
}

# wait_until_ready NAME PID API_PORT: returns once the node answers a REST
# request, and fails when it exits first or the bounded wait ends. The answer,
# the node's signed peer record, is left in the node's directory as "spr".
wait_until_ready() {
	ready_name=$1
	ready_pid=$2
	ready_api_port=$3
	ready_dir=$scratch/$ready_name

	ready_attempts=0
	while [ "$ready_attempts" -lt "$START_ATTEMPTS" ]; do
		kill -0 "$ready_pid" 2>/dev/null ||
			fail "$ready_name start" "the $ready_name node exited before accepting REST requests; see $ready_dir/node.log"
		if rest "$ready_dir/spr" "$PROBE_TIMEOUT" --header 'Accept: text/plain' \
			"http://127.0.0.1:$ready_api_port/api/storage/v1/spr" &&
			[ "$rest_status" = 200 ]; then
			return 0
		fi
		sleep "$POLL_INTERVAL"
		ready_attempts=$((ready_attempts + 1))
	done
	fail "$ready_name start" "the $ready_name node was not ready after $ready_attempts attempts, which is at most $((START_ATTEMPTS * (PROBE_TIMEOUT + POLL_INTERVAL))) seconds; see $ready_dir/node.log"
}

# start_node NAME API_PORT LISTEN_PORT BOOTSTRAP_OPTION: one node, from a
# silent port to a ready REST API. It sets last_started_pid, which holds until
# the next start_node: a caller that needs the pid copies it at once.
start_node() {
	require_silent_port "$1" "$2"
	launch_node "$1" "$2" "$3" "$4"
	wait_until_ready "$1" "$last_started_pid" "$2"
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
	# Not every command the check runs. curl and mktemp are, with the sha256
	# tool above, the tools outside POSIX; awk, sed, cmp and wc are POSIX and
	# checked all the same. cat, sleep, mkdir and env are run without a check
	# here, and a PATH that lacks one fails at the step that needs it.
	for required_tool in curl awk sed cmp wc mktemp; do
		command -v "$required_tool" >/dev/null 2>&1 ||
			fail tools "$required_tool is not available"
	done
}

# clear_storage_environment: removes every STORAGE_ variable from this shell,
# so no node it starts inherits one. The storage CLI takes any of its options
# from such a variable: STORAGE_API_BINDADDR=0.0.0.0 would otherwise serve
# every node's REST API on all interfaces while the run still passed.
# It is called once, before any node, so no launch can forget it.
clear_storage_environment() {
	for storage_variable in $(env | sed -n 's/^\(STORAGE_[A-Za-z0-9_]*\)=.*/\1/p'); do
		unset "$storage_variable"
	done
	# Guard: unset cannot remove a name that is not a shell identifier, and
	# env cannot tell a variable from a line inside another one's value. Both
	# leave a STORAGE_ line here, and the run stops rather than guess.
	storage_leftover=$(env | sed -n 's/^\(STORAGE_[^=]*\).*/\1/p')
	[ -z "$storage_leftover" ] ||
		fail environment "cannot remove from the nodes' environment: $storage_leftover"
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
	# Not a no-op: BSD wc pads the count with spaces, which the arithmetic
	# drops. The tests below and the diagnostic need the bare number.
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

# read_publisher_spr: sets publisher_spr to the peer record the readiness poll
# left behind. The record becomes the fetcher's only bootstrap node, so
# anything that is not "spr:" and a base64url body is refused here, where the
# failure names the publisher. Let through, an error page or a truncated
# record would start a fetcher that finds no provider, and the run would fail
# a fetch timeout later, blamed on the fetch.
read_publisher_spr() {
	publisher_spr=$(cat "$scratch/publisher/spr" 2>/dev/null)
	spr_body=${publisher_spr#spr:}
	# The first pattern is the record itself: equal means there was no prefix.
	case $spr_body in
	"$publisher_spr" | '' | *[!A-Za-z0-9_=-]*)
		fail "publisher start" "the publisher returned no usable peer record; see $scratch/publisher/spr"
		;;
	esac
}

# check_manifest CID: fails unless the publisher's manifest for CID reports
# the three pinned values.
check_manifest() {
	manifest_file=$scratch/manifest.json
	rest_ok manifest "$manifest_file" "$REQUEST_TIMEOUT" \
		"http://127.0.0.1:$PUBLISHER_API_PORT/api/storage/v1/data/$1/network/manifest"
	# sed, not jq: jq is not on a stock desktop. The patterns assume what the
	# node sends, one line of JSON in which each of the three keys appears
	# once. Anything else yields no value or a wrong one, and both fail below.
	reported_block_size=$(sed -n \
		's/.*"blockSize"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$manifest_file")
	reported_filename=$(sed -n \
		's/.*"filename"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest_file")
	reported_mimetype=$(sed -n \
		's/.*"mimetype"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest_file")
	[ -n "$reported_block_size" ] ||
		fail manifest "cannot parse the manifest; see $manifest_file"
	[ "$reported_block_size" = "$PINNED_BLOCK_SIZE" ] ||
		fail manifest "expected block size $PINNED_BLOCK_SIZE, the manifest reports $reported_block_size"
	[ "$reported_filename" = "$PINNED_FILENAME" ] ||
		fail manifest "expected filename $PINNED_FILENAME, the manifest reports ${reported_filename:-none}"
	[ "$reported_mimetype" = "$PINNED_MIMETYPE" ] ||
		fail manifest "expected mimetype $PINNED_MIMETYPE, the manifest reports ${reported_mimetype:-none}"
}

# fetch CID OUT_FILE: streams CID from the fetcher into OUT_FILE.
fetch() {
	rest_ok fetch "$2" "$FETCH_TIMEOUT" \
		"http://127.0.0.1:$FETCHER_API_PORT/api/storage/v1/data/$1/network/stream?advertise=false"
}

# verify_fetched FETCHED_FILE ORIGINAL_FILE EXPECTED_SHA256
verify_fetched() {
	sha256_of "$1" ||
		fail verification "cannot compute the sha256 of the fetched content"
	[ "$sha256" = "$3" ] ||
		fail verification "sha256 mismatch: expected $3, actual $sha256"
	cmp -s "$2" "$1" ||
		fail verification "the fetched content is not byte-for-byte the test content"
}

# check_cid_reproduces CID: the pinned upload to the reproducer returns CID.
check_cid_reproduces() {
	upload re-upload "$REPRODUCER_API_PORT" "$PINNED_FILENAME" "$PINNED_BLOCK_SIZE"
	[ "$uploaded_cid" = "$1" ] ||
		fail re-upload "the CID does not reproduce: recorded $1, re-upload returned $uploaded_cid"
}

# check_cid_changes CID: an upload with one pinned value changed does not
# return CID.
check_cid_changes() {
	upload "changed filename upload" "$REPRODUCER_API_PORT" "$CHANGED_FILENAME" "$PINNED_BLOCK_SIZE"
	[ "$uploaded_cid" != "$1" ] ||
		fail "changed filename upload" "changing the filename to $CHANGED_FILENAME still returned the recorded CID $1"
	upload "changed block size upload" "$REPRODUCER_API_PORT" "$PINNED_FILENAME" "$CHANGED_BLOCK_SIZE"
	[ "$uploaded_cid" != "$1" ] ||
		fail "changed block size upload" "changing the block size to $CHANGED_BLOCK_SIZE still returned the recorded CID $1"
}

main() {
	parse_arguments "$@"
	require_storage_cli
	require_tools
	clear_storage_environment

	trap cleanup EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM

	create_scratch
	write_payload

	start_node publisher "$PUBLISHER_API_PORT" "$PUBLISHER_LISTEN_PORT" --no-bootstrap-node
	read_publisher_spr
	upload upload "$PUBLISHER_API_PORT" "$PINNED_FILENAME" "$PINNED_BLOCK_SIZE"
	# Copied because every later upload overwrites uploaded_cid: this is the
	# CID the reproducer's answers are compared with.
	recorded_cid=$uploaded_cid
	note "recorded CID $recorded_cid"
	check_manifest "$recorded_cid"

	start_node fetcher "$FETCHER_API_PORT" "$FETCHER_LISTEN_PORT" "--bootstrap-node=$publisher_spr"
	fetcher_pid=$last_started_pid
	fetched=$scratch/fetched.bin
	fetch "$recorded_cid" "$fetched"
	# The fetcher is stopped here, not left to cleanup: it holds the content
	# now, and must be gone before the reproducer starts, so that no node but
	# the publisher holds it while the CID is reproduced.
	stop_node "$fetcher_pid"
	verify_fetched "$fetched" "$payload" "$payload_sha256"

	# The reproducer has no bootstrap node, so it cannot have obtained the
	# content from the publisher: an equal CID comes from the bytes alone.
	start_node reproducer "$REPRODUCER_API_PORT" "$REPRODUCER_LISTEN_PORT" --no-bootstrap-node
	check_cid_reproduces "$recorded_cid"
	check_cid_changes "$recorded_cid"

	printf 'cid=%s\nfilename=%s\nblock_size=%s\nmimetype=%s\nsha256=%s\n' \
		"$recorded_cid" "$PINNED_FILENAME" "$PINNED_BLOCK_SIZE" "$PINNED_MIMETYPE" "$payload_sha256"
}

main "$@"

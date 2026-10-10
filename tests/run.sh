#!/bin/sh
# Unit suite: runs the round-trip check against a stub storage CLI and a stub
# curl. It sees the check's own logic and every failure path. It cannot see a
# real node: only tests/integration/storage-round-trip.sh run against a built
# storage CLI does that.
#
# usage: sh tests/run.sh [SHELL]
#   SHELL is the POSIX shell the check is run with (default: sh), for example
#   "busybox sh" or dash.

# stub_cli and scratch are read by the sourced test file.
# shellcheck disable=SC2034

set -u

tests_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd) || exit 2
repo=$(dirname -- "$tests_dir")
check=$tests_dir/integration/storage-round-trip.sh
stubs=$tests_dir/unit/stubs
stub_cli=$stubs/storage
shell_under_test=${1:-sh}

# Absolute paths: some tests put a fake of the same name earlier on PATH.
real_sleep=$(command -v sleep)
if command -v sha256sum >/dev/null 2>&1; then
	real_sha256=$(command -v sha256sum)
else
	real_sha256="$(command -v shasum) -a 256"
fi

mkdir -p "$repo/tmp"
suite_dir=$(mktemp -d "$repo/tmp/unit.XXXXXX") || exit 2

tests_run=0
failures=0
test_name=

# begin NAME: a fresh state directory for the stubs and a fresh scratch parent.
begin() {
	tests_run=$((tests_run + 1))
	test_name=$1
	work=$suite_dir/$tests_run
	state=$work/state
	mkdir -p "$state" "$work/scratch"
	check_path=$stubs:$PATH
	test_failed=0
}

# knob NAME [CONTENT]: sets one stub knob for the current test.
knob() {
	printf '%s\n' "${2:-}" >"$state/$1"
}

# run_check ARGUMENT...: runs the check to completion; sets status, and
# scratch to the directory it printed.
run_check() {
	# The shell command may be two words, as in "busybox sh".
	# shellcheck disable=SC2086
	PATH=$check_path STUB_STATE=$state STUB_REAL_SLEEP=$real_sleep \
		STUB_REAL_SHA256=$real_sha256 \
		$shell_under_test "$check" --scratch-parent "$work/scratch" "$@" \
		>"$work/stdout" 2>"$work/stderr"
	status=$?
	scratch=$(sed -n 's/^storage-round-trip: scratch directory: //p' "$work/stderr")
}

flunk() {
	[ "$test_failed" -eq 0 ] && failures=$((failures + 1))
	test_failed=1
	printf 'FAIL %s: %s\n' "$test_name" "$*"
}

assert_status_zero() {
	[ "$status" -eq 0 ] || flunk "expected exit 0, got $status: $(cat "$work/stderr")"
}

assert_status_nonzero() {
	[ "$status" -ne 0 ] || flunk "expected a non-zero exit, got 0"
}

# assert_contains FILE TEXT: FILE holds a line containing the fixed TEXT.
assert_contains() {
	grep -F -- "$2" "$1" >/dev/null 2>&1 ||
		flunk "$(basename "$1") lacks '$2'; it holds: $(cat "$1" 2>/dev/null)"
}

assert_lacks() {
	if grep -F -- "$2" "$1" >/dev/null 2>&1; then
		flunk "$(basename "$1") holds '$2'"
	fi
}

assert_empty_file() {
	[ -f "$1" ] || flunk "$(basename "$1") does not exist"
	[ ! -s "$1" ] || flunk "$(basename "$1") is not empty: $(cat "$1")"
}

assert_line_count() {
	count=0
	[ -f "$1" ] && count=$(grep -c '' "$1")
	[ "$count" -eq "$2" ] || flunk "$(basename "$1") has $count lines, expected $2"
}

# A failed run names its step on standard error and prints no result line.
assert_failed_at() {
	assert_status_nonzero
	assert_contains "$work/stderr" "storage-round-trip: $1:"
	assert_lacks "$work/stdout" "cid="
}

# No stub node the check started may still be running once it has exited.
assert_no_node_left() {
	[ -f "$state/pids" ] || return 0
	while read -r stub_pid; do
		kill -0 "$stub_pid" 2>/dev/null && flunk "stub node $stub_pid is still running"
	done <"$state/pids"
}

end() {
	assert_no_node_left
	[ "$test_failed" -eq 0 ] && printf 'ok   %s\n' "$test_name"
}

# shellcheck source=tests/unit/storage-round-trip.test.sh
. "$tests_dir/unit/storage-round-trip.test.sh"

printf '%s tests, %s failed\n' "$tests_run" "$failures"
if [ "$failures" -ne 0 ]; then
	printf 'state kept in %s\n' "$suite_dir"
	exit 1
fi
rm -rf "$suite_dir"

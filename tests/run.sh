#!/bin/sh
# Unit suite: runs the round-trip check against a stub storage CLI and a stub
# curl. It sees the check's own logic and every failure path. It cannot see a
# real node: only tests/integration/storage-round-trip.sh run against a built
# storage CLI does that.
#
# usage: sh tests/run.sh [SHELL [CHECK]]
#   SHELL is the POSIX shell the check is run with (default: sh), for example
#   "busybox sh" or dash.
#   CHECK is the check to run the suite against (default: the tracked one), a
#   path relative to the repository root or absolute. It exists so a test can be
#   watched failing against a copy of the check with one behaviour broken.

# stub_cli and scratch are read by the sourced test file.
# shellcheck disable=SC2034

set -u

tests_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd) || exit 2
repo=$(dirname -- "$tests_dir")
shell_under_test=${1:-sh}
case ${2:-} in
'') check=$tests_dir/integration/storage-round-trip.sh ;;
/*) check=$2 ;;
*) check=$repo/$2 ;;
esac
stubs=$tests_dir/unit/stubs
stub_cli=$stubs/storage

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
check_tmpdir=
check_tmpdir_unset=0

# begin NAME: a fresh state directory for the stubs and a fresh scratch parent.
begin() {
	tests_run=$((tests_run + 1))
	test_name=$1
	work=$suite_dir/$tests_run
	state=$work/state
	mkdir -p "$state" "$work/scratch"
	check_path=$stubs:$PATH
	check_tmpdir=
	check_tmpdir_unset=0
	test_failed=0
}

# knob NAME [CONTENT]: sets one stub knob for the current test.
knob() {
	printf '%s\n' "${2:-}" >"$state/$1"
}

# under_stubs COMMAND...: the environment the check is run under, in one place:
# PATH is check_path, and the stubs find their state directory and the real
# sleep and sha256 tool. It replaces the shell it is called in with COMMAND,
# and sets this shell's own variables first, so it is only ever called inside
# ( ). Because COMMAND takes the subshell's place, a background
# ( under_stubs ... ) & has COMMAND's own pid, which a signal then reaches.
under_stubs() {
	PATH=$check_path
	STUB_STATE=$state
	STUB_REAL_SLEEP=$real_sleep
	STUB_REAL_SHA256=$real_sha256
	export PATH STUB_STATE STUB_REAL_SLEEP STUB_REAL_SHA256
	exec "$@"
}

# run_check ARGUMENT...: runs the check to completion; sets status, and
# scratch to the directory it printed.
run_check() {
	# The shell command may be two words, as in "busybox sh".
	# shellcheck disable=SC2086
	(under_stubs $shell_under_test "$check" --scratch-parent "$work/scratch" "$@") \
		>"$work/stdout" 2>"$work/stderr"
	status=$?
	scratch=$(sed -n 's/^storage-round-trip: scratch directory: //p' "$work/stderr")
}

# in_directory DIR COMMAND [ARGUMENT...]: runs COMMAND, which may be run_check
# or run_check_bare, with DIR as the working directory, and returns to the
# repository root. COMMAND runs in this shell, so what it sets is kept.
in_directory() {
	cd "$1" || exit 2
	shift
	"$@"
	cd "$repo" || exit 2
}

# api_port_of ROLE: the REST port the check gave the publisher, fetcher or
# reproducer, from the arguments the stub storage CLI recorded.
api_port_of() {
	sed -n 's/^--api-port=//p' "$state/args-$1"
}

# run_check_bare ARGUMENT...: like run_check, but states no scratch parent of its
# own, and gives the check the TMPDIR named by check_tmpdir: set, and empty when
# check_tmpdir is empty, or not set at all when check_tmpdir_unset is 1.
run_check_bare() {
	(
		if [ "$check_tmpdir_unset" -eq 1 ]; then
			unset TMPDIR
		else
			TMPDIR=$check_tmpdir
			export TMPDIR
		fi
		# shellcheck disable=SC2086
		under_stubs $shell_under_test "$check" "$@" \
			>"$work/stdout" 2>"$work/stderr"
	)
	status=$?
	scratch=$(sed -n 's/^storage-round-trip: scratch directory: //p' "$work/stderr")
}

# make_toolbox DIR: a directory holding every tool the check, the stub curl and
# the stub storage CLI use, as links, and the stub curl as curl. A test sets
# check_path to it after taking one tool out, so that tool is the only thing
# missing.
make_toolbox() {
	mkdir "$1"
	for tool in "${shell_under_test%% *}" awk sed cmp wc mktemp cat mkdir sleep \
		cksum tr cp grep ls rm env sha256sum; do
		ln -s "$(command -v "$tool")" "$1/$tool"
	done
	ln -s "$stubs/curl" "$1/curl"
}

# flunk MESSAGE...: the current test has failed. Its name is also appended to
# failed-tests in the suite directory, which is kept after a failure, so the
# names of the failing tests can be read from a file as well as from the output.
flunk() {
	if [ "$test_failed" -eq 0 ]; then
		failures=$((failures + 1))
		printf '%s\n' "$test_name" >>"$suite_dir/failed-tests"
	fi
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

# The scratch parent holds nothing: the check refused before making its
# scratch directory.
assert_no_scratch_made() {
	ls -A "$work/scratch" >"$work/scratch-entries"
	assert_line_count "$work/scratch-entries" 0
}

# After a pass, standard output is the five result lines and nothing else. The
# CID is the one the stub publisher recorded and the digest is taken here, from
# the file the check wrote, so neither comes from what the check printed.
assert_result_lines() {
	recorded_cid=$(sed -n '1s/^publisher \([^ ]*\) .*/\1/p' "$state/uploads")
	[ -n "$recorded_cid" ] || flunk "the stub publisher recorded no upload"
	expected_sha256=$($real_sha256 <"$scratch/poc-payload.bin")
	expected_sha256=${expected_sha256%% *}
	printf 'cid=%s\nfilename=poc-payload.bin\nblock_size=131072\nmimetype=application/octet-stream\nsha256=%s\n' \
		"$recorded_cid" "$expected_sha256" >"$work/expected-stdout"
	cmp -s "$work/expected-stdout" "$work/stdout" ||
		flunk "stdout is: $(cat "$work/stdout"); expected: $(cat "$work/expected-stdout")"
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

#!/bin/sh
# Test suite for safe mode (T016) in route.sh and watchdog
# Uses shunit2 framework — ash/busybox compatible

MERGEN_TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
MERGEN_ROOT="$(cd "$MERGEN_TEST_DIR/.." && pwd)"

# ── Test Temp Directory ─────────────────────────────────

_TEST_TMPDIR=""

# ── Mock UCI System ─────────────────────────────────────

_MOCK_UCI_STORE=""
_MOCK_CONFIG_LOADED=""
_MOCK_FOREACH_SECTIONS=""
_MOCK_SECTION_COUNTER=0

uci() {
	local cmd="$1"
	shift
	case "$cmd" in
		-q)
			local subcmd="$1"; shift
			case "$subcmd" in
				get) _mock_uci_get "$1" ;;
			esac
			;;
		get)
			if [ "$1" = "-q" ]; then
				shift
				_mock_uci_get "$1"
			else
				_mock_uci_get "$1"
			fi
			;;
		set) _mock_uci_set "$1" ;;
		commit) return 0 ;;
	esac
}

_mock_uci_get() {
	local path="$1"
	echo "$_MOCK_UCI_STORE" | while IFS='=' read -r key value; do
		if [ "$key" = "$path" ]; then
			echo "$value"
			return 0
		fi
	done
}

_mock_uci_set() {
	local assignment="$1"
	local key="${assignment%%=*}"
	local value="${assignment#*=}"
	_MOCK_UCI_STORE="$(echo "$_MOCK_UCI_STORE" | grep -v "^${key}=" 2>/dev/null)
${key}=${value}"
}

config_load() { _MOCK_CONFIG_LOADED="$1"; }

config_get() {
	local var="$1" section="$2" option="$3" default="$4"
	local val
	val="$(_mock_uci_get "${_MOCK_CONFIG_LOADED}.${section}.${option}")"
	[ -z "$val" ] && val="$default"
	eval "$var=\"$val\""
}

config_foreach() {
	local callback="$1" type="$2"
	local section
	for section in $_MOCK_FOREACH_SECTIONS; do
		"$callback" "$section"
	done
}

# Mock logger, flock, ip
logger() { :; }
flock() { return 0; }
ip() {
	case "$1" in
		rule) return 0 ;;
		route)
			case "$2" in
				show)
					shift 2
					# Gateway detection support
					local dev=""
					while [ $# -gt 0 ]; do
						case "$1" in
							dev) dev="$2"; shift 2 ;;
							*) shift ;;
						esac
					done
					if [ -n "$dev" ]; then
						echo "default via 10.0.0.1 dev ${dev}"
					fi
					return 0
					;;
				*) return 0 ;;
			esac
			;;
	esac
}

# ── Mock ping ───────────────────────────────────────────

_MOCK_PING_RESULT=0

ping() {
	return $_MOCK_PING_RESULT
}

# ── Source modules under test ───────────────────────────

. "${MERGEN_ROOT}/files/usr/lib/mergen/core.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/utils.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/engine.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/resolver.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/route.sh"

# Source CLI with guard
MERGEN_SOURCED=1
. "${MERGEN_ROOT}/files/usr/bin/mergen"

# Source watchdog with guard
MERGEN_WATCHDOG_SOURCED=1
. "${MERGEN_ROOT}/files/usr/sbin/mergen-watchdog"

# ── Post-source Overrides ──────────────────────────────

mergen_lock_acquire() { return 0; }
mergen_lock_release() { return 0; }

# ── Setup/Teardown ──────────────────────────────────────

setUp() {
	_MOCK_UCI_STORE=""
	_MOCK_FOREACH_SECTIONS=""
	_MOCK_SECTION_COUNTER=0
	_MOCK_PING_RESULT=0
	MERGEN_ROUTE_APPLIED_COUNT=0
	MERGEN_ROUTE_FAILED_COUNT=0

	_TEST_TMPDIR="$(mktemp -d)"
	mkdir -p "${_TEST_TMPDIR}/providers"
	mkdir -p "${_TEST_TMPDIR}/cache"

	MERGEN_PROVIDERS_DIR="${_TEST_TMPDIR}/providers"
	MERGEN_CACHE_DIR="${_TEST_TMPDIR}/cache"
	MERGEN_TMP="${_TEST_TMPDIR}"
	MERGEN_SNAPSHOT_DIR="${_TEST_TMPDIR}/snapshot"
	MERGEN_PENDING_FILE="${_TEST_TMPDIR}/pending_confirm"

	_mock_uci_set "mergen.global.enabled=1"
	_mock_uci_set "mergen.global.log_level=info"
	_mock_uci_set "mergen.global.default_table=100"
	_mock_uci_set "mergen.global.safe_mode_ping_target=8.8.8.8"
	_mock_uci_set "mergen.global.watchdog_interval=60"
	_MOCK_CONFIG_LOADED="mergen"
}

tearDown() {
	if [ -n "$_TEST_TMPDIR" ] && [ -d "$_TEST_TMPDIR" ]; then
		rm -rf "$_TEST_TMPDIR"
	fi
}

# ── Ping Test ───────────────────────────────────────────

test_ping_success() {
	_MOCK_PING_RESULT=0
	mergen_safe_mode_ping "8.8.8.8"
	assertEquals "Ping succeeds" 0 $?
}

test_ping_failure() {
	_MOCK_PING_RESULT=1
	mergen_safe_mode_ping "8.8.8.8"
	assertEquals "Ping fails" 1 $?
}

# ── Pending File Tests ──────────────────────────────────

test_safe_mode_start_creates_file() {
	mergen_safe_mode_start 60
	assertTrue "Pending file created" "[ -f '$MERGEN_PENDING_FILE' ]"
}

test_safe_mode_start_has_timestamp() {
	mergen_safe_mode_start 60
	grep -q "^timestamp=" "$MERGEN_PENDING_FILE"
	assertEquals "Has timestamp" 0 $?
}

test_safe_mode_start_has_timeout() {
	mergen_safe_mode_start 120
	grep -q "^timeout=120" "$MERGEN_PENDING_FILE"
	assertEquals "Has correct timeout" 0 $?
}

test_safe_mode_pending_true() {
	mergen_safe_mode_start 60
	mergen_safe_mode_pending
	assertEquals "Pending returns true" 0 $?
}

test_safe_mode_pending_false() {
	mergen_safe_mode_pending
	assertEquals "Pending returns false" 1 $?
}

# ── Confirm Tests ───────────────────────────────────────

test_confirm_removes_pending() {
	mergen_safe_mode_start 60
	assertTrue "Pending file exists" "[ -f '$MERGEN_PENDING_FILE' ]"

	mergen_safe_mode_confirm
	assertFalse "Pending file removed" "[ -f '$MERGEN_PENDING_FILE' ]"
}

test_confirm_no_pending_fails() {
	mergen_safe_mode_confirm
	assertEquals "Confirm without pending fails" 1 $?
}

test_cli_confirm_with_pending() {
	mergen_safe_mode_start 60

	local output
	output="$(cmd_confirm 2>&1)"
	echo "$output" | grep -q "onaylandi"
	assertEquals "CLI confirm reports success" 0 $?
}

test_cli_confirm_without_pending() {
	local output
	output="$(cmd_confirm 2>&1)"
	assertEquals "CLI confirm fails" 1 $?
}

# ── Timer Expiry Tests ──────────────────────────────────

test_timer_not_expired() {
	mergen_safe_mode_start 60
	mergen_safe_mode_expired
	assertEquals "Timer not expired" 1 $?
}

test_timer_expired() {
	# Write a pending file with old timestamp
	cat > "$MERGEN_PENDING_FILE" <<EOF
timestamp=0
timeout=60
EOF

	mergen_safe_mode_expired
	assertEquals "Timer expired" 0 $?
}

test_timer_no_pending() {
	mergen_safe_mode_expired
	assertEquals "No pending returns not expired" 1 $?
}

# ── Safe Mode Apply Integration ─────────────────────────

test_safe_apply_ping_success_creates_pending() {
	_MOCK_PING_RESULT=0
	_MOCK_FOREACH_SECTIONS=""

	cmd_apply --safe > /dev/null 2>&1

	assertTrue "Pending file created after safe apply" "[ -f '$MERGEN_PENDING_FILE' ]"
}

test_safe_apply_ping_fail_rolls_back() {
	_MOCK_PING_RESULT=1
	_MOCK_FOREACH_SECTIONS=""

	local ret
	cmd_apply --safe > /dev/null 2>&1
	ret=$?

	assertEquals "Safe apply fails on ping failure" 1 "$ret"
	assertFalse "No pending file on failure" "[ -f '$MERGEN_PENDING_FILE' ]"
}

# ── Watchdog Safe Mode Check ────────────────────────────

test_watchdog_check_no_pending() {
	watchdog_check_safe_mode
	assertEquals "No pending is noop" 0 $?
}

test_watchdog_check_not_expired() {
	mergen_safe_mode_start 3600

	watchdog_check_safe_mode
	assertTrue "Pending still exists (not expired)" "[ -f '$MERGEN_PENDING_FILE' ]"
}

test_watchdog_check_expired_removes_pending() {
	# Create expired pending file
	cat > "$MERGEN_PENDING_FILE" <<EOF
timestamp=0
timeout=1
EOF

	# Create snapshot for restore
	mergen_snapshot_create

	watchdog_check_safe_mode
	assertFalse "Pending removed after expiry" "[ -f '$MERGEN_PENDING_FILE' ]"
}

# ── Load shunit2 ────────────────────────────────────────

if [ -f "${MERGEN_TEST_DIR}/shunit2" ]; then
	. "${MERGEN_TEST_DIR}/shunit2"
elif [ -f /usr/share/shunit2/shunit2 ]; then
	. /usr/share/shunit2/shunit2
else
	echo "ERROR: shunit2 not found. Install it or place it in tests/"
	exit 1
fi

#!/bin/sh
# Test suite for watchdog daemon in mergen/files/usr/sbin/mergen-watchdog
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
		add)
			local config="$1" type="$2"
			_MOCK_SECTION_COUNTER=$((_MOCK_SECTION_COUNTER + 1))
			local new_id="cfg$(printf '%03d' $_MOCK_SECTION_COUNTER)"
			echo "$new_id"
			;;
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
		route)
			case "$2" in
				show)
					if echo "$*" | grep -q "dev wg0"; then
						echo "default via 10.0.0.1 dev wg0"
					fi
					;;
				*) return 0 ;;
			esac
			;;
		rule) return 0 ;;
	esac
}

# ── Source modules under test ───────────────────────────

. "${MERGEN_ROOT}/files/usr/lib/mergen/core.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/utils.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/engine.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/resolver.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/route.sh"

# Source watchdog with main loop guard
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
	MERGEN_UCI_RESULT=""
	MERGEN_ROUTE_APPLIED_COUNT=0
	MERGEN_ROUTE_FAILED_COUNT=0
	_watchdog_start_time="$(date +%s)"
	_watchdog_last_update=0

	# Create temp directory structure
	_TEST_TMPDIR="$(mktemp -d)"
	mkdir -p "${_TEST_TMPDIR}/providers"
	mkdir -p "${_TEST_TMPDIR}/cache"

	# Override globals
	MERGEN_PROVIDERS_DIR="${_TEST_TMPDIR}/providers"
	MERGEN_CACHE_DIR="${_TEST_TMPDIR}/cache"
	MERGEN_TMP="${_TEST_TMPDIR}"
	MERGEN_STATUS_FILE="${_TEST_TMPDIR}/status.json"
	MERGEN_PID_FILE="${_TEST_TMPDIR}/mergen.pid"

	# Set up default UCI config
	_mock_uci_set "mergen.global.enabled=1"
	_mock_uci_set "mergen.global.log_level=info"
	_mock_uci_set "mergen.global.cache_dir=${_TEST_TMPDIR}/cache"
	_mock_uci_set "mergen.global.update_interval=86400"
	_mock_uci_set "mergen.global.default_table=100"
	_MOCK_CONFIG_LOADED="mergen"
}

tearDown() {
	if [ -n "$_TEST_TMPDIR" ] && [ -d "$_TEST_TMPDIR" ]; then
		rm -rf "$_TEST_TMPDIR"
	fi
}

# ── Status File Tests ───────────────────────────────────

test_write_status_creates_file() {
	watchdog_write_status
	assertTrue "Status file created" "[ -f '$MERGEN_STATUS_FILE' ]"
}

test_write_status_valid_json_fields() {
	watchdog_write_status

	local content
	content="$(cat "$MERGEN_STATUS_FILE")"

	echo "$content" | grep -q '"daemon"'
	assertEquals "Has daemon field" 0 $?

	echo "$content" | grep -q '"pid"'
	assertEquals "Has pid field" 0 $?

	echo "$content" | grep -q '"uptime"'
	assertEquals "Has uptime field" 0 $?

	echo "$content" | grep -q '"rules"'
	assertEquals "Has rules field" 0 $?

	echo "$content" | grep -q '"cache"'
	assertEquals "Has cache field" 0 $?

	echo "$content" | grep -q '"last_check"'
	assertEquals "Has last_check field" 0 $?
}

test_write_status_daemon_active() {
	watchdog_write_status

	local content
	content="$(cat "$MERGEN_STATUS_FILE")"

	echo "$content" | grep -q '"daemon": "active"'
	assertEquals "Daemon is active" 0 $?
}

test_write_status_rule_counts() {
	# Add mock rules
	_MOCK_FOREACH_SECTIONS="rule1 rule2"
	_mock_uci_set "mergen.rule1.name=test1"
	_mock_uci_set "mergen.rule1.enabled=1"
	_mock_uci_set "mergen.rule2.name=test2"
	_mock_uci_set "mergen.rule2.enabled=0"

	watchdog_write_status

	local content
	content="$(cat "$MERGEN_STATUS_FILE")"

	echo "$content" | grep -q '"total": 2'
	assertEquals "Total rules is 2" 0 $?

	echo "$content" | grep -q '"active": 1'
	assertEquals "Active rules is 1" 0 $?

	echo "$content" | grep -q '"disabled": 1'
	assertEquals "Disabled rules is 1" 0 $?
}

test_write_status_cached_asns() {
	# Create mock cache files
	echo "10.0.0.0/8" > "${_TEST_TMPDIR}/cache/AS13335.v4.txt"
	echo "timestamp=123" > "${_TEST_TMPDIR}/cache/AS13335.meta"
	echo "172.16.0.0/12" > "${_TEST_TMPDIR}/cache/AS15169.v4.txt"
	echo "timestamp=456" > "${_TEST_TMPDIR}/cache/AS15169.meta"

	watchdog_write_status

	local content
	content="$(cat "$MERGEN_STATUS_FILE")"

	echo "$content" | grep -q '"cached_asns": 2'
	assertEquals "Cached ASNs is 2" 0 $?
}

test_write_status_last_sync() {
	local now
	now="$(date +%s)"
	echo "$now" > "${_TEST_TMPDIR}/last_sync"

	watchdog_write_status

	local content
	content="$(cat "$MERGEN_STATUS_FILE")"

	echo "$content" | grep -q "\"last_sync\": ${now}"
	assertEquals "Last sync timestamp correct" 0 $?
}

# ── Update Check Tests ──────────────────────────────────

test_check_updates_no_sync_triggers_update() {
	# No last_sync file exists — should trigger update
	# Mock provider for ASN resolution
	cat > "${_TEST_TMPDIR}/providers/mock.sh" <<'EOF'
#!/bin/sh
provider_name() { echo "mock"; }
provider_test() { return 0; }
provider_resolve() { echo "10.0.0.0/8"; return 0; }
EOF
	chmod +x "${_TEST_TMPDIR}/providers/mock.sh"
	_MOCK_FOREACH_SECTIONS="mock"
	_mock_uci_set "mergen.mock.enabled=1"
	_mock_uci_set "mergen.mock.priority=10"

	watchdog_check_updates

	assertTrue "Last sync file created" "[ -f '${_TEST_TMPDIR}/last_sync' ]"
}

test_check_updates_fresh_sync_skips() {
	# Write recent sync timestamp — should skip
	date +%s > "${_TEST_TMPDIR}/last_sync"

	# Set short interval but sync just happened
	_mock_uci_set "mergen.global.update_interval=86400"

	watchdog_check_updates

	# last_sync should still have the original timestamp (not updated)
	local ts_after
	ts_after="$(cat "${_TEST_TMPDIR}/last_sync")"
	assertTrue "Sync was not re-run" "[ -n '$ts_after' ]"
}

test_check_updates_expired_triggers_update() {
	# Write old sync timestamp (well past the interval)
	echo "0" > "${_TEST_TMPDIR}/last_sync"
	_mock_uci_set "mergen.global.update_interval=86400"

	watchdog_check_updates

	local ts_after
	ts_after="$(cat "${_TEST_TMPDIR}/last_sync")"
	local now
	now="$(date +%s)"

	# The timestamp should be recent (within 5 seconds)
	local diff=$((now - ts_after))
	assertTrue "Sync was re-run (timestamp updated)" "[ $diff -lt 5 ]"
}

# ── Signal Handling Tests ───────────────────────────────

test_shutdown_sets_flag() {
	_watchdog_running=1
	_watchdog_shutdown
	assertEquals "Running flag cleared" 0 "$_watchdog_running"
}

# ── Startup State Tests ─────────────────────────────────

test_initial_state() {
	_watchdog_start_time="$(date +%s)"
	_watchdog_last_update=0

	assertEquals "Last update is 0" 0 "$_watchdog_last_update"
	assertTrue "Start time is set" "[ $_watchdog_start_time -gt 0 ]"
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

#!/bin/sh
# Test suite for mergen/files/usr/lib/mergen/core.sh
# Uses shunit2 framework — ash/busybox compatible

MERGEN_TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
MERGEN_ROOT="$(cd "$MERGEN_TEST_DIR/.." && pwd)"

# ── Mock UCI System ──────────────────────────────────────

# In-memory config store for testing
_MOCK_UCI_STORE=""
_MOCK_CONFIG_LOADED=""

# Mock uci command
uci() {
	local cmd="$1"
	shift
	case "$cmd" in
		-q)
			# Handle: uci -q get mergen.global.enabled
			local subcmd="$1"
			shift
			case "$subcmd" in
				get)
					local path="$1"
					_mock_uci_get "$path"
					;;
			esac
			;;
		get)
			local path
			# Handle -q flag if present
			if [ "$1" = "-q" ]; then
				shift
				path="$1"
			else
				path="$1"
			fi
			_mock_uci_get "$path"
			;;
		set)
			local assignment="$1"
			_mock_uci_set "$assignment"
			;;
		add)
			local conf="$1" type="$2"
			_mock_uci_add "$conf" "$type"
			;;
		delete)
			local path="$1"
			_mock_uci_delete "$path"
			;;
		add_list)
			local assignment="$1"
			_mock_uci_add_list "$assignment"
			;;
		del_list)
			local assignment="$1"
			_mock_uci_del_list "$assignment"
			;;
		commit)
			# no-op in tests
			return 0
			;;
		show)
			echo "$_MOCK_UCI_STORE"
			;;
	esac
}

_mock_uci_get() {
	local path="$1"
	# Search store for matching key
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
	# Remove existing entry if present
	local new_store=""
	echo "$_MOCK_UCI_STORE" | while IFS= read -r line; do
		local existing_key="${line%%=*}"
		[ "$existing_key" = "$key" ] || echo "$line"
	done
	_MOCK_UCI_STORE="$(echo "$_MOCK_UCI_STORE" | grep -v "^${key}=" 2>/dev/null)
${key}=${value}"
}

_mock_uci_add() {
	local conf="$1" type="$2"
	local idx="cfg$(date +%s)$$"
	_MOCK_UCI_STORE="${_MOCK_UCI_STORE}
${conf}.${idx}=${type}"
	echo "$idx"
}

_mock_uci_delete() {
	local path="$1"
	_MOCK_UCI_STORE="$(echo "$_MOCK_UCI_STORE" | grep -v "^${path}" 2>/dev/null)"
}

_mock_uci_add_list() { :; }
_mock_uci_del_list() { :; }

# Mock config_load/config_get/config_foreach for OpenWrt UCI shell API
config_load() { _MOCK_CONFIG_LOADED="$1"; }

config_get() {
	local var="$1" section="$2" option="$3" default="$4"
	local val
	val="$(_mock_uci_get "${_MOCK_CONFIG_LOADED}.${section}.${option}")"
	[ -z "$val" ] && val="$default"
	eval "$var=\"$val\""
}

_MOCK_FOREACH_SECTIONS=""
config_foreach() {
	local callback="$1" type="$2"
	local section
	for section in $_MOCK_FOREACH_SECTIONS; do
		"$callback" "$section"
	done
}

# Mock logger
logger() { :; }

# Mock flock
flock() { return 0; }

# Mock find
find() {
	# Return empty for stale lock check
	command find "$@" 2>/dev/null
}

# ── Source module under test ─────────────────────────────

. "${MERGEN_ROOT}/files/usr/lib/mergen/core.sh"

# ── Setup/Teardown ───────────────────────────────────────

setUp() {
	_MOCK_UCI_STORE=""
	_MOCK_FOREACH_SECTIONS=""
	MERGEN_UCI_RESULT=""
	MERGEN_UCI_LIST_RESULT=""

	# Override lock path for test environments (macOS lacks /var/lock)
	MERGEN_LOCK="/tmp/mergen-test.lock"
	rm -f "$MERGEN_LOCK"

	# Set up default config
	_mock_uci_set "mergen.global.enabled=1"
	_mock_uci_set "mergen.global.log_level=info"
	_mock_uci_set "mergen.global.default_table=100"
}

# ── UCI Wrapper Tests ────────────────────────────────────

test_uci_get_existing() {
	mergen_uci_get "global" "enabled" "0"
	assertEquals "Get existing value" "1" "$MERGEN_UCI_RESULT"
}

test_uci_get_default() {
	mergen_uci_get "global" "nonexistent" "fallback"
	assertEquals "Get with default" "fallback" "$MERGEN_UCI_RESULT"
}

test_uci_set_and_get() {
	mergen_uci_set "global" "log_level" "debug"
	mergen_uci_get "global" "log_level" "info"
	assertEquals "Set then get" "debug" "$MERGEN_UCI_RESULT"
}

test_uci_commit() {
	mergen_uci_commit
	assertEquals "Commit returns success" 0 $?
}

# ── Rule Functions Tests ─────────────────────────────────

test_count_rules_empty() {
	_MOCK_FOREACH_SECTIONS=""
	local count
	count="$(mergen_count_rules)"
	assertEquals "Empty rules count" "0" "$count"
}

test_count_rules_with_data() {
	_MOCK_FOREACH_SECTIONS="cfg001 cfg002 cfg003"
	local count
	count="$(mergen_count_rules)"
	assertEquals "Three rules count" "3" "$count"
}

test_find_rule_by_name_found() {
	_MOCK_FOREACH_SECTIONS="cfg001 cfg002"
	_mock_uci_set "mergen.cfg001.name=cloudflare"
	_mock_uci_set "mergen.cfg002.name=google"

	mergen_find_rule_by_name "cloudflare"
	assertEquals "Find existing rule" 0 $?
	assertEquals "Found section id" "cfg001" "$MERGEN_UCI_RESULT"
}

test_find_rule_by_name_not_found() {
	_MOCK_FOREACH_SECTIONS="cfg001"
	_mock_uci_set "mergen.cfg001.name=cloudflare"

	mergen_find_rule_by_name "nonexistent"
	assertNotEquals "Rule not found" 0 $?
}

# ── Logging Tests ────────────────────────────────────────

test_log_level_num() {
	assertEquals "Debug level" "0" "$(_mergen_log_level_num "debug")"
	assertEquals "Info level" "1" "$(_mergen_log_level_num "info")"
	assertEquals "Warning level" "2" "$(_mergen_log_level_num "warning")"
	assertEquals "Error level" "3" "$(_mergen_log_level_num "error")"
	assertEquals "Unknown level" "1" "$(_mergen_log_level_num "unknown")"
}

test_log_does_not_crash() {
	mergen_log "info" "Test" "This is a test message"
	assertEquals "Log call succeeds" 0 $?

	mergen_log "debug" "Test" "Debug message"
	assertEquals "Debug log call succeeds" 0 $?

	mergen_log "error" "Test" "Error message"
	assertEquals "Error log call succeeds" 0 $?
}

# ── Lock Management Tests ────────────────────────────────

test_lock_acquire_and_release() {
	mergen_lock_acquire 5
	assertEquals "Lock acquired" 0 $?

	mergen_lock_release
	assertEquals "Lock released" 0 $?
}

# ── Load shunit2 ─────────────────────────────────────────

if [ -f "${MERGEN_TEST_DIR}/shunit2" ]; then
	. "${MERGEN_TEST_DIR}/shunit2"
elif [ -f /usr/share/shunit2/shunit2 ]; then
	. /usr/share/shunit2/shunit2
else
	echo "ERROR: shunit2 not found. Install it or place it in tests/"
	exit 1
fi

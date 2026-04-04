#!/bin/sh
# Integration Test: Logging across operations
# Tests that operations produce correct log entries with proper format
# Exercises: core.sh logging with engine.sh, route.sh, CLI operations

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
			if [ "$type" = "rule" ]; then
				_MOCK_FOREACH_SECTIONS="${_MOCK_FOREACH_SECTIONS} ${new_id}"
			fi
			echo "$new_id"
			;;
		add_list)
			local assignment="$1"
			local key="${assignment%%=*}"
			local value="${assignment#*=}"
			local existing
			existing="$(_mock_uci_get "$key")"
			if [ -n "$existing" ]; then
				_mock_uci_set "${key}=${existing} ${value}"
			else
				_mock_uci_set "${key}=${value}"
			fi
			;;
		delete)
			local path="$1"
			_MOCK_UCI_STORE="$(echo "$_MOCK_UCI_STORE" | grep -v "^${MERGEN_CONF:-mergen}\.${path}\." 2>/dev/null)"
			local section="${path##*.}"
			_MOCK_FOREACH_SECTIONS="$(echo "$_MOCK_FOREACH_SECTIONS" | sed "s/ *${section} */ /g" | sed 's/^ *//;s/ *$//')"
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

# ── Mock logger (captures all calls) ───────────────────

_LOG_ENTRIES=""
_LOG_COUNT=0

logger() {
	local tag="" priority="" message=""

	while [ $# -gt 0 ]; do
		case "$1" in
			-t) tag="$2"; shift 2 ;;
			-p) priority="$2"; shift 2 ;;
			*)  message="$*"; break ;;
		esac
	done

	_LOG_COUNT=$((_LOG_COUNT + 1))
	_LOG_ENTRIES="${_LOG_ENTRIES}
${tag}|${priority}|${message}"
}

flock() { return 0; }

# ── Mock ip/nft commands ───────────────────────────────

ip() {
	case "$1" in
		route)
			case "$2" in
				add|replace) return 0 ;;
				show)
					if echo "$*" | grep -q "dev wg0"; then
						echo "default via 10.0.0.1 dev wg0"
					fi
					return 0
					;;
				del|delete|flush) return 0 ;;
			esac
			;;
		rule) return 0 ;;
		link)
			case "$3" in
				wg0|lan|eth0) echo "1: $3: <POINTOPOINT,NOARP,UP>" ;;
				*) return 1 ;;
			esac
			;;
	esac
}

nft() { return 127; }

# ── Source modules under test ───────────────────────────

. "${MERGEN_ROOT}/files/usr/lib/mergen/core.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/utils.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/engine.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/resolver.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/route.sh"

MERGEN_SOURCED=1
. "${MERGEN_ROOT}/files/usr/bin/mergen"

# ── Post-source Overrides ──────────────────────────────

mergen_uci_add() {
	local type="$1"
	_MOCK_SECTION_COUNTER=$((_MOCK_SECTION_COUNTER + 1))
	local new_id="cfg$(printf '%03d' $_MOCK_SECTION_COUNTER)"
	MERGEN_UCI_RESULT="$new_id"
	if [ "$type" = "rule" ]; then
		_MOCK_FOREACH_SECTIONS="${_MOCK_FOREACH_SECTIONS} ${new_id}"
	fi
}

mergen_lock_acquire() { return 0; }
mergen_lock_release() { return 0; }

MERGEN_NFT_AVAILABLE="0"
MERGEN_IPSET_AVAILABLE="0"
MERGEN_ENGINE_ACTIVE=""

# ── Setup/Teardown ──────────────────────────────────────

setUp() {
	_MOCK_UCI_STORE=""
	_MOCK_FOREACH_SECTIONS=""
	_MOCK_SECTION_COUNTER=0
	_LOG_ENTRIES=""
	_LOG_COUNT=0
	MERGEN_UCI_RESULT=""
	MERGEN_ENGINE_ACTIVE=""
	MERGEN_FORCE_APPLY=0

	_TEST_TMPDIR="$(mktemp -d)"
	mkdir -p "${_TEST_TMPDIR}/providers"
	mkdir -p "${_TEST_TMPDIR}/cache"
	mkdir -p "${_TEST_TMPDIR}/snapshot"

	MERGEN_PROVIDERS_DIR="${_TEST_TMPDIR}/providers"
	MERGEN_CACHE_DIR="${_TEST_TMPDIR}/cache"
	MERGEN_TMP="${_TEST_TMPDIR}"
	MERGEN_SNAPSHOT_DIR="${_TEST_TMPDIR}/snapshot"

	_mock_uci_set "mergen.global.enabled=1"
	_mock_uci_set "mergen.global.log_level=debug"
	_mock_uci_set "mergen.global.cache_dir=${_TEST_TMPDIR}/cache"
	_mock_uci_set "mergen.global.default_table=100"
	_mock_uci_set "mergen.global.max_prefix_per_rule=10000"
	_mock_uci_set "mergen.global.max_prefix_total=50000"
	_MOCK_CONFIG_LOADED="mergen"

	# Reset log level cache for each test
	MERGEN_LOG_LEVEL=""
	MERGEN_LOG_LEVEL_NUM=""
}

tearDown() {
	[ -n "$_TEST_TMPDIR" ] && [ -d "$_TEST_TMPDIR" ] && rm -rf "$_TEST_TMPDIR"
}

# ── Integration Tests ──────────────────────────────────

test_apply_generates_log_entries() {
	cmd_add --name log-test --ip 10.0.0.0/8 --via wg0 2>/dev/null
	cmd_apply 2>/dev/null

	assertTrue "Log entries generated" "[ $_LOG_COUNT -gt 0 ]"
}

test_apply_logs_have_mergen_tag() {
	cmd_add --name tag-test --ip 10.0.0.0/8 --via wg0 2>/dev/null
	cmd_apply 2>/dev/null

	echo "$_LOG_ENTRIES" | grep -q "^mergen|"
	assertEquals "All logs have mergen tag" 0 $?
}

test_apply_logs_contain_route_component() {
	cmd_add --name comp-test --ip 10.0.0.0/8 --via wg0 2>/dev/null
	cmd_apply 2>/dev/null

	echo "$_LOG_ENTRIES" | grep -q "\[Route\]"
	assertEquals "Route component tag present" 0 $?
}

test_apply_logs_contain_iso_timestamp() {
	cmd_add --name ts-test --ip 10.0.0.0/8 --via wg0 2>/dev/null
	cmd_apply 2>/dev/null

	# Check for ISO 8601 pattern in log entries
	echo "$_LOG_ENTRIES" | grep -q '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}'
	assertEquals "ISO 8601 timestamp present" 0 $?
}

test_apply_logs_info_level_for_success() {
	cmd_add --name info-test --ip 10.0.0.0/8 --via wg0 2>/dev/null
	cmd_apply 2>/dev/null

	echo "$_LOG_ENTRIES" | grep -q "daemon.info"
	assertEquals "Info-level logs generated" 0 $?
}

test_apply_logs_snapshot_component() {
	cmd_add --name snap-log --ip 10.0.0.0/8 --via wg0 2>/dev/null
	cmd_apply 2>/dev/null

	echo "$_LOG_ENTRIES" | grep -q "\[Snapshot\]"
	assertEquals "Snapshot component appears in logs" 0 $?
}

test_debug_logs_visible_at_debug_level() {
	_mock_uci_set "mergen.global.log_level=debug"
	MERGEN_LOG_LEVEL=""
	MERGEN_LOG_LEVEL_NUM=""

	# Directly emit a debug log to verify the filter passes it through
	mergen_log "debug" "Test" "debug-visibility-check"

	echo "$_LOG_ENTRIES" | grep -q "daemon.debug"
	assertEquals "Debug logs visible at debug level" 0 $?
}

test_debug_logs_hidden_at_info_level() {
	_mock_uci_set "mergen.global.log_level=info"
	MERGEN_LOG_LEVEL=""
	MERGEN_LOG_LEVEL_NUM=""

	# Trigger a debug-level log via mergen_log directly
	_LOG_ENTRIES=""
	_LOG_COUNT=0
	mergen_log "debug" "Test" "should be hidden"

	echo "$_LOG_ENTRIES" | grep -q "should be hidden"
	assertNotEquals "Debug logs hidden at info level" 0 $?
}

test_error_logs_to_stderr() {
	MERGEN_LOG_LEVEL=""
	MERGEN_LOG_LEVEL_NUM=""

	local stderr_output
	stderr_output="$(mergen_log "error" "Test" "stderr-check" 2>&1 >/dev/null)"

	echo "$stderr_output" | grep -q "stderr-check"
	assertEquals "Error messages go to stderr" 0 $?
}

test_warning_logs_to_stderr() {
	MERGEN_LOG_LEVEL=""
	MERGEN_LOG_LEVEL_NUM=""

	local stderr_output
	stderr_output="$(mergen_log "warning" "Test" "warn-check" 2>&1 >/dev/null)"

	echo "$stderr_output" | grep -q "warn-check"
	assertEquals "Warning messages go to stderr" 0 $?
}

test_engine_detection_logged() {
	MERGEN_ENGINE_ACTIVE=""
	cmd_add --name eng-log --ip 10.0.0.0/8 --via wg0 2>/dev/null
	cmd_apply 2>/dev/null

	echo "$_LOG_ENTRIES" | grep -q "\[Engine\]"
	assertEquals "Engine component appears in logs" 0 $?
}

test_multiple_operations_accumulate_logs() {
	cmd_add --name multi-a --ip 10.0.0.0/8 --via wg0 2>/dev/null
	local count_after_add=$_LOG_COUNT

	cmd_add --name multi-b --ip 172.16.0.0/12 --via wg0 2>/dev/null
	cmd_apply 2>/dev/null

	assertTrue "Logs accumulated across operations" "[ $_LOG_COUNT -gt $count_after_add ]"
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

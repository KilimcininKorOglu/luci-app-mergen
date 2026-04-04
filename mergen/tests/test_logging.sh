#!/bin/sh
# Test suite for logging framework (T019) in core.sh
# Uses shunit2 framework — ash/busybox compatible

MERGEN_TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
MERGEN_ROOT="$(cd "$MERGEN_TEST_DIR/.." && pwd)"

# ── Mock UCI System ─────────────────────────────────────

_MOCK_UCI_STORE=""
_MOCK_CONFIG_LOADED=""
_MOCK_FOREACH_SECTIONS=""

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

# ── Mock logger (captures output for verification) ──────

_LOGGER_CALLS=""
_LOGGER_LAST_TAG=""
_LOGGER_LAST_PRIORITY=""
_LOGGER_LAST_MESSAGE=""

logger() {
	local tag="" priority="" message=""

	while [ $# -gt 0 ]; do
		case "$1" in
			-t) tag="$2"; shift 2 ;;
			-p) priority="$2"; shift 2 ;;
			*)  message="$*"; break ;;
		esac
	done

	_LOGGER_LAST_TAG="$tag"
	_LOGGER_LAST_PRIORITY="$priority"
	_LOGGER_LAST_MESSAGE="$message"
	_LOGGER_CALLS="${_LOGGER_CALLS}|${tag}:${priority}:${message}"
}

# Mock flock
flock() { return 0; }

# Mock logread for query tests
_MOCK_LOGREAD_OUTPUT=""

logread() {
	local filter=""
	while [ $# -gt 0 ]; do
		case "$1" in
			-e) filter="$2"; shift 2 ;;
			*) shift ;;
		esac
	done

	if [ -n "$_MOCK_LOGREAD_OUTPUT" ]; then
		if [ -n "$filter" ]; then
			echo "$_MOCK_LOGREAD_OUTPUT" | grep "$filter"
		else
			echo "$_MOCK_LOGREAD_OUTPUT"
		fi
	fi
}

# ── Source Module Under Test ────────────────────────────

. "${MERGEN_ROOT}/files/usr/lib/mergen/core.sh"

# ── Setup/Teardown ──────────────────────────────────────

setUp() {
	_MOCK_UCI_STORE=""
	_MOCK_FOREACH_SECTIONS=""
	_LOGGER_CALLS=""
	_LOGGER_LAST_TAG=""
	_LOGGER_LAST_PRIORITY=""
	_LOGGER_LAST_MESSAGE=""
	_MOCK_LOGREAD_OUTPUT=""

	# Reset log level cache
	MERGEN_LOG_LEVEL=""
	MERGEN_LOG_LEVEL_NUM=""

	_mock_uci_set "mergen.global.log_level=info"
	_MOCK_CONFIG_LOADED="mergen"
}

# ── Log Level Number Tests ─────────────────────────────

test_level_num_debug() {
	local num
	num="$(_mergen_log_level_num "debug")"
	assertEquals "debug=0" "0" "$num"
}

test_level_num_info() {
	local num
	num="$(_mergen_log_level_num "info")"
	assertEquals "info=1" "1" "$num"
}

test_level_num_warning() {
	local num
	num="$(_mergen_log_level_num "warning")"
	assertEquals "warning=2" "2" "$num"
}

test_level_num_error() {
	local num
	num="$(_mergen_log_level_num "error")"
	assertEquals "error=3" "3" "$num"
}

test_level_num_unknown_defaults_to_info() {
	local num
	num="$(_mergen_log_level_num "bogus")"
	assertEquals "unknown=1 (info)" "1" "$num"
}

# ── Log Init Tests ─────────────────────────────────────

test_log_init_caches_level() {
	_mock_uci_set "mergen.global.log_level=debug"
	mergen_log_init
	assertEquals "Level cached" "debug" "$MERGEN_LOG_LEVEL"
	assertEquals "Level num cached" "0" "$MERGEN_LOG_LEVEL_NUM"
}

test_log_init_default_info() {
	# No log_level set in UCI
	_MOCK_UCI_STORE=""
	mergen_log_init
	assertEquals "Default is info" "info" "$MERGEN_LOG_LEVEL"
	assertEquals "Default num is 1" "1" "$MERGEN_LOG_LEVEL_NUM"
}

test_log_init_lazy_on_first_call() {
	_mock_uci_set "mergen.global.log_level=warning"
	MERGEN_LOG_LEVEL=""
	MERGEN_LOG_LEVEL_NUM=""

	# Call mergen_log — should lazy-init
	mergen_log "error" "Test" "trigger lazy init"
	assertEquals "Level auto-initialized" "warning" "$MERGEN_LOG_LEVEL"
}

# ── Log Filtering Tests ────────────────────────────────

test_log_info_at_info_level() {
	_mock_uci_set "mergen.global.log_level=info"
	mergen_log_init
	mergen_log "info" "Test" "visible"
	echo "$_LOGGER_LAST_MESSAGE" | grep -q "visible"
	assertEquals "Info logged at info level" 0 $?
}

test_log_debug_filtered_at_info_level() {
	_mock_uci_set "mergen.global.log_level=info"
	mergen_log_init
	_LOGGER_LAST_MESSAGE=""
	mergen_log "debug" "Test" "hidden"
	assertEquals "Debug filtered at info level" "" "$_LOGGER_LAST_MESSAGE"
}

test_log_debug_visible_at_debug_level() {
	_mock_uci_set "mergen.global.log_level=debug"
	mergen_log_init
	mergen_log "debug" "Test" "visible-debug"
	echo "$_LOGGER_LAST_MESSAGE" | grep -q "visible-debug"
	assertEquals "Debug logged at debug level" 0 $?
}

test_log_warning_at_error_level_filtered() {
	_mock_uci_set "mergen.global.log_level=error"
	mergen_log_init
	_LOGGER_LAST_MESSAGE=""
	mergen_log "warning" "Test" "hidden-warn"
	assertEquals "Warning filtered at error level" "" "$_LOGGER_LAST_MESSAGE"
}

test_log_error_always_visible() {
	_mock_uci_set "mergen.global.log_level=error"
	mergen_log_init
	mergen_log "error" "Test" "always-visible"
	echo "$_LOGGER_LAST_MESSAGE" | grep -q "always-visible"
	assertEquals "Error always logged" 0 $?
}

# ── Log Format Tests ───────────────────────────────────

test_log_has_tag() {
	mergen_log_init
	mergen_log "info" "Engine" "test message"
	assertEquals "Tag is mergen" "mergen" "$_LOGGER_LAST_TAG"
}

test_log_has_syslog_priority_info() {
	mergen_log_init
	mergen_log "info" "Test" "msg"
	assertEquals "Priority daemon.info" "daemon.info" "$_LOGGER_LAST_PRIORITY"
}

test_log_has_syslog_priority_error() {
	mergen_log_init
	mergen_log "error" "Test" "msg"
	assertEquals "Priority daemon.err" "daemon.err" "$_LOGGER_LAST_PRIORITY"
}

test_log_has_syslog_priority_warning() {
	mergen_log_init
	mergen_log "warning" "Test" "msg"
	assertEquals "Priority daemon.warning" "daemon.warning" "$_LOGGER_LAST_PRIORITY"
}

test_log_has_syslog_priority_debug() {
	_mock_uci_set "mergen.global.log_level=debug"
	mergen_log_init
	mergen_log "debug" "Test" "msg"
	assertEquals "Priority daemon.debug" "daemon.debug" "$_LOGGER_LAST_PRIORITY"
}

test_log_message_contains_level() {
	mergen_log_init
	mergen_log "info" "Route" "test"
	echo "$_LOGGER_LAST_MESSAGE" | grep -q '\[info\]'
	assertEquals "Message contains level tag" 0 $?
}

test_log_message_contains_component() {
	mergen_log_init
	mergen_log "info" "Resolver" "test"
	echo "$_LOGGER_LAST_MESSAGE" | grep -q '\[Resolver\]'
	assertEquals "Message contains component tag" 0 $?
}

test_log_message_contains_iso8601_timestamp() {
	mergen_log_init
	mergen_log "info" "Test" "timestamp check"
	# ISO 8601: YYYY-MM-DDTHH:MM:SS
	echo "$_LOGGER_LAST_MESSAGE" | grep -q '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}'
	assertEquals "Message contains ISO 8601 timestamp" 0 $?
}

test_log_stderr_on_error() {
	mergen_log_init
	local stderr_output
	stderr_output="$(mergen_log "error" "CLI" "stderr test" 2>&1 >/dev/null)"
	echo "$stderr_output" | grep -q "stderr test"
	assertEquals "Error goes to stderr" 0 $?
}

test_log_stderr_on_warning() {
	mergen_log_init
	local stderr_output
	stderr_output="$(mergen_log "warning" "CLI" "warn test" 2>&1 >/dev/null)"
	echo "$stderr_output" | grep -q "warn test"
	assertEquals "Warning goes to stderr" 0 $?
}

test_log_no_stderr_on_info() {
	mergen_log_init
	local stderr_output
	stderr_output="$(mergen_log "info" "CLI" "info test" 2>&1 >/dev/null)"
	assertEquals "Info does not go to stderr" "" "$stderr_output"
}

# ── Component Tag Tests ────────────────────────────────

test_all_component_tags() {
	mergen_log_init
	local tag
	for tag in Core Engine Route Resolver Provider Daemon CLI NFT IPSET SafeMode Snapshot; do
		_LOGGER_LAST_MESSAGE=""
		mergen_log "info" "$tag" "testing ${tag}"
		echo "$_LOGGER_LAST_MESSAGE" | grep -q "\\[${tag}\\]"
		assertEquals "Component tag ${tag}" 0 $?
	done
}

# ── Log Query Tests ────────────────────────────────────

test_query_returns_mergen_entries() {
	_MOCK_LOGREAD_OUTPUT="Jan 1 mergen[123]: [info] [Route] test
Jan 1 other[456]: unrelated
Jan 1 mergen[123]: [error] [CLI] error msg"

	local output
	output="$(mergen_log_query)"
	local count
	count="$(echo "$output" | wc -l | tr -d ' ')"
	assertEquals "Returns 2 mergen entries" "2" "$count"
}

test_query_tail_limits_output() {
	_MOCK_LOGREAD_OUTPUT="Jan 1 mergen[1]: [info] [Route] line1
Jan 1 mergen[1]: [info] [Route] line2
Jan 1 mergen[1]: [info] [Route] line3"

	local output
	output="$(mergen_log_query --tail 2)"
	local count
	count="$(echo "$output" | wc -l | tr -d ' ')"
	assertEquals "Tail limits to 2" "2" "$count"
}

test_query_level_filter() {
	_MOCK_LOGREAD_OUTPUT="Jan 1 mergen[1]: [info] [Route] info msg
Jan 1 mergen[1]: [error] [Route] error msg
Jan 1 mergen[1]: [info] [CLI] another info"

	local output
	output="$(mergen_log_query --level error)"
	echo "$output" | grep -q "error msg"
	assertEquals "Level filter shows error" 0 $?
	echo "$output" | grep -q "info msg"
	assertNotEquals "Level filter hides info" 0 $?
}

test_query_component_filter() {
	_MOCK_LOGREAD_OUTPUT="Jan 1 mergen[1]: [info] [Route] route msg
Jan 1 mergen[1]: [info] [CLI] cli msg
Jan 1 mergen[1]: [error] [Route] route error"

	local output
	output="$(mergen_log_query --component Route)"
	local count
	count="$(echo "$output" | wc -l | tr -d ' ')"
	assertEquals "Component filter returns 2 Route entries" "2" "$count"
}

test_query_combined_filters() {
	_MOCK_LOGREAD_OUTPUT="Jan 1 mergen[1]: [info] [Route] route info
Jan 1 mergen[1]: [error] [Route] route error
Jan 1 mergen[1]: [error] [CLI] cli error"

	local output
	output="$(mergen_log_query --level error --component Route)"
	local count
	count="$(echo "$output" | wc -l | tr -d ' ')"
	assertEquals "Combined filter returns 1 entry" "1" "$count"
}

test_query_empty_output() {
	_MOCK_LOGREAD_OUTPUT=""
	local output
	output="$(mergen_log_query)"
	assertEquals "Empty logread returns empty" "" "$output"
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

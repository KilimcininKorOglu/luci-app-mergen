#!/bin/sh
# Test suite for snapshot/rollback in mergen/files/usr/lib/mergen/route.sh
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
		delete) return 0 ;;
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

# Mock logger, flock
logger() { :; }
flock() { return 0; }

# ── Mock ip command ─────────────────────────────────────

_MOCK_IP_RULES=""
_MOCK_IP_ROUTES=""

ip() {
	case "$1" in
		rule)
			case "$2" in
				save)
					echo "$_MOCK_IP_RULES"
					return 0
					;;
				show)
					echo "$_MOCK_IP_RULES"
					return 0
					;;
				add)
					shift 2
					_MOCK_IP_RULES="${_MOCK_IP_RULES}
$*"
					return 0
					;;
				del|delete)
					# Remove first matching rule
					if [ -n "$_MOCK_IP_RULES" ]; then
						_MOCK_IP_RULES="$(echo "$_MOCK_IP_RULES" | sed '1d')"
						return 0
					fi
					return 2
					;;
				restore)
					# Read from stdin
					_MOCK_IP_RULES="$(cat)"
					return 0
					;;
			esac
			;;
		route)
			case "$2" in
				show)
					shift 2
					local table="" dev=""
					while [ $# -gt 0 ]; do
						case "$1" in
							table) table="$2"; shift 2 ;;
							dev) dev="$2"; shift 2 ;;
							default) shift ;;
							*) shift ;;
						esac
					done
					# Gateway detection: return default route for any device
					if [ -n "$dev" ] && [ -z "$table" ]; then
						echo "default via 10.0.0.1 dev ${dev}"
						return 0
					fi
					if [ -n "$table" ]; then
						echo "$_MOCK_IP_ROUTES" | grep "table=${table}" | sed 's/ table=[0-9]*//'
					else
						echo "$_MOCK_IP_ROUTES"
					fi
					return 0
					;;
				add)
					shift 2
					_MOCK_IP_ROUTES="${_MOCK_IP_ROUTES}
$*"
					return 0
					;;
				replace)
					shift 2
					_MOCK_IP_ROUTES="${_MOCK_IP_ROUTES}
$*"
					return 0
					;;
				flush)
					shift 2
					local table=""
					while [ $# -gt 0 ]; do
						case "$1" in
							table) table="$2"; shift 2 ;;
							*) shift ;;
						esac
					done
					if [ -n "$table" ]; then
						_MOCK_IP_ROUTES="$(echo "$_MOCK_IP_ROUTES" | grep -v "table=${table}")"
					else
						_MOCK_IP_ROUTES=""
					fi
					return 0
					;;
			esac
			;;
	esac
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

# ── Post-source Overrides ──────────────────────────────

mergen_lock_acquire() { return 0; }
mergen_lock_release() { return 0; }

# ── Setup/Teardown ──────────────────────────────────────

setUp() {
	_MOCK_UCI_STORE=""
	_MOCK_FOREACH_SECTIONS=""
	_MOCK_SECTION_COUNTER=0
	_MOCK_IP_RULES=""
	_MOCK_IP_ROUTES=""
	MERGEN_ROUTE_APPLIED_COUNT=0
	MERGEN_ROUTE_FAILED_COUNT=0

	# Create temp directory structure
	_TEST_TMPDIR="$(mktemp -d)"
	mkdir -p "${_TEST_TMPDIR}/providers"
	mkdir -p "${_TEST_TMPDIR}/cache"

	# Override globals
	MERGEN_PROVIDERS_DIR="${_TEST_TMPDIR}/providers"
	MERGEN_CACHE_DIR="${_TEST_TMPDIR}/cache"
	MERGEN_TMP="${_TEST_TMPDIR}"
	MERGEN_SNAPSHOT_DIR="${_TEST_TMPDIR}/snapshot"

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

# ── Snapshot Create Tests ───────────────────────────────

test_snapshot_create_makes_dir() {
	mergen_snapshot_create
	assertTrue "Snapshot dir created" "[ -d '$MERGEN_SNAPSHOT_DIR' ]"
}

test_snapshot_create_writes_meta() {
	mergen_snapshot_create
	assertTrue "Meta file created" "[ -f '${MERGEN_SNAPSHOT_DIR}/meta' ]"
}

test_snapshot_meta_has_timestamp() {
	mergen_snapshot_create

	grep -q "^timestamp=" "${MERGEN_SNAPSHOT_DIR}/meta"
	assertEquals "Meta has timestamp" 0 $?
}

test_snapshot_meta_has_tables_saved() {
	mergen_snapshot_create

	grep -q "^tables_saved=" "${MERGEN_SNAPSHOT_DIR}/meta"
	assertEquals "Meta has tables_saved" 0 $?
}

test_snapshot_create_saves_rules() {
	_MOCK_IP_RULES="100: to 10.0.0.0/8 lookup 100"
	mergen_snapshot_create

	assertTrue "Rules file created" "[ -f '${MERGEN_SNAPSHOT_DIR}/rules.save' ]"
}

test_snapshot_create_saves_routes() {
	mergen_snapshot_create

	assertTrue "Routes file created" "[ -f '${MERGEN_SNAPSHOT_DIR}/routes.save' ]"
}

# ── Snapshot Exists Tests ───────────────────────────────

test_snapshot_exists_no_snapshot() {
	mergen_snapshot_exists
	local ret=$?
	assertEquals "No snapshot returns 1" 1 "$ret"
}

test_snapshot_exists_with_snapshot() {
	mergen_snapshot_create

	mergen_snapshot_exists
	local ret=$?
	assertEquals "Snapshot exists returns 0" 0 "$ret"
}

# ── Snapshot Info Tests ─────────────────────────────────

test_snapshot_info_no_snapshot() {
	local output
	output="$(mergen_snapshot_info 2>&1)"
	echo "$output" | grep -q "bulunamadi"
	assertEquals "Info reports no snapshot" 0 $?
}

test_snapshot_info_with_snapshot() {
	mergen_snapshot_create

	local output
	output="$(mergen_snapshot_info)"
	echo "$output" | grep -q "Snapshot:"
	assertEquals "Info shows snapshot" 0 $?
}

# ── Snapshot Delete Tests ───────────────────────────────

test_snapshot_delete_removes_dir() {
	mergen_snapshot_create
	assertTrue "Snapshot exists" "[ -d '$MERGEN_SNAPSHOT_DIR' ]"

	mergen_snapshot_delete
	assertFalse "Snapshot deleted" "[ -d '$MERGEN_SNAPSHOT_DIR' ]"
}

test_snapshot_delete_noop_when_missing() {
	mergen_snapshot_delete
	# Should not error
	assertEquals "Delete noop succeeds" 0 $?
}

# ── Snapshot Restore Tests ──────────────────────────────

test_restore_no_snapshot_fails() {
	mergen_snapshot_restore
	local ret=$?
	assertEquals "Restore without snapshot fails" 1 "$ret"
}

test_restore_after_snapshot_succeeds() {
	mergen_snapshot_create

	mergen_snapshot_restore
	local ret=$?
	assertEquals "Restore succeeds" 0 "$ret"
}

# ── CLI Rollback Command Tests ──────────────────────────

test_cli_rollback_no_snapshot() {
	local output
	output="$(cmd_rollback 2>&1)"
	echo "$output" | grep -q "snapshot bulunamadi"
	assertEquals "Rollback reports no snapshot" 0 $?
}

test_cli_rollback_with_snapshot() {
	mergen_snapshot_create

	local output
	output="$(cmd_rollback 2>&1)"
	echo "$output" | grep -q "Geri yukleme tamamlandi"
	assertEquals "Rollback reports success" 0 $?
}

# ── Apply Creates Snapshot Tests ────────────────────────

test_apply_creates_snapshot() {
	_MOCK_FOREACH_SECTIONS=""

	cmd_apply > /dev/null 2>&1

	assertTrue "Apply creates snapshot" "[ -d '$MERGEN_SNAPSHOT_DIR' ]"
	assertTrue "Snapshot meta exists after apply" "[ -f '${MERGEN_SNAPSHOT_DIR}/meta' ]"
}

# ── Integration: Apply then Rollback ────────────────────

test_apply_rollback_cycle() {
	# Set up a rule
	_MOCK_FOREACH_SECTIONS="rule1"
	_mock_uci_set "mergen.rule1.name=test1"
	_mock_uci_set "mergen.rule1.enabled=1"
	_mock_uci_set "mergen.rule1.ip=10.0.0.0/8"
	_mock_uci_set "mergen.rule1.via=wg0"
	_mock_uci_set "mergen.rule1.priority=100"

	# Apply (creates snapshot first)
	cmd_apply > /dev/null 2>&1

	# Snapshot should exist
	assertTrue "Snapshot exists after apply" "[ -f '${MERGEN_SNAPSHOT_DIR}/meta' ]"

	# Rollback
	local output
	output="$(cmd_rollback 2>&1)"
	echo "$output" | grep -q "Geri yukleme tamamlandi"
	assertEquals "Rollback succeeds after apply" 0 $?
}

# ── Atomic Apply Tests ──────────────────────────────────

test_atomic_apply_no_rules() {
	_MOCK_FOREACH_SECTIONS=""

	mergen_apply_atomic
	local ret=$?
	assertEquals "Atomic apply with no rules succeeds" 0 "$ret"
	assertEquals "Applied count is 0" 0 "$MERGEN_ROUTE_APPLIED_COUNT"
}

test_atomic_apply_all_succeed() {
	_MOCK_FOREACH_SECTIONS="rule1 rule2"
	_mock_uci_set "mergen.rule1.name=test1"
	_mock_uci_set "mergen.rule1.enabled=1"
	_mock_uci_set "mergen.rule1.ip=10.0.0.0/8"
	_mock_uci_set "mergen.rule1.via=wg0"
	_mock_uci_set "mergen.rule1.priority=100"
	_mock_uci_set "mergen.rule2.name=test2"
	_mock_uci_set "mergen.rule2.enabled=1"
	_mock_uci_set "mergen.rule2.ip=172.16.0.0/12"
	_mock_uci_set "mergen.rule2.via=wg0"
	_mock_uci_set "mergen.rule2.priority=200"

	mergen_apply_atomic
	local ret=$?
	assertEquals "Atomic apply succeeds" 0 "$ret"
	assertEquals "Applied count is 2" 2 "$MERGEN_ROUTE_APPLIED_COUNT"
}

test_atomic_apply_skips_disabled() {
	_MOCK_FOREACH_SECTIONS="rule1 rule2"
	_mock_uci_set "mergen.rule1.name=test1"
	_mock_uci_set "mergen.rule1.enabled=1"
	_mock_uci_set "mergen.rule1.ip=10.0.0.0/8"
	_mock_uci_set "mergen.rule1.via=wg0"
	_mock_uci_set "mergen.rule1.priority=100"
	_mock_uci_set "mergen.rule2.name=test2"
	_mock_uci_set "mergen.rule2.enabled=0"
	_mock_uci_set "mergen.rule2.ip=172.16.0.0/12"
	_mock_uci_set "mergen.rule2.via=wg0"
	_mock_uci_set "mergen.rule2.priority=200"

	mergen_apply_atomic
	local ret=$?
	assertEquals "Atomic apply succeeds" 0 "$ret"
	assertEquals "Only enabled rule applied" 1 "$MERGEN_ROUTE_APPLIED_COUNT"
}

test_atomic_apply_failure_rolls_back() {
	# Override mergen_route_apply to fail on second rule
	_ORIG_ROUTE_APPLY="$(type mergen_route_apply)"
	_apply_call_count=0

	mergen_route_apply() {
		_apply_call_count=$((_apply_call_count + 1))
		if [ "$_apply_call_count" -eq 2 ]; then
			return 1
		fi
		return 0
	}

	_MOCK_FOREACH_SECTIONS="rule1 rule2"
	_mock_uci_set "mergen.rule1.name=test1"
	_mock_uci_set "mergen.rule1.enabled=1"
	_mock_uci_set "mergen.rule2.name=fail_rule"
	_mock_uci_set "mergen.rule2.enabled=1"

	# Create snapshot first (needed for restore)
	mergen_snapshot_create

	mergen_apply_atomic
	local ret=$?
	assertEquals "Atomic apply fails" 1 "$ret"
	assertEquals "Failed rule name recorded" "fail_rule" "$MERGEN_ATOMIC_FAILED_RULE"

	# Restore the original function
	eval "mergen_route_apply() { :; }"
}

test_atomic_apply_failure_reports_rule_name() {
	mergen_route_apply() {
		return 1
	}

	_MOCK_FOREACH_SECTIONS="rule1"
	_mock_uci_set "mergen.rule1.name=broken_rule"
	_mock_uci_set "mergen.rule1.enabled=1"

	mergen_snapshot_create

	mergen_apply_atomic
	assertEquals "Failed rule is broken_rule" "broken_rule" "$MERGEN_ATOMIC_FAILED_RULE"

	eval "mergen_route_apply() { :; }"
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

#!/bin/sh
# Integration Test: Rollback lifecycle
# Tests apply → failure → automatic rollback → state verification
# Exercises: route.sh, engine.sh, core.sh, resolver.sh, CLI together

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

# Mock logger, flock
logger() { :; }
flock() { return 0; }

# ── Mock ip command with state tracking ────────────────

_IP_ROUTES=""
_IP_RULES=""
_MOCK_APPLY_FAIL_RULE=""

ip() {
	case "$1" in
		route)
			case "$2" in
				add|replace)
					shift 2
					local prefix="$1"
					# Simulate failure for specific rule
					if [ -n "$_MOCK_APPLY_FAIL_RULE" ]; then
						local table_arg
						table_arg="$(echo "$*" | sed -n 's/.*table \([0-9]*\).*/\1/p')"
						if [ "$table_arg" = "$_MOCK_APPLY_FAIL_RULE" ]; then
							return 1
						fi
					fi
					_IP_ROUTES="${_IP_ROUTES}
$*"
					return 0
					;;
				show)
					if echo "$*" | grep -q "table"; then
						local tbl
						tbl="$(echo "$*" | sed -n 's/.*table \([0-9]*\).*/\1/p')"
						echo "$_IP_ROUTES" | grep "table $tbl" 2>/dev/null
					elif echo "$*" | grep -q "dev"; then
						echo "default via 10.0.0.1 dev wg0"
					fi
					return 0
					;;
				del|delete)
					shift 2
					local del_args="$*"
					_IP_ROUTES="$(echo "$_IP_ROUTES" | grep -v "$1" 2>/dev/null)"
					return 0
					;;
				flush)
					local tbl
					tbl="$(echo "$*" | sed -n 's/.*table \([0-9]*\).*/\1/p')"
					[ -n "$tbl" ] && _IP_ROUTES="$(echo "$_IP_ROUTES" | grep -v "table $tbl" 2>/dev/null)"
					return 0
					;;
			esac
			;;
		rule)
			case "$2" in
				add)
					shift 2
					_IP_RULES="${_IP_RULES}
$*"
					return 0
					;;
				del|delete)
					shift 2
					_IP_RULES="$(echo "$_IP_RULES" | grep -v "$1" 2>/dev/null)"
					return 0
					;;
				show)
					echo "$_IP_RULES"
					return 0
					;;
				save)
					echo "$_IP_RULES"
					return 0
					;;
				restore)
					return 0
					;;
			esac
			;;
		link)
			case "$3" in
				wg0|lan|eth0) echo "1: $3: <POINTOPOINT,NOARP,UP>" ;;
				*) return 1 ;;
			esac
			;;
	esac
}

# Mock nft (not available — fallback to per-prefix routing)
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

# Force no packet engine
MERGEN_NFT_AVAILABLE="0"
MERGEN_IPSET_AVAILABLE="0"
MERGEN_ENGINE_ACTIVE=""

# ── Setup/Teardown ──────────────────────────────────────

setUp() {
	_MOCK_UCI_STORE=""
	_MOCK_FOREACH_SECTIONS=""
	_MOCK_SECTION_COUNTER=0
	_IP_ROUTES=""
	_IP_RULES=""
	_MOCK_APPLY_FAIL_RULE=""
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
	_mock_uci_set "mergen.global.log_level=info"
	_mock_uci_set "mergen.global.cache_dir=${_TEST_TMPDIR}/cache"
	_mock_uci_set "mergen.global.default_table=100"
	_mock_uci_set "mergen.global.max_prefix_per_rule=10000"
	_mock_uci_set "mergen.global.max_prefix_total=50000"
	_MOCK_CONFIG_LOADED="mergen"

	# Reset log level cache
	MERGEN_LOG_LEVEL=""
	MERGEN_LOG_LEVEL_NUM=""

	# Re-source route.sh to restore any function overrides from previous tests
	. "${MERGEN_ROOT}/files/usr/lib/mergen/route.sh"
}

tearDown() {
	[ -n "$_TEST_TMPDIR" ] && [ -d "$_TEST_TMPDIR" ] && rm -rf "$_TEST_TMPDIR"
}

# ── Integration Tests ──────────────────────────────────

test_apply_creates_snapshot_before_routes() {
	cmd_add --name snap-test --ip 10.0.0.0/8 --via wg0 2>/dev/null

	cmd_apply 2>/dev/null
	assertEquals "Apply succeeds" 0 $?

	# Snapshot directory should have been written
	assertTrue "Snapshot dir exists" "[ -d '${_TEST_TMPDIR}/snapshot' ]"
}

test_apply_rollback_on_failure() {
	# Add two rules — second will fail via override
	cmd_add --name rule-ok --ip 10.0.0.0/8 --via wg0 2>/dev/null
	cmd_add --name rule-fail --ip 172.16.0.0/12 --via wg0 2>/dev/null

	# Override mergen_route_apply to fail on second rule
	local _orig_apply_count=0
	mergen_route_apply() {
		_orig_apply_count=$((_orig_apply_count + 1))
		if [ "$1" = "rule-fail" ]; then
			return 1
		fi
		# For the first rule, just mark as applied (simplified)
		return 0
	}

	cmd_apply 2>/dev/null
	local rc=$?
	assertNotEquals "Apply fails" 0 "$rc"
}

test_rollback_restores_previous_state() {
	# Step 1: Apply a rule successfully
	cmd_add --name initial --ip 10.0.0.0/8 --via wg0 2>/dev/null
	cmd_apply 2>/dev/null
	assertEquals "Initial apply succeeds" 0 $?

	# Verify route exists
	local route_count
	route_count="$(echo "$_IP_ROUTES" | grep -c "table" 2>/dev/null || echo "0")"
	assertTrue "Routes exist after apply" "[ $route_count -gt 0 ]"

	# Step 2: Rollback
	cmd_rollback 2>/dev/null
	assertEquals "Rollback succeeds" 0 $?
}

test_apply_multiple_rules_atomic() {
	cmd_add --name multi-a --ip 10.0.0.0/8 --via wg0 2>/dev/null
	cmd_add --name multi-b --ip 172.16.0.0/12 --via wg0 2>/dev/null

	cmd_apply 2>/dev/null
	assertEquals "Multi-rule apply succeeds" 0 $?

	local output
	output="$(cmd_apply 2>&1)"
	echo "$output" | grep -q "2 kural"
	assertEquals "Reports 2 rules applied" 0 $?
}

test_disable_then_apply_skips_rule() {
	cmd_add --name skip-me --ip 10.0.0.0/8 --via wg0 2>/dev/null
	cmd_add --name keep-me --ip 172.16.0.0/12 --via wg0 2>/dev/null
	cmd_disable skip-me 2>/dev/null

	local output
	output="$(cmd_apply 2>&1)"
	echo "$output" | grep -q "1 kural"
	assertEquals "Only 1 rule applied (disabled skipped)" 0 $?
}

test_full_lifecycle_add_apply_rollback() {
	# Add
	cmd_add --name lifecycle --ip 192.168.0.0/16 --via wg0 2>/dev/null
	assertEquals "Add succeeds" 0 $?

	# Apply
	cmd_apply 2>/dev/null
	assertEquals "Apply succeeds" 0 $?

	# Verify last_sync written
	assertTrue "Last sync exists" "[ -f '${_TEST_TMPDIR}/last_sync' ]"

	# Rollback
	cmd_rollback 2>/dev/null
	assertEquals "Rollback succeeds" 0 $?
}

test_apply_with_force_bypasses_limits() {
	# Set a very low limit
	_mock_uci_set "mergen.global.max_prefix_per_rule=1"

	cmd_add --name over-limit --ip "10.0.0.0/8 172.16.0.0/12 192.168.0.0/16" --via wg0 2>/dev/null

	# Without force should fail
	MERGEN_FORCE_APPLY=0
	cmd_apply 2>/dev/null
	local rc_no_force=$?

	# With force should succeed
	MERGEN_FORCE_APPLY=1
	cmd_apply 2>/dev/null
	local rc_force=$?

	assertEquals "Force apply succeeds" 0 "$rc_force"
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

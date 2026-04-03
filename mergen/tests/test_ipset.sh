#!/bin/sh
# Test suite for ipset fallback and engine abstraction (T018) in route.sh
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

# Mock logger and flock
logger() { :; }
flock() { return 0; }

# ── Mock ipset Command ─────────────────────────────────

_IPSET_SETS=""
_IPSET_ELEMENTS=""
_IPSET_RESTORE_CONTENT=""
_IPSET_MOCK_FAIL=0

ipset() {
	if [ "$_IPSET_MOCK_FAIL" -eq 1 ]; then
		return 1
	fi

	case "$1" in
		create)
			local set_name="$2" set_type="$3"
			_IPSET_SETS="${_IPSET_SETS} ${set_name}:${set_type}"
			return 0
			;;
		add)
			local set_name="$2" element="$3"
			_IPSET_ELEMENTS="${_IPSET_ELEMENTS}|${set_name}=${element}"
			return 0
			;;
		flush)
			local set_name="$2"
			_IPSET_ELEMENTS="$(echo "$_IPSET_ELEMENTS" | sed "s|${set_name}=[^|]*||g")"
			return 0
			;;
		destroy)
			local set_name="$2"
			_IPSET_SETS="$(echo "$_IPSET_SETS" | sed "s| ${set_name}:[^ ]*||g")"
			return 0
			;;
		restore)
			# Read from stdin
			_IPSET_RESTORE_CONTENT="$(cat)"
			# Parse restore commands
			echo "$_IPSET_RESTORE_CONTENT" | while IFS= read -r line; do
				case "$line" in
					"flush "*)
						;;
					"add "*)
						local parts set_name element
						set_name="$(echo "$line" | awk '{print $2}')"
						element="$(echo "$line" | awk '{print $3}')"
						_IPSET_ELEMENTS="${_IPSET_ELEMENTS}|${set_name}=${element}"
						;;
				esac
			done
			return 0
			;;
		save)
			# Output save format for mergen_ sets
			echo "$_IPSET_SETS" | tr ' ' '\n' | while IFS=: read -r name type; do
				[ -z "$name" ] && continue
				case "$name" in
					mergen_*)
						echo "create ${name} ${type}"
						;;
				esac
			done
			return 0
			;;
		list)
			if [ "$2" = "-n" ]; then
				# List set names only
				echo "$_IPSET_SETS" | tr ' ' '\n' | while IFS=: read -r name type; do
					[ -z "$name" ] && continue
					echo "$name"
				done
				return 0
			fi
			;;
	esac
	return 0
}

# ── Mock iptables Command ──────────────────────────────

_IPTABLES_RULES=""

iptables() {
	case "$1" in
		-t)
			local table="$2"
			shift 2
			case "$1" in
				-A)
					shift
					_IPTABLES_RULES="${_IPTABLES_RULES}|${table}:$*"
					return 0
					;;
				-D)
					shift
					local old="$_IPTABLES_RULES"
					# Try to remove a matching rule
					local match="${table}:$*"
					_IPTABLES_RULES="$(echo "$_IPTABLES_RULES" | sed "s|${match}||" | sed 's/||/|/g')"
					[ "$old" != "$_IPTABLES_RULES" ] && return 0
					return 1
					;;
				-C)
					# Check if rule exists
					shift
					local check="${table}:$*"
					echo "$_IPTABLES_RULES" | grep -q "$check" && return 0
					return 1
					;;
			esac
			;;
	esac
	return 0
}

# ── Mock nft Command (disabled for ipset tests) ────────

# Override nft to be "not found" by default in ipset tests
_NFT_MOCK_AVAILABLE=0

nft() {
	if [ "$_NFT_MOCK_AVAILABLE" -eq 1 ]; then
		# Minimal nft mock for engine detection
		case "$1" in
			add|delete|flush|list|-f|-a)
				return 0
				;;
		esac
	fi
	return 127
}

# ── Mock ip Command ─────────────────────────────────────

_IP_RULES=""
_IP_ROUTES=""

ip() {
	case "$1" in
		rule)
			case "$2" in
				add)
					shift 2
					_IP_RULES="${_IP_RULES}|$*"
					return 0
					;;
				del)
					shift 2
					local old="$_IP_RULES"
					_IP_RULES="$(echo "$_IP_RULES" | sed "s|[^|]*||" | sed 's/^|//')"
					[ "$old" != "$_IP_RULES" ] && return 0
					return 2
					;;
				save|show|restore) return 0 ;;
			esac
			;;
		route)
			case "$2" in
				add|replace)
					shift 2
					_IP_ROUTES="${_IP_ROUTES}|$*"
					return 0
					;;
				flush) return 0 ;;
				show)
					shift 2
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
			esac
			;;
	esac
}

# Mock ping
ping() { return 0; }

# ── Source Modules Under Test ───────────────────────────

. "${MERGEN_ROOT}/files/usr/lib/mergen/core.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/utils.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/engine.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/resolver.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/route.sh"

# ── Post-source Overrides ──────────────────────────────

mergen_lock_acquire() { return 0; }
mergen_lock_release() { return 0; }

# ── Setup/Teardown ──────────────────────────────────────

setUp() {
	_MOCK_UCI_STORE=""
	_MOCK_FOREACH_SECTIONS=""
	_MOCK_SECTION_COUNTER=0
	MERGEN_ROUTE_APPLIED_COUNT=0
	MERGEN_ROUTE_FAILED_COUNT=0

	# Reset engine caches
	MERGEN_NFT_AVAILABLE=""
	MERGEN_IPSET_AVAILABLE=""
	MERGEN_ENGINE_ACTIVE=""

	_NFT_MOCK_AVAILABLE=0

	_IPSET_SETS=""
	_IPSET_ELEMENTS=""
	_IPSET_RESTORE_CONTENT=""
	_IPSET_MOCK_FAIL=0
	_IPTABLES_RULES=""

	_IP_RULES=""
	_IP_ROUTES=""

	_TEST_TMPDIR="$(mktemp -d)"
	mkdir -p "${_TEST_TMPDIR}/providers"
	mkdir -p "${_TEST_TMPDIR}/cache"

	MERGEN_PROVIDERS_DIR="${_TEST_TMPDIR}/providers"
	MERGEN_CACHE_DIR="${_TEST_TMPDIR}/cache"
	MERGEN_TMP="${_TEST_TMPDIR}"
	MERGEN_SNAPSHOT_DIR="${_TEST_TMPDIR}/snapshot"

	_mock_uci_set "mergen.global.enabled=1"
	_mock_uci_set "mergen.global.log_level=info"
	_mock_uci_set "mergen.global.default_table=100"
	_mock_uci_set "mergen.global.packet_engine=auto"
	_MOCK_CONFIG_LOADED="mergen"
}

tearDown() {
	if [ -n "$_TEST_TMPDIR" ] && [ -d "$_TEST_TMPDIR" ]; then
		rm -rf "$_TEST_TMPDIR"
	fi
}

# ── ipset Availability Tests ───────────────────────────

test_ipset_available_detected() {
	MERGEN_IPSET_AVAILABLE=""
	mergen_ipset_available
	assertEquals "ipset detected" 0 $?
}

test_ipset_available_cached() {
	MERGEN_IPSET_AVAILABLE="1"
	mergen_ipset_available
	assertEquals "Cached returns true" 0 $?
}

test_ipset_unavailable_cached() {
	MERGEN_IPSET_AVAILABLE="0"
	mergen_ipset_available
	assertEquals "Cached returns false" 1 $?
}

# ── ipset Create Tests ─────────────────────────────────

test_ipset_create_success() {
	mergen_ipset_create "cloudflare"
	assertEquals "Create succeeds" 0 $?
	echo "$_IPSET_SETS" | grep -q "mergen_cloudflare:hash:net"
	assertEquals "Set registered with hash:net" 0 $?
}

test_ipset_create_empty_name_fails() {
	mergen_ipset_create ""
	assertEquals "Empty name fails" 1 $?
}

# ── ipset Add Tests ────────────────────────────────────

test_ipset_add_single_prefix() {
	mergen_ipset_create "test1"
	mergen_ipset_add "test1" "1.0.0.0/24"
	assertEquals "Single prefix succeeds" 0 $?
}

test_ipset_add_multiple_prefixes() {
	mergen_ipset_create "test2"
	local prefixes="1.0.0.0/24
1.1.1.0/24
2.0.0.0/16"
	mergen_ipset_add "test2" "$prefixes"
	assertEquals "Multiple prefixes succeed" 0 $?
}

test_ipset_add_empty_list_fails() {
	mergen_ipset_create "empty"
	mergen_ipset_add "empty" ""
	assertEquals "Empty list fails" 1 $?
}

test_ipset_add_uses_restore() {
	mergen_ipset_create "restoretest"
	mergen_ipset_add "restoretest" "10.0.0.0/8"
	# Restore file should be cleaned up
	assertFalse "Restore file cleaned up" "[ -f '${MERGEN_TMP}/ipset_restore_restoretest.txt' ]"
}

# ── ipset Flush Tests ──────────────────────────────────

test_ipset_flush_success() {
	mergen_ipset_create "flushtest"
	mergen_ipset_add "flushtest" "10.0.0.0/8"
	mergen_ipset_flush "flushtest"
	assertEquals "Flush succeeds" 0 $?
}

# ── ipset Destroy Tests ────────────────────────────────

test_ipset_destroy_removes_set() {
	mergen_ipset_create "destroytest"
	echo "$_IPSET_SETS" | grep -q "mergen_destroytest"
	assertEquals "Set exists" 0 $?

	mergen_ipset_destroy "destroytest"
	echo "$_IPSET_SETS" | grep -q "mergen_destroytest"
	assertNotEquals "Set removed" 0 $?
}

test_ipset_destroy_noop_when_unavailable() {
	MERGEN_IPSET_AVAILABLE="0"
	mergen_ipset_destroy "noexist"
	assertEquals "Noop when unavailable" 0 $?
}

# ── ipset MARK Rule Tests ──────────────────────────────

test_ipset_mark_add_success() {
	mergen_ipset_create "marktest"
	mergen_ipset_mark_add "marktest" "100"
	assertEquals "Mark add succeeds" 0 $?
	echo "$_IPTABLES_RULES" | grep -q "mergen_marktest"
	assertEquals "iptables rule references set" 0 $?
	echo "$_IPTABLES_RULES" | grep -q "set-mark 100"
	assertEquals "iptables rule has correct mark" 0 $?
}

test_ipset_mark_add_empty_params_fails() {
	mergen_ipset_mark_add "" "100"
	assertEquals "Empty name fails" 1 $?
	mergen_ipset_mark_add "test" ""
	assertEquals "Empty fwmark fails" 1 $?
}

# ── ipset Cleanup Tests ────────────────────────────────

test_ipset_cleanup_noop_when_unavailable() {
	MERGEN_IPSET_AVAILABLE="0"
	mergen_ipset_cleanup
	assertEquals "Cleanup noop" 0 $?
}

# ── Engine Detection Tests ─────────────────────────────

test_engine_auto_selects_ipset_when_no_nft() {
	# Force nft as unavailable (command -v finds our mock function)
	MERGEN_NFT_AVAILABLE="0"
	MERGEN_IPSET_AVAILABLE="1"
	MERGEN_ENGINE_ACTIVE=""
	_mock_uci_set "mergen.global.packet_engine=auto"

	mergen_engine_detect
	assertEquals "Engine detected" 0 $?
	assertEquals "ipset selected" "ipset" "$MERGEN_ENGINE_ACTIVE"
}

test_engine_auto_selects_nft_when_available() {
	_NFT_MOCK_AVAILABLE=1
	MERGEN_NFT_AVAILABLE="1"
	MERGEN_IPSET_AVAILABLE="1"
	MERGEN_ENGINE_ACTIVE=""
	_mock_uci_set "mergen.global.packet_engine=auto"

	mergen_engine_detect
	assertEquals "nftables selected" "nftables" "$MERGEN_ENGINE_ACTIVE"
}

test_engine_force_ipset() {
	MERGEN_NFT_AVAILABLE="1"
	MERGEN_IPSET_AVAILABLE="1"
	MERGEN_ENGINE_ACTIVE=""
	_mock_uci_set "mergen.global.packet_engine=ipset"

	mergen_engine_detect
	assertEquals "ipset forced" "ipset" "$MERGEN_ENGINE_ACTIVE"
}

test_engine_force_nftables_fails_when_unavailable() {
	MERGEN_NFT_AVAILABLE="0"
	MERGEN_IPSET_AVAILABLE="1"
	MERGEN_ENGINE_ACTIVE=""
	_mock_uci_set "mergen.global.packet_engine=nftables"

	mergen_engine_detect
	assertEquals "Falls to none" "none" "$MERGEN_ENGINE_ACTIVE"
}

test_engine_info_returns_active() {
	MERGEN_NFT_AVAILABLE="0"
	MERGEN_IPSET_AVAILABLE="1"
	MERGEN_ENGINE_ACTIVE=""
	_mock_uci_set "mergen.global.packet_engine=auto"

	local info
	info="$(mergen_engine_info)"
	assertEquals "Info returns ipset" "ipset" "$info"
}

test_engine_cached() {
	MERGEN_ENGINE_ACTIVE="ipset"
	mergen_engine_detect
	assertEquals "Cached value preserved" "ipset" "$MERGEN_ENGINE_ACTIVE"
}

# ── Common Interface Tests ─────────────────────────────

test_common_set_create_dispatches_to_ipset() {
	MERGEN_ENGINE_ACTIVE="ipset"
	MERGEN_IPSET_AVAILABLE="1"
	mergen_set_create "dispatch_test"
	assertEquals "Dispatch succeeds" 0 $?
	echo "$_IPSET_SETS" | grep -q "mergen_dispatch_test"
	assertEquals "ipset create called" 0 $?
}

test_common_set_add_dispatches_to_ipset() {
	MERGEN_ENGINE_ACTIVE="ipset"
	MERGEN_IPSET_AVAILABLE="1"
	mergen_ipset_create "addtest"
	mergen_set_add "addtest" "10.0.0.0/8"
	assertEquals "Dispatch add succeeds" 0 $?
}

test_common_set_destroy_dispatches_to_ipset() {
	MERGEN_ENGINE_ACTIVE="ipset"
	MERGEN_IPSET_AVAILABLE="1"
	mergen_ipset_create "deltest"
	mergen_set_destroy "deltest"
	assertEquals "Dispatch destroy succeeds" 0 $?
}

test_common_set_mark_dispatches_to_ipset() {
	MERGEN_ENGINE_ACTIVE="ipset"
	MERGEN_IPSET_AVAILABLE="1"
	mergen_ipset_create "markdisp"
	mergen_set_mark_rule "markdisp" "100"
	assertEquals "Dispatch mark succeeds" 0 $?
	echo "$_IPTABLES_RULES" | grep -q "mergen_markdisp"
	assertEquals "iptables rule created" 0 $?
}

test_common_returns_error_when_none() {
	MERGEN_ENGINE_ACTIVE="none"
	mergen_set_create "fail_test"
	assertEquals "Create fails with none" 1 $?
}

# ── Route Apply ipset Integration ──────────────────────

test_apply_uses_ipset_when_no_nft() {
	MERGEN_NFT_AVAILABLE="0"
	MERGEN_IPSET_AVAILABLE="1"
	MERGEN_ENGINE_ACTIVE=""
	_mock_uci_set "mergen.global.packet_engine=auto"

	_MOCK_FOREACH_SECTIONS="rule1"
	_mock_uci_set "mergen.rule1.name=ipsettest"
	_mock_uci_set "mergen.rule1.ip=1.0.0.0/24"
	_mock_uci_set "mergen.rule1.via=wg0"
	_mock_uci_set "mergen.rule1.priority=100"
	_mock_uci_set "mergen.rule1.enabled=1"

	mergen_route_apply "ipsettest"
	assertEquals "Apply succeeds" 0 $?

	# Verify ipset was created
	echo "$_IPSET_SETS" | grep -q "mergen_ipsettest"
	assertEquals "ipset created" 0 $?

	# Verify iptables MARK rule
	echo "$_IPTABLES_RULES" | grep -q "mergen_ipsettest"
	assertEquals "iptables MARK rule added" 0 $?

	# Verify fwmark ip rule
	echo "$_IP_RULES" | grep -q "fwmark"
	assertEquals "fwmark ip rule added" 0 $?
}

test_apply_falls_back_to_per_prefix_when_nothing_available() {
	MERGEN_NFT_AVAILABLE="0"
	MERGEN_IPSET_AVAILABLE="0"
	MERGEN_ENGINE_ACTIVE=""
	_mock_uci_set "mergen.global.packet_engine=auto"

	_MOCK_FOREACH_SECTIONS="rule1"
	_mock_uci_set "mergen.rule1.name=fallback"
	_mock_uci_set "mergen.rule1.ip=10.0.0.0/8"
	_mock_uci_set "mergen.rule1.via=wg0"
	_mock_uci_set "mergen.rule1.priority=100"
	_mock_uci_set "mergen.rule1.enabled=1"

	mergen_route_apply "fallback"
	assertEquals "Apply succeeds" 0 $?

	# Verify per-prefix ip rule (fallback)
	echo "$_IP_RULES" | grep -q "to 10.0.0.0/8"
	assertEquals "Per-prefix ip rule added" 0 $?
}

# ── Route Remove ipset Integration ─────────────────────

test_remove_destroys_ipset() {
	MERGEN_ENGINE_ACTIVE="ipset"
	MERGEN_IPSET_AVAILABLE="1"
	_MOCK_FOREACH_SECTIONS="rule1"
	_mock_uci_set "mergen.rule1.name=rmtest"
	_mock_uci_set "mergen.rule1.ip=10.0.0.0/8"
	_mock_uci_set "mergen.rule1.via=wg0"
	_mock_uci_set "mergen.rule1.priority=100"
	_mock_uci_set "mergen.rule1.enabled=1"

	mergen_route_apply "rmtest"
	echo "$_IPSET_SETS" | grep -q "mergen_rmtest"
	assertEquals "Set exists after apply" 0 $?

	mergen_route_remove "rmtest"
	echo "$_IPSET_SETS" | grep -q "mergen_rmtest"
	assertNotEquals "Set removed after remove" 0 $?
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

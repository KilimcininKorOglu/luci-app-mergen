#!/bin/sh
# Test suite for hotplug integration (T032)
# Tests interface up/down event handling and rule application
# Uses shunit2 framework — ash/busybox compatible

MERGEN_TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
MERGEN_ROOT="$(cd "$MERGEN_TEST_DIR/.." && pwd)"

# ── Mock UCI System ─────────────────────────────────────

_MOCK_UCI_STORE=""
_MOCK_CONFIG_LOADED=""
_MOCK_FOREACH_SECTIONS=""
_MOCK_ADD_COUNTER=0

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
			local conf="$1" type="$2"
			_mock_uci_add "$conf" "$type"
			;;
		delete) _mock_uci_delete "$1" ;;
		add_list) _mock_uci_add_list "$1" ;;
		del_list) _mock_uci_del_list "$1" ;;
		commit) return 0 ;;
		show) echo "$_MOCK_UCI_STORE" ;;
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

_mock_uci_add() {
	local conf="$1" type="$2"
	_MOCK_ADD_COUNTER=$((_MOCK_ADD_COUNTER + 1))
	local idx="cfg${_MOCK_ADD_COUNTER}"
	_MOCK_UCI_STORE="${_MOCK_UCI_STORE}
${conf}.${idx}=${type}"
	_MOCK_FOREACH_SECTIONS="${_MOCK_FOREACH_SECTIONS} ${idx}"
	echo "$idx"
}

_mock_uci_delete() {
	local path="$1"
	_MOCK_UCI_STORE="$(echo "$_MOCK_UCI_STORE" | grep -v "^${path}" 2>/dev/null)"
	local new_sections=""
	local section
	for section in $_MOCK_FOREACH_SECTIONS; do
		case "$path" in
			*"$section"*) ;;
			*) new_sections="$new_sections $section" ;;
		esac
	done
	_MOCK_FOREACH_SECTIONS="$new_sections"
}

_mock_uci_add_list() {
	local assignment="$1"
	local key="${assignment%%=*}"
	local value="${assignment#*=}"
	local existing
	existing="$(_mock_uci_get "$key")"
	if [ -n "$existing" ]; then
		_MOCK_UCI_STORE="$(echo "$_MOCK_UCI_STORE" | grep -v "^${key}=" 2>/dev/null)
${key}=${existing} ${value}"
	else
		_MOCK_UCI_STORE="${_MOCK_UCI_STORE}
${key}=${value}"
	fi
}

_mock_uci_del_list() {
	local assignment="$1"
	local key="${assignment%%=*}"
	local value="${assignment#*=}"
	local existing
	existing="$(_mock_uci_get "$key")"
	if [ -z "$existing" ]; then return 0; fi
	local new_list="" item
	for item in $existing; do
		if [ "$item" != "$value" ]; then
			if [ -n "$new_list" ]; then
				new_list="$new_list $item"
			else
				new_list="$item"
			fi
		fi
	done
	_MOCK_UCI_STORE="$(echo "$_MOCK_UCI_STORE" | grep -v "^${key}=" 2>/dev/null)"
	if [ -n "$new_list" ]; then
		_MOCK_UCI_STORE="${_MOCK_UCI_STORE}
${key}=${new_list}"
	fi
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

# ── Mock ip and route tracking ────────────────────────────

_MOCK_ROUTES=""
_MOCK_RULES=""
_MOCK_IP6_ROUTES=""
_MOCK_IP6_RULES=""
_MOCK_NFT_SETS=""
_MOCK_NFT_RULES=""
_MOCK_GATEWAY="10.0.0.1"

ip() {
	case "$1" in
		-6)
			shift
			case "$1" in
				route)
					shift
					case "$1" in
						add) _MOCK_IP6_ROUTES="${_MOCK_IP6_ROUTES}
$*" ;;
						flush) _MOCK_IP6_ROUTES="" ;;
						show) echo "default via fe80::1 dev eth0" ;;
					esac
					;;
				rule)
					shift
					case "$1" in
						add) _MOCK_IP6_RULES="${_MOCK_IP6_RULES}
$*" ;;
						del) ;;
					esac
					;;
			esac
			;;
		route)
			shift
			case "$1" in
				add) _MOCK_ROUTES="${_MOCK_ROUTES}
$*" ;;
				flush) _MOCK_ROUTES="" ;;
				show)
					shift
					# Handle "ip route show dev <iface>" and "ip route show default"
					case "$1" in
						dev)
							echo "default via $_MOCK_GATEWAY dev $2"
							;;
						default)
							echo "default via $_MOCK_GATEWAY dev eth0"
							;;
						*)
							echo "default via $_MOCK_GATEWAY dev eth0"
							;;
					esac
					;;
			esac
			;;
		rule)
			shift
			case "$1" in
				add) _MOCK_RULES="${_MOCK_RULES}
$*" ;;
				del) ;;
				show) echo "$_MOCK_RULES" ;;
			esac
			;;
	esac
	return 0
}

# Mock nft
nft() {
	case "$1" in
		add)
			_MOCK_NFT_SETS="${_MOCK_NFT_SETS}
$*"
			_MOCK_NFT_RULES="${_MOCK_NFT_RULES}
$*"
			;;
		delete|destroy)
			;;
		list) ;;
	esac
	return 0
}

# Mock wget for resolver
wget() { return 1; }

# ── Source modules under test ─────────────────────────────

. "${MERGEN_ROOT}/files/usr/lib/mergen/core.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/utils.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/engine.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/resolver.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/route.sh"

# Override mergen_uci_add to avoid subshell variable loss
mergen_uci_add() {
	local type="$1"
	_MOCK_ADD_COUNTER=$((_MOCK_ADD_COUNTER + 1))
	local idx="cfg${_MOCK_ADD_COUNTER}"
	_MOCK_UCI_STORE="${_MOCK_UCI_STORE}
${MERGEN_CONF}.${idx}=${type}"
	_MOCK_FOREACH_SECTIONS="${_MOCK_FOREACH_SECTIONS} ${idx}"
	MERGEN_UCI_RESULT="$idx"
}

# Override lock functions for testing
mergen_lock_acquire() { return 0; }
mergen_lock_release() { return 0; }

# ── Setup/Teardown ────────────────────────────────────────

setUp() {
	_MOCK_UCI_STORE=""
	_MOCK_FOREACH_SECTIONS=""
	_MOCK_ADD_COUNTER=0
	MERGEN_UCI_RESULT=""
	_MOCK_ROUTES=""
	_MOCK_RULES=""
	_MOCK_IP6_ROUTES=""
	_MOCK_IP6_RULES=""
	_MOCK_NFT_SETS=""
	_MOCK_NFT_RULES=""

	_mock_uci_set "mergen.global.enabled=1"
	_mock_uci_set "mergen.global.default_table=100"
	_mock_uci_set "mergen.global.log_level=info"
	_mock_uci_set "mergen.global.set_type=nftables"
	_mock_uci_set "mergen.global.ipv6_enabled=0"
	_MOCK_CONFIG_LOADED="mergen"

	# Create tmp cache dir
	MERGEN_TMP="$(mktemp -d)"
	MERGEN_CACHE_DIR="${MERGEN_TMP}/cache"
	mkdir -p "$MERGEN_CACHE_DIR"
}

tearDown() {
	[ -n "$MERGEN_TMP" ] && rm -rf "$MERGEN_TMP"
}

# ── Helper ────────────────────────────────────────────────

_add_rule() {
	local name="$1" type="$2" targets="$3" via="$4" priority="${5:-100}"
	mergen_rule_add "$name" "$type" "$targets" "$via" "$priority"
}

_create_cache() {
	local asn="$1"
	shift
	local prefixes="$*"
	echo "$prefixes" | tr ' ' '\n' > "${MERGEN_CACHE_DIR}/AS${asn}.v4.txt"
	printf "timestamp=%s\nprovider=mock\n" "$(date +%s)" > "${MERGEN_CACHE_DIR}/AS${asn}.meta"
}

# ── Hotplug Script Logic Tests ────────────────────────────
# We simulate the hotplug script logic inline since the script
# uses exit instead of return (not sourceable for tests)

_simulate_hotplug() {
	local action="$1"
	local iface="$2"
	local applied=0 removed=0

	case "$action" in
		ifup)
			_hp_apply_cb() {
				local section="$1"
				local name via enabled

				config_get name "$section" "name" ""
				config_get via "$section" "via" ""
				config_get enabled "$section" "enabled" "1"

				if [ "$enabled" = "1" ] && [ "$via" = "$iface" ]; then
					if mergen_route_apply "$name"; then
						applied=$((applied + 1))
					fi
				fi
			}

			config_load "$MERGEN_CONF"
			config_foreach _hp_apply_cb "rule"
			echo "$applied"
			;;

		ifdown)
			_hp_remove_cb() {
				local section="$1"
				local name via enabled

				config_get name "$section" "name" ""
				config_get via "$section" "via" ""
				config_get enabled "$section" "enabled" "1"

				if [ "$enabled" = "1" ] && [ "$via" = "$iface" ]; then
					mergen_route_remove "$name" 2>/dev/null
					removed=$((removed + 1))
				fi
			}

			config_load "$MERGEN_CONF"
			config_foreach _hp_remove_cb "rule"
			echo "$removed"
			;;
	esac
}

# ── Tests ─────────────────────────────────────────────────

test_ifup_applies_rules() {
	_add_rule "vpnrule" "ip" "10.0.0.0/8" "wg0" 100
	_add_rule "otherrule" "ip" "172.16.0.0/12" "eth1" 200

	local result
	result="$(_simulate_hotplug "ifup" "wg0")"
	assertEquals "should apply 1 rule" 1 "$result"
}

test_ifup_skips_other_interfaces() {
	_add_rule "vpnrule" "ip" "10.0.0.0/8" "wg0" 100

	local result
	result="$(_simulate_hotplug "ifup" "eth1")"
	assertEquals "should apply 0 rules for eth1" 0 "$result"
}

test_ifup_skips_disabled_rules() {
	_add_rule "vpnrule" "ip" "10.0.0.0/8" "wg0" 100
	mergen_rule_toggle "vpnrule" "0"

	local result
	result="$(_simulate_hotplug "ifup" "wg0")"
	assertEquals "should skip disabled rules" 0 "$result"
}

test_ifdown_removes_routes() {
	_add_rule "vpnrule" "ip" "10.0.0.0/8" "wg0" 100

	# First apply
	_simulate_hotplug "ifup" "wg0" >/dev/null

	# Then remove
	local result
	result="$(_simulate_hotplug "ifdown" "wg0")"
	assertEquals "should remove 1 rule" 1 "$result"
}

test_ifdown_skips_other_interfaces() {
	_add_rule "vpnrule" "ip" "10.0.0.0/8" "wg0" 100
	_simulate_hotplug "ifup" "wg0" >/dev/null

	local result
	result="$(_simulate_hotplug "ifdown" "eth1")"
	assertEquals "should remove 0 rules for eth1" 0 "$result"
}

test_multiple_rules_same_interface() {
	_add_rule "rule1" "ip" "10.0.0.0/8" "wg0" 100
	_add_rule "rule2" "ip" "172.16.0.0/12" "wg0" 200

	local result
	result="$(_simulate_hotplug "ifup" "wg0")"
	assertEquals "should apply 2 rules" 2 "$result"
}

test_mixed_interfaces() {
	_add_rule "vpnrule" "ip" "10.0.0.0/8" "wg0" 100
	_add_rule "lanrule" "ip" "172.16.0.0/12" "eth1" 200
	_add_rule "vpnrule2" "ip" "192.168.0.0/16" "wg0" 300

	local result
	result="$(_simulate_hotplug "ifup" "wg0")"
	assertEquals "should apply only wg0 rules" 2 "$result"
}

test_no_rules_for_interface() {
	_add_rule "vpnrule" "ip" "10.0.0.0/8" "wg0" 100

	local result
	result="$(_simulate_hotplug "ifup" "tun0")"
	assertEquals "should apply 0 rules for tun0" 0 "$result"
}

test_ifup_ifdown_cycle() {
	_add_rule "vpnrule" "ip" "10.0.0.0/8" "wg0" 100

	# Interface comes up
	local up_result
	up_result="$(_simulate_hotplug "ifup" "wg0")"
	assertEquals "should apply on ifup" 1 "$up_result"

	# Interface goes down
	local down_result
	down_result="$(_simulate_hotplug "ifdown" "wg0")"
	assertEquals "should remove on ifdown" 1 "$down_result"

	# Interface comes back up
	up_result="$(_simulate_hotplug "ifup" "wg0")"
	assertEquals "should re-apply on second ifup" 1 "$up_result"
}

test_asn_rule_with_cache() {
	_add_rule "cloudflare" "asn" "13335" "wg0" 100
	_create_cache "13335" "104.16.0.0/13 104.24.0.0/14"

	# Override mergen_resolve_asn to use cache directly for test
	_orig_resolve="$(type mergen_resolve_asn 2>/dev/null)"
	mergen_resolve_asn() {
		local asn="$1"
		MERGEN_RESOLVE_RESULT_V4="$(cat "${MERGEN_CACHE_DIR}/AS${asn}.v4.txt" 2>/dev/null)"
		MERGEN_RESOLVE_RESULT_V6=""
		MERGEN_RESOLVE_COUNT_V4=2
		MERGEN_RESOLVE_COUNT_V6=0
		MERGEN_RESOLVE_PROVIDER="mock"
		return 0
	}

	local result
	result="$(_simulate_hotplug "ifup" "wg0")"
	assertEquals "should apply ASN rule from cache" 1 "$result"
}

# ── Load Runner ───────────────────────────────────────────
. "${MERGEN_TEST_DIR}/shunit2"

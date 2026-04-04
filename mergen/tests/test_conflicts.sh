#!/bin/sh
# Test suite for conflict detection (T028)
# Tests CIDR overlap detection and cross-rule conflict checking
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

# Mock ip command (minimal — not needed for conflict detection)
ip() { return 0; }

# ── Source modules under test ─────────────────────────────

. "${MERGEN_ROOT}/files/usr/lib/mergen/core.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/utils.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/engine.sh"

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

# ── Setup/Teardown ────────────────────────────────────────

setUp() {
	_MOCK_UCI_STORE=""
	_MOCK_FOREACH_SECTIONS=""
	_MOCK_ADD_COUNTER=0
	MERGEN_UCI_RESULT=""
	MERGEN_CONFLICT_COUNT=0
	MERGEN_CONFLICT_REPORT=""

	_mock_uci_set "mergen.global.enabled=1"
	_mock_uci_set "mergen.global.default_table=100"
	_mock_uci_set "mergen.global.log_level=info"
	_MOCK_CONFIG_LOADED="mergen"
}

# ── Helper ────────────────────────────────────────────────

_add_rule() {
	local name="$1" type="$2" targets="$3" via="$4" priority="${5:-100}"
	mergen_rule_add "$name" "$type" "$targets" "$via" "$priority"
}

# ── IP to Int Conversion Tests ────────────────────────────

test_ip_to_int_zero() {
	_mergen_ip_to_int "0.0.0.0"
	assertEquals "0.0.0.0 -> 0" 0 "$MERGEN_IP_INT"
}

test_ip_to_int_simple() {
	_mergen_ip_to_int "10.0.0.0"
	assertEquals "10.0.0.0 -> 167772160" 167772160 "$MERGEN_IP_INT"
}

test_ip_to_int_max() {
	_mergen_ip_to_int "255.255.255.255"
	assertEquals "255.255.255.255" 4294967295 "$MERGEN_IP_INT"
}

test_int_to_ip_zero() {
	_mergen_int_to_ip 0
	assertEquals "0 -> 0.0.0.0" "0.0.0.0" "$MERGEN_IP_STR"
}

test_int_to_ip_simple() {
	_mergen_int_to_ip 167772160
	assertEquals "167772160 -> 10.0.0.0" "10.0.0.0" "$MERGEN_IP_STR"
}

# ── CIDR Range Tests ─────────────────────────────────────

test_cidr_range_slash8() {
	_mergen_cidr_range "10.0.0.0/8"
	_mergen_int_to_ip "$MERGEN_CIDR_START"
	assertEquals "Start of 10.0.0.0/8" "10.0.0.0" "$MERGEN_IP_STR"
	_mergen_int_to_ip "$MERGEN_CIDR_END"
	assertEquals "End of 10.0.0.0/8" "10.255.255.255" "$MERGEN_IP_STR"
}

test_cidr_range_slash24() {
	_mergen_cidr_range "192.168.1.0/24"
	_mergen_int_to_ip "$MERGEN_CIDR_START"
	assertEquals "Start of 192.168.1.0/24" "192.168.1.0" "$MERGEN_IP_STR"
	_mergen_int_to_ip "$MERGEN_CIDR_END"
	assertEquals "End of 192.168.1.0/24" "192.168.1.255" "$MERGEN_IP_STR"
}

test_cidr_range_slash32() {
	_mergen_cidr_range "1.2.3.4/32"
	_mergen_int_to_ip "$MERGEN_CIDR_START"
	assertEquals "Start of /32" "1.2.3.4" "$MERGEN_IP_STR"
	_mergen_int_to_ip "$MERGEN_CIDR_END"
	assertEquals "End of /32" "1.2.3.4" "$MERGEN_IP_STR"
}

# ── CIDR Overlap Tests ───────────────────────────────────

test_overlap_supernet_contains_subnet() {
	_mergen_cidr_overlaps "10.0.0.0/8" "10.1.0.0/16"
	assertEquals "Supernet contains subnet" 0 $?
}

test_overlap_same_prefix() {
	_mergen_cidr_overlaps "192.168.1.0/24" "192.168.1.0/24"
	assertEquals "Same prefix overlaps" 0 $?
}

test_overlap_partial() {
	_mergen_cidr_overlaps "10.0.0.0/15" "10.1.0.0/16"
	assertEquals "Partial overlap" 0 $?
}

test_no_overlap_disjoint() {
	_mergen_cidr_overlaps "10.0.0.0/8" "172.16.0.0/12"
	assertNotEquals "Disjoint ranges" 0 $?
}

test_no_overlap_adjacent() {
	_mergen_cidr_overlaps "10.0.0.0/25" "10.0.0.128/25"
	assertNotEquals "Adjacent but not overlapping" 0 $?
}

# ── Conflict Detection Tests ─────────────────────────────

test_no_conflict_different_prefixes() {
	_add_rule "rule_a" "ip" "10.0.0.0/8" "wg0" "100"
	_add_rule "rule_b" "ip" "172.16.0.0/12" "eth0" "200"

	mergen_check_conflicts
	assertEquals "No conflicts detected" 0 $?
	assertEquals "Zero conflict count" 0 "$MERGEN_CONFLICT_COUNT"
}

test_conflict_overlapping_different_interfaces() {
	_add_rule "vpn" "ip" "10.0.0.0/8" "wg0" "100"
	_add_rule "office" "ip" "10.1.0.0/16" "eth0" "200"

	mergen_check_conflicts
	assertNotEquals "Conflict detected" 0 $?
	assertEquals "One conflict" 1 "$MERGEN_CONFLICT_COUNT"
}

test_no_conflict_same_interface() {
	_add_rule "vpn_a" "ip" "10.0.0.0/8" "wg0" "100"
	_add_rule "vpn_b" "ip" "10.1.0.0/16" "wg0" "200"

	mergen_check_conflicts
	assertEquals "Same interface is not a conflict" 0 $?
	assertEquals "Zero conflicts" 0 "$MERGEN_CONFLICT_COUNT"
}

test_conflict_multiple() {
	_add_rule "rule_a" "ip" "10.0.0.0/8" "wg0" "100"
	_add_rule "rule_b" "ip" "10.1.0.0/16" "eth0" "200"
	_add_rule "rule_c" "ip" "10.2.0.0/16" "eth1" "300"

	mergen_check_conflicts
	assertNotEquals "Multiple conflicts detected" 0 $?
	assertTrue "Multiple conflict count" "[ $MERGEN_CONFLICT_COUNT -ge 2 ]"
}

test_conflict_disabled_rule_skipped() {
	_add_rule "active" "ip" "10.0.0.0/8" "wg0" "100"
	_add_rule "disabled" "ip" "10.1.0.0/16" "eth0" "200"
	# Disable the second rule
	mergen_rule_toggle "disabled" "0"

	mergen_check_conflicts
	assertEquals "Disabled rule skipped" 0 $?
	assertEquals "Zero conflicts" 0 "$MERGEN_CONFLICT_COUNT"
}

test_conflict_report_content() {
	_add_rule "vpn" "ip" "10.0.0.0/8" "wg0" "100"
	_add_rule "office" "ip" "10.1.0.0/16" "eth0" "200"

	mergen_check_conflicts

	# Report should mention both rule names
	case "$MERGEN_CONFLICT_REPORT" in
		*"vpn"*"office"*|*"office"*"vpn"*)
			assertTrue "Report mentions both rules" true
			;;
		*)
			fail "Report should mention both rule names: $MERGEN_CONFLICT_REPORT"
			;;
	esac
}

test_no_conflict_asn_rules_skipped() {
	# ASN rules are resolved at apply time — cannot check statically
	_add_rule "asn_a" "asn" "13335" "wg0" "100"
	_add_rule "asn_b" "asn" "15169" "eth0" "200"

	mergen_check_conflicts
	assertEquals "ASN rules skipped" 0 $?
}

# ── Load shunit2 ─────────────────────────────────────────

SHUNIT2_PATH="${MERGEN_TEST_DIR}/shunit2"
if [ ! -f "$SHUNIT2_PATH" ]; then
	SHUNIT2_PATH="$(command -v shunit2 2>/dev/null)"
fi

if [ -z "$SHUNIT2_PATH" ] || [ ! -f "$SHUNIT2_PATH" ]; then
	echo "HATA: shunit2 bulunamadı."
	exit 1
fi

. "$SHUNIT2_PATH"

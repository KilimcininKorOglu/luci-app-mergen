#!/bin/sh
# Test suite for CIDR aggregation (T028)
# Tests merging adjacent CIDR blocks into larger prefixes
# Uses shunit2 framework — ash/busybox compatible

MERGEN_TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
MERGEN_ROOT="$(cd "$MERGEN_TEST_DIR/.." && pwd)"

# ── Minimal Mock UCI System ───────────────────────────────

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
		add) return 0 ;;
		delete) return 0 ;;
		add_list) return 0 ;;
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

config_load() { _MOCK_CONFIG_LOADED="$1"; }

config_get() {
	local var="$1" section="$2" option="$3" default="$4"
	local val
	val="$(_mock_uci_get "${_MOCK_CONFIG_LOADED}.${section}.${option}")"
	[ -z "$val" ] && val="$default"
	eval "$var=\"$val\""
}

config_foreach() { :; }

# Mock logger and flock
logger() { :; }
flock() { return 0; }

# Mock ip command
ip() { return 0; }

# ── Source modules under test ─────────────────────────────

. "${MERGEN_ROOT}/files/usr/lib/mergen/core.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/utils.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/engine.sh"

# ── Setup/Teardown ────────────────────────────────────────

setUp() {
	_MOCK_UCI_STORE=""
	_MOCK_CONFIG_LOADED="mergen"
	MERGEN_TMP="/tmp/mergen_test_agg_$$"
	mkdir -p "$MERGEN_TMP"
}

tearDown() {
	rm -rf "$MERGEN_TMP"
}

# ── Aggregation Tests ────────────────────────────────────

test_aggregate_adjacent_slash25() {
	local input="10.0.0.0/25
10.0.0.128/25"

	local result
	result="$(mergen_aggregate_prefixes "$input")"
	assertEquals "Two /25s merge into /24" "10.0.0.0/24" "$result"
}

test_aggregate_adjacent_slash24() {
	local input="192.168.0.0/24
192.168.1.0/24"

	local result
	result="$(mergen_aggregate_prefixes "$input")"
	assertEquals "Two /24s merge into /23" "192.168.0.0/23" "$result"
}

test_aggregate_no_merge_non_adjacent() {
	local input="10.0.0.0/24
10.0.2.0/24"

	local result
	result="$(mergen_aggregate_prefixes "$input")"
	local count
	count="$(echo "$result" | wc -l | tr -d ' ')"
	assertEquals "Non-adjacent stays separate" 2 "$count"
}

test_aggregate_no_merge_different_sizes() {
	local input="10.0.0.0/24
10.0.1.0/25"

	local result
	result="$(mergen_aggregate_prefixes "$input")"
	local count
	count="$(echo "$result" | wc -l | tr -d ' ')"
	assertEquals "Different sizes stay separate" 2 "$count"
}

test_aggregate_multiple_pairs() {
	local input="10.0.0.0/25
10.0.0.128/25
10.0.1.0/25
10.0.1.128/25"

	local result
	result="$(mergen_aggregate_prefixes "$input")"
	local count
	count="$(echo "$result" | wc -l | tr -d ' ')"
	# Two pairs each merge to /24, then those two /24s merge to /23
	assertEquals "Cascading merge to /23" 1 "$count"
	assertEquals "Result is /23" "10.0.0.0/23" "$result"
}

test_aggregate_single_prefix() {
	local input="10.0.0.0/8"

	local result
	result="$(mergen_aggregate_prefixes "$input")"
	assertEquals "Single prefix unchanged" "10.0.0.0/8" "$result"
}

test_aggregate_empty_input() {
	local result
	result="$(mergen_aggregate_prefixes "")"
	assertEquals "Empty input returns empty" "" "$result"
}

test_aggregate_deduplicates() {
	local input="10.0.0.0/24
10.0.0.0/24
10.0.0.0/24"

	local result
	result="$(mergen_aggregate_prefixes "$input")"
	assertEquals "Duplicates removed" "10.0.0.0/24" "$result"
}

test_aggregate_ipv6_passthrough() {
	# IPv6 prefixes should be filtered out (not aggregated)
	local input="2001:db8::/32
2001:db8:1::/48"

	local result
	result="$(mergen_aggregate_prefixes "$input")"
	assertEquals "IPv6 filtered out" "" "$result"
}

test_aggregate_mixed_v4_v6() {
	local input="10.0.0.0/25
10.0.0.128/25
2001:db8::/32"

	local result
	result="$(mergen_aggregate_prefixes "$input")"
	assertEquals "Only IPv4 aggregated" "10.0.0.0/24" "$result"
}

test_aggregate_preserves_non_adjacent() {
	# Three prefixes: first two can merge, third is separate
	local input="10.0.0.0/25
10.0.0.128/25
172.16.0.0/24"

	local result
	result="$(mergen_aggregate_prefixes "$input")"
	local count
	count="$(echo "$result" | wc -l | tr -d ' ')"
	assertEquals "Merged + separate = 2 entries" 2 "$count"

	# Check both present
	case "$result" in
		*"10.0.0.0/24"*) assertTrue "Merged prefix present" true ;;
		*) fail "Merged prefix missing" ;;
	esac
	case "$result" in
		*"172.16.0.0/24"*) assertTrue "Separate prefix present" true ;;
		*) fail "Separate prefix missing" ;;
	esac
}

test_aggregate_unaligned_no_merge() {
	# 10.0.0.128/25 + 10.0.1.0/25 are adjacent but don't align to /24
	local input="10.0.0.128/25
10.0.1.0/25"

	local result
	result="$(mergen_aggregate_prefixes "$input")"
	local count
	count="$(echo "$result" | wc -l | tr -d ' ')"
	assertEquals "Unaligned adjacent blocks stay separate" 2 "$count"
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

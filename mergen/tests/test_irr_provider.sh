#!/bin/sh
# Test suite for mergen/files/etc/mergen/providers/irr.sh
# Uses shunit2 framework — ash/busybox compatible
# Tests use mock whois responses instead of real RADB queries

MERGEN_TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
MERGEN_ROOT="$(cd "$MERGEN_TEST_DIR/.." && pwd)"

# ── Test Temp Directory ─────────────────────────────────

_TEST_TMPDIR=""
_MOCK_WHOIS_RESPONSE=""
_MOCK_WHOIS_EXIT=0

# ── Mock Dependencies ───────────────────────────────────

MERGEN_CONF="mergen"
MERGEN_UCI_RESULT=""
MERGEN_PROVIDER_WHOIS_SERVER="whois.radb.net"
MERGEN_PROVIDER_TIMEOUT="30"

mergen_log() { :; }

mergen_uci_get() {
	MERGEN_UCI_RESULT="$3"
}

# ── Source provider under test ──────────────────────────

. "${MERGEN_ROOT}/files/etc/mergen/providers/irr.sh"

# Override _irr_whois_query to use mock response
_irr_whois_query() {
	if [ "$_MOCK_WHOIS_EXIT" -ne 0 ]; then
		return "$_MOCK_WHOIS_EXIT"
	fi
	echo "$_MOCK_WHOIS_RESPONSE"
}

# ── Setup/Teardown ──────────────────────────────────────

setUp() {
	_TEST_TMPDIR="$(mktemp -d)"
	_MOCK_WHOIS_RESPONSE=""
	_MOCK_WHOIS_EXIT=0
	MERGEN_PROVIDER_WHOIS_SERVER="whois.radb.net"
	MERGEN_PROVIDER_TIMEOUT="30"
}

tearDown() {
	if [ -n "$_TEST_TMPDIR" ] && [ -d "$_TEST_TMPDIR" ]; then
		rm -rf "$_TEST_TMPDIR"
	fi
}

# ── Mock RADB Responses ─────────────────────────────────

_IRR_RESPONSE_V4='route:          104.16.0.0/12
descr:          Cloudflare Inc
origin:         AS13335
mnt-by:         MNT-CLOUDFLARE
source:         RADB

route:          172.64.0.0/13
descr:          Cloudflare Inc
origin:         AS13335
mnt-by:         MNT-CLOUDFLARE
source:         RADB'

_IRR_RESPONSE_MIXED='route:          104.16.0.0/12
descr:          Cloudflare Inc
origin:         AS13335
source:         RADB

route6:         2606:4700::/32
descr:          Cloudflare Inc
origin:         AS13335
source:         RADB

route:          172.64.0.0/13
descr:          Cloudflare Inc
origin:         AS13335
source:         RADB

route6:         2803:f800::/32
descr:          Cloudflare Inc
origin:         AS13335
source:         RADB'

_IRR_RESPONSE_EMPTY='% No entries found for the selected source(s).'

# ── Provider Name Tests ─────────────────────────────────

test_provider_name() {
	local name
	name="$(provider_name)"
	assertEquals "Provider name" "IRR/RADB" "$name"
}

# ── Provider Test (Connectivity) ────────────────────────

test_provider_test_success() {
	_MOCK_WHOIS_RESPONSE="$_IRR_RESPONSE_V4"
	_MOCK_WHOIS_EXIT=0

	provider_test
	assertEquals "Test succeeds when RADB reachable" 0 $?
}

test_provider_test_failure() {
	_MOCK_WHOIS_RESPONSE=""
	_MOCK_WHOIS_EXIT=1

	provider_test
	assertNotEquals "Test fails when RADB unreachable" 0 $?
}

# ── IPv4 Only Resolution ───────────────────────────────

test_resolve_ipv4_only() {
	_MOCK_WHOIS_RESPONSE="$_IRR_RESPONSE_V4"

	local v4_output v6_output
	v4_output="$(provider_resolve "13335" 3>"${_TEST_TMPDIR}/v6.txt")"
	v6_output="$(cat "${_TEST_TMPDIR}/v6.txt" 2>/dev/null)"

	echo "$v4_output" | grep -q "104.16.0.0/12"
	assertEquals "Contains first v4 prefix" 0 $?

	echo "$v4_output" | grep -q "172.64.0.0/13"
	assertEquals "Contains second v4 prefix" 0 $?

	assertEquals "No v6 output" "" "$v6_output"
}

# ── Mixed IPv4/IPv6 Resolution ──────────────────────────

test_resolve_mixed_v4_v6() {
	_MOCK_WHOIS_RESPONSE="$_IRR_RESPONSE_MIXED"

	local v4_output v6_output
	v4_output="$(provider_resolve "13335" 3>"${_TEST_TMPDIR}/v6.txt")"
	v6_output="$(cat "${_TEST_TMPDIR}/v6.txt" 2>/dev/null)"

	echo "$v4_output" | grep -q "104.16.0.0/12"
	assertEquals "V4 prefix 1" 0 $?

	echo "$v4_output" | grep -q "172.64.0.0/13"
	assertEquals "V4 prefix 2" 0 $?

	echo "$v6_output" | grep -q "2606:4700::/32"
	assertEquals "V6 prefix 1" 0 $?

	echo "$v6_output" | grep -q "2803:f800::/32"
	assertEquals "V6 prefix 2" 0 $?
}

# ── Empty Result ────────────────────────────────────────

test_resolve_empty_result() {
	_MOCK_WHOIS_RESPONSE="$_IRR_RESPONSE_EMPTY"

	local v4_output
	v4_output="$(provider_resolve "99999" 3>/dev/null)"
	assertEquals "Empty result returns success" 0 $?

	local line_count
	line_count="$(echo "$v4_output" | grep -c '.' 2>/dev/null)"
	assertEquals "No prefix lines in output" "0" "$line_count"
}

# ── Whois Failure ──────────────────────────────────────

test_resolve_whois_failure() {
	_MOCK_WHOIS_RESPONSE=""
	_MOCK_WHOIS_EXIT=1

	provider_resolve "13335" 3>/dev/null
	assertNotEquals "Whois failure returns non-zero" 0 $?
}

test_resolve_empty_response() {
	_MOCK_WHOIS_RESPONSE=""
	_MOCK_WHOIS_EXIT=0

	provider_resolve "13335" 3>/dev/null
	assertNotEquals "Empty whois response returns non-zero" 0 $?
}

# ── V4/V6 Separation Accuracy ──────────────────────────

test_v4_v6_separation_no_mixing() {
	_MOCK_WHOIS_RESPONSE="$_IRR_RESPONSE_MIXED"

	local v4_output v6_output
	v4_output="$(provider_resolve "13335" 3>"${_TEST_TMPDIR}/v6.txt")"
	v6_output="$(cat "${_TEST_TMPDIR}/v6.txt" 2>/dev/null)"

	local v6_in_v4
	v6_in_v4="$(echo "$v4_output" | grep -c ':' 2>/dev/null)"
	assertEquals "No IPv6 in v4 output" "0" "$v6_in_v4"

	local v4_in_v6
	v4_in_v6="$(echo "$v6_output" | grep -cv ':' 2>/dev/null)"
	assertEquals "No IPv4 in v6 output" "0" "$v4_in_v6"
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

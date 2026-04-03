#!/bin/sh
# Test suite for mergen/files/etc/mergen/providers/bgptools.sh
# Uses shunit2 framework — ash/busybox compatible
# Tests use mock HTTP responses instead of real API calls

MERGEN_TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
MERGEN_ROOT="$(cd "$MERGEN_TEST_DIR/.." && pwd)"

# ── Test Temp Directory ─────────────────────────────────

_TEST_TMPDIR=""
_MOCK_HTTP_RESPONSE=""
_MOCK_HTTP_EXIT=0

# ── Mock Dependencies ───────────────────────────────────

MERGEN_CONF="mergen"
MERGEN_UCI_RESULT=""
MERGEN_PROVIDER_URL="https://bgp.tools/table.jsonl"
MERGEN_PROVIDER_TIMEOUT="30"
MERGEN_PROVIDER_API_KEY=""

mergen_log() { :; }

mergen_uci_get() {
	MERGEN_UCI_RESULT="$3"
}

# ── Source provider under test ──────────────────────────

. "${MERGEN_ROOT}/files/etc/mergen/providers/bgptools.sh"

# Override _bgptools_http_get to use mock response
_bgptools_http_get() {
	local url="$1" timeout="$2" method="${3:-GET}"

	if [ "$_MOCK_HTTP_EXIT" -ne 0 ]; then
		return "$_MOCK_HTTP_EXIT"
	fi

	# For HEAD requests, just return success
	if [ "$method" = "HEAD" ]; then
		echo "HTTP/1.1 200 OK"
		return 0
	fi

	echo "$_MOCK_HTTP_RESPONSE"
}

# ── Setup/Teardown ──────────────────────────────────────

setUp() {
	_TEST_TMPDIR="$(mktemp -d)"
	_MOCK_HTTP_RESPONSE=""
	_MOCK_HTTP_EXIT=0
	MERGEN_PROVIDER_URL="https://bgp.tools/table.jsonl"
	MERGEN_PROVIDER_TIMEOUT="30"
	MERGEN_PROVIDER_API_KEY=""
}

tearDown() {
	if [ -n "$_TEST_TMPDIR" ] && [ -d "$_TEST_TMPDIR" ]; then
		rm -rf "$_TEST_TMPDIR"
	fi
}

# ── Mock API Responses (JSONL format) ────────────────────

# JSONL: one JSON object per line with CIDR field
_BGPTOOLS_RESPONSE_V4='{"CIDR":"104.16.0.0/12","ASN":13335,"Path":[]}
{"CIDR":"172.64.0.0/13","ASN":13335,"Path":[]}'

_BGPTOOLS_RESPONSE_MIXED='{"CIDR":"104.16.0.0/12","ASN":13335,"Path":[]}
{"CIDR":"2606:4700::/32","ASN":13335,"Path":[]}
{"CIDR":"172.64.0.0/13","ASN":13335,"Path":[]}
{"CIDR":"2803:f800::/32","ASN":13335,"Path":[]}'

_BGPTOOLS_RESPONSE_PREFIX_FIELD='{"prefix":"104.16.0.0/12","origin":13335}
{"prefix":"172.64.0.0/13","origin":13335}'

_BGPTOOLS_RESPONSE_EMPTY=''

# ── Provider Name Tests ─────────────────────────────────

test_provider_name() {
	local name
	name="$(provider_name)"
	assertEquals "Provider name" "bgp.tools" "$name"
}

# ── Provider Test (Connectivity) ────────────────────────

test_provider_test_success() {
	_MOCK_HTTP_EXIT=0

	provider_test
	assertEquals "Test should succeed when API reachable" 0 $?
}

test_provider_test_failure() {
	_MOCK_HTTP_EXIT=1

	provider_test
	assertNotEquals "Test should fail when API unreachable" 0 $?
}

# ── IPv4 Only Resolution (CIDR field) ──────────────────

test_resolve_ipv4_cidr_field() {
	_MOCK_HTTP_RESPONSE="$_BGPTOOLS_RESPONSE_V4"

	local v4_output
	v4_output="$(provider_resolve "13335" 3>"${_TEST_TMPDIR}/v6.txt")"

	echo "$v4_output" | grep -q "104.16.0.0/12"
	assertEquals "Contains first v4 prefix" 0 $?

	echo "$v4_output" | grep -q "172.64.0.0/13"
	assertEquals "Contains second v4 prefix" 0 $?
}

# ── IPv4 Only Resolution (prefix field fallback) ───────

test_resolve_ipv4_prefix_field() {
	_MOCK_HTTP_RESPONSE="$_BGPTOOLS_RESPONSE_PREFIX_FIELD"

	local v4_output
	v4_output="$(provider_resolve "13335" 3>/dev/null)"

	echo "$v4_output" | grep -q "104.16.0.0/12"
	assertEquals "Contains v4 prefix via prefix field" 0 $?
}

# ── Mixed IPv4/IPv6 Resolution ──────────────────────────

test_resolve_mixed_v4_v6() {
	_MOCK_HTTP_RESPONSE="$_BGPTOOLS_RESPONSE_MIXED"

	local v4_output v6_output
	v4_output="$(provider_resolve "13335" 3>"${_TEST_TMPDIR}/v6.txt")"
	v6_output="$(cat "${_TEST_TMPDIR}/v6.txt" 2>/dev/null)"

	# Check IPv4 prefixes on stdout
	echo "$v4_output" | grep -q "104.16.0.0/12"
	assertEquals "V4 prefix 1" 0 $?

	echo "$v4_output" | grep -q "172.64.0.0/13"
	assertEquals "V4 prefix 2" 0 $?

	# Check IPv6 prefixes on fd 3
	echo "$v6_output" | grep -q "2606:4700::/32"
	assertEquals "V6 prefix 1" 0 $?

	echo "$v6_output" | grep -q "2803:f800::/32"
	assertEquals "V6 prefix 2" 0 $?
}

# ── Empty Result ────────────────────────────────────────

test_resolve_empty_response() {
	_MOCK_HTTP_RESPONSE=""
	_MOCK_HTTP_EXIT=0

	provider_resolve "99999" 3>/dev/null
	assertNotEquals "Empty response returns non-zero" 0 $?
}

# ── HTTP Failure ────────────────────────────────────────

test_resolve_http_failure() {
	_MOCK_HTTP_EXIT=1

	provider_resolve "13335" 3>/dev/null
	assertNotEquals "HTTP failure returns non-zero" 0 $?
}

# ── V4/V6 Separation ───────────────────────────────────

test_v4_v6_separation_no_mixing() {
	_MOCK_HTTP_RESPONSE="$_BGPTOOLS_RESPONSE_MIXED"

	local v4_output v6_output
	v4_output="$(provider_resolve "13335" 3>"${_TEST_TMPDIR}/v6.txt")"
	v6_output="$(cat "${_TEST_TMPDIR}/v6.txt" 2>/dev/null)"

	# V4 output should not contain IPv6
	local v6_in_v4
	v6_in_v4="$(echo "$v4_output" | grep -c ':' 2>/dev/null)"
	assertEquals "No IPv6 in v4 output" "0" "$v6_in_v4"

	# V6 output should not contain IPv4
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

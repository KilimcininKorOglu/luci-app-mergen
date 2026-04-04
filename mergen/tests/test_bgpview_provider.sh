#!/bin/sh
# Test suite for mergen/files/etc/mergen/providers/bgpview.sh
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
MERGEN_PROVIDER_URL="https://api.bgpview.io"
MERGEN_PROVIDER_TIMEOUT="30"

mergen_log() { :; }

mergen_uci_get() {
	MERGEN_UCI_RESULT="$3"
}

# Mock jsonfilter — OpenWrt's native JSON parser
# Supports the subset of expressions used by bgpview.sh
jsonfilter() {
	local expression=""
	while [ $# -gt 0 ]; do
		case "$1" in
			-e) expression="$2"; shift 2 ;;
			*) shift ;;
		esac
	done

	local input
	input="$(cat)"

	case "$expression" in
		'@.status')
			_json_extract_simple "$input" '"status"'
			;;
		'@.status_message')
			_json_extract_simple "$input" '"status_message"'
			;;
		'@.data.ipv4_prefixes[*].prefix')
			# Extract all prefix values from ipv4_prefixes array
			echo "$input" | tr ',' '\n' | tr '[' '\n' | tr ']' '\n' | \
				sed -n 's/.*"prefix"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | \
				grep -v ':'
			;;
		'@.data.ipv6_prefixes[*].prefix')
			# Extract all prefix values from ipv6_prefixes array
			# Find ipv6_prefixes section and extract prefixes with colons
			local in_v6=0
			echo "$input" | tr ',' '\n' | while IFS= read -r chunk; do
				case "$chunk" in
					*ipv6_prefixes*) in_v6=1 ;;
				esac
				if [ "$in_v6" -eq 1 ]; then
					local p
					p="$(echo "$chunk" | sed -n 's/.*"prefix"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
					[ -n "$p" ] && echo "$p"
				fi
			done
			;;
	esac
}

# Simple JSON value extractor for a given key
_json_extract_simple() {
	local json="$1"
	local key="$2"
	echo "$json" | sed -n "s/.*${key}[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

# ── Source provider under test ──────────────────────────

. "${MERGEN_ROOT}/files/etc/mergen/providers/bgpview.sh"

# Override _bgpview_http_get to use mock response
_bgpview_http_get() {
	if [ "$_MOCK_HTTP_EXIT" -ne 0 ]; then
		return "$_MOCK_HTTP_EXIT"
	fi
	echo "$_MOCK_HTTP_RESPONSE"
}

# ── Setup/Teardown ──────────────────────────────────────

setUp() {
	_TEST_TMPDIR="$(mktemp -d)"
	_MOCK_HTTP_RESPONSE=""
	_MOCK_HTTP_EXIT=0
	MERGEN_PROVIDER_URL="https://api.bgpview.io"
	MERGEN_PROVIDER_TIMEOUT="30"
}

tearDown() {
	if [ -n "$_TEST_TMPDIR" ] && [ -d "$_TEST_TMPDIR" ]; then
		rm -rf "$_TEST_TMPDIR"
	fi
}

# ── Mock API Responses ──────────────────────────────────

_BGPVIEW_RESPONSE_V4='{"status":"ok","data":{"ipv4_prefixes":[{"prefix":"104.16.0.0/12","ip":"104.16.0.0","cidr":12},{"prefix":"172.64.0.0/13","ip":"172.64.0.0","cidr":13}],"ipv6_prefixes":[]}}'

_BGPVIEW_RESPONSE_MIXED='{"status":"ok","data":{"ipv4_prefixes":[{"prefix":"104.16.0.0/12","ip":"104.16.0.0","cidr":12},{"prefix":"172.64.0.0/13","ip":"172.64.0.0","cidr":13}],"ipv6_prefixes":[{"prefix":"2606:4700::/32","ip":"2606:4700::","cidr":32},{"prefix":"2803:f800::/32","ip":"2803:f800::","cidr":32}]}}'

_BGPVIEW_RESPONSE_EMPTY='{"status":"ok","data":{"ipv4_prefixes":[],"ipv6_prefixes":[]}}'

_BGPVIEW_RESPONSE_ERROR='{"status":"error","status_message":"Malformed ASN"}'

# ── Provider Name Tests ─────────────────────────────────

test_provider_name() {
	local name
	name="$(provider_name)"
	assertEquals "Provider name" "BGPView" "$name"
}

# ── Provider Test (Connectivity) ────────────────────────

test_provider_test_success() {
	_MOCK_HTTP_RESPONSE='{"status":"ok"}'
	_MOCK_HTTP_EXIT=0

	provider_test
	assertEquals "Test should succeed when API reachable" 0 $?
}

test_provider_test_failure() {
	_MOCK_HTTP_EXIT=1

	provider_test
	assertNotEquals "Test should fail when API unreachable" 0 $?
}

# ── IPv4 Only Resolution ───────────────────────────────

test_resolve_ipv4_only() {
	_MOCK_HTTP_RESPONSE="$_BGPVIEW_RESPONSE_V4"

	local v4_output v6_output
	v4_output="$(provider_resolve "13335" 3>"${_TEST_TMPDIR}/v6.txt")"
	v6_output="$(cat "${_TEST_TMPDIR}/v6.txt" 2>/dev/null)"

	# Check IPv4 prefixes
	echo "$v4_output" | grep -q "104.16.0.0/12"
	assertEquals "Contains first v4 prefix" 0 $?

	echo "$v4_output" | grep -q "172.64.0.0/13"
	assertEquals "Contains second v4 prefix" 0 $?

	# No IPv6 output
	assertEquals "No v6 output" "" "$v6_output"
}

# ── Mixed IPv4/IPv6 Resolution ──────────────────────────

test_resolve_mixed_v4_v6() {
	_MOCK_HTTP_RESPONSE="$_BGPVIEW_RESPONSE_MIXED"

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

test_resolve_empty_result() {
	_MOCK_HTTP_RESPONSE="$_BGPVIEW_RESPONSE_EMPTY"

	local v4_output
	v4_output="$(provider_resolve "99999" 3>/dev/null)"
	assertEquals "Empty result returns success" 0 $?

	# No output lines
	local line_count
	line_count="$(echo "$v4_output" | grep -c '.' 2>/dev/null)"
	assertEquals "No lines in output" "0" "$line_count"
}

# ── Error Handling ──────────────────────────────────────

test_resolve_api_error() {
	_MOCK_HTTP_RESPONSE="$_BGPVIEW_RESPONSE_ERROR"

	provider_resolve "invalid" 3>/dev/null
	assertNotEquals "API error returns non-zero" 0 $?
}

test_resolve_timeout() {
	_MOCK_HTTP_RESPONSE=""
	_MOCK_HTTP_EXIT=0

	provider_resolve "13335" 3>/dev/null
	assertNotEquals "Empty response returns non-zero" 0 $?
}

test_resolve_http_failure() {
	_MOCK_HTTP_EXIT=1

	provider_resolve "13335" 3>/dev/null
	assertNotEquals "HTTP failure returns non-zero" 0 $?
}

# ── V4/V6 Separation Accuracy ──────────────────────────

test_v4_v6_separation_no_mixing() {
	_MOCK_HTTP_RESPONSE="$_BGPVIEW_RESPONSE_MIXED"

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

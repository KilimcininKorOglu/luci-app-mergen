#!/bin/sh
# Test suite for mergen/files/etc/mergen/providers/routeviews.sh
# Uses shunit2 framework — ash/busybox compatible
# Tests use mock dump files instead of real RouteViews data

MERGEN_TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
MERGEN_ROOT="$(cd "$MERGEN_TEST_DIR/.." && pwd)"

# ── Test Temp Directory ─────────────────────────────────

_TEST_TMPDIR=""

# ── Mock Dependencies ───────────────────────────────────

MERGEN_CONF="mergen"
MERGEN_UCI_RESULT=""
MERGEN_TMP=""
MERGEN_PROVIDER_URL="https://routeviews.org/bgpdata/"
MERGEN_PROVIDER_TIMEOUT="30"
MERGEN_PROVIDER_DUMP_PATH=""

mergen_log() { :; }

mergen_uci_get() {
	MERGEN_UCI_RESULT="$3"
}

# ── Source provider under test ──────────────────────────

. "${MERGEN_ROOT}/files/etc/mergen/providers/routeviews.sh"

# Override download to prevent real HTTP calls
_routeviews_download_and_parse() {
	return 1
}

_routeviews_http_check() {
	return 1
}

# ── Setup/Teardown ──────────────────────────────────────

setUp() {
	_TEST_TMPDIR="$(mktemp -d)"
	MERGEN_TMP="$_TEST_TMPDIR"
	MERGEN_PROVIDER_DUMP_PATH="${_TEST_TMPDIR}/rib.txt"
}

tearDown() {
	if [ -n "$_TEST_TMPDIR" ] && [ -d "$_TEST_TMPDIR" ]; then
		rm -rf "$_TEST_TMPDIR"
	fi
}

# ── Mock Dump Data ──────────────────────────────────────

_create_mock_dump() {
	cat > "$MERGEN_PROVIDER_DUMP_PATH" <<'DUMPEOF'
13335|104.16.0.0/12
13335|172.64.0.0/13
13335|2606:4700::/32
15169|8.8.8.0/24
15169|142.250.0.0/15
15169|2607:f8b0::/32
32934|31.13.24.0/21
32934|157.240.0.0/16
32934|2a03:2880::/32
DUMPEOF
}

# ── Provider Name Tests ─────────────────────────────────

test_provider_name() {
	local name
	name="$(provider_name)"
	assertEquals "Provider name" "RouteViews" "$name"
}

# ── Provider Test (Availability) ────────────────────────

test_provider_test_with_dump() {
	_create_mock_dump

	provider_test
	assertEquals "Test succeeds with local dump" 0 $?
}

test_provider_test_no_dump() {
	rm -f "$MERGEN_PROVIDER_DUMP_PATH"

	provider_test
	assertNotEquals "Test fails without dump and unreachable server" 0 $?
}

# ── IPv4 Resolution ────────────────────────────────────

test_resolve_ipv4_cloudflare() {
	_create_mock_dump

	local v4_output
	v4_output="$(provider_resolve "13335" 3>/dev/null)"

	echo "$v4_output" | grep -q "104.16.0.0/12"
	assertEquals "Cloudflare v4 prefix 1" 0 $?

	echo "$v4_output" | grep -q "172.64.0.0/13"
	assertEquals "Cloudflare v4 prefix 2" 0 $?
}

test_resolve_ipv4_google() {
	_create_mock_dump

	local v4_output
	v4_output="$(provider_resolve "15169" 3>/dev/null)"

	echo "$v4_output" | grep -q "8.8.8.0/24"
	assertEquals "Google DNS prefix" 0 $?

	echo "$v4_output" | grep -q "142.250.0.0/15"
	assertEquals "Google services prefix" 0 $?
}

# ── IPv6 Resolution ────────────────────────────────────

test_resolve_ipv6() {
	_create_mock_dump

	local v6_output
	provider_resolve "13335" 3>"${_TEST_TMPDIR}/v6.txt" >/dev/null
	v6_output="$(cat "${_TEST_TMPDIR}/v6.txt" 2>/dev/null)"

	echo "$v6_output" | grep -q "2606:4700::/32"
	assertEquals "Cloudflare v6 prefix" 0 $?
}

# ── V4/V6 Separation ───────────────────────────────────

test_v4_v6_separation() {
	_create_mock_dump

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

# ── ASN Isolation ──────────────────────────────────────

test_resolve_asn_isolation() {
	_create_mock_dump

	local v4_output
	v4_output="$(provider_resolve "32934" 3>/dev/null)"

	echo "$v4_output" | grep -q "157.240.0.0/16"
	assertEquals "Facebook prefix present" 0 $?

	echo "$v4_output" | grep -q "104.16.0.0"
	assertNotEquals "No Cloudflare prefix in Facebook result" 0 $?

	echo "$v4_output" | grep -q "8.8.8.0"
	assertNotEquals "No Google prefix in Facebook result" 0 $?
}

# ── Empty Result ────────────────────────────────────────

test_resolve_unknown_asn() {
	_create_mock_dump

	local v4_output
	v4_output="$(provider_resolve "99999" 3>/dev/null)"
	assertEquals "Unknown ASN returns success" 0 $?

	local line_count
	line_count="$(echo "$v4_output" | grep -c '.' 2>/dev/null)"
	assertEquals "No output for unknown ASN" "0" "$line_count"
}

# ── No Dump File ───────────────────────────────────────

test_resolve_no_dump_fails() {
	rm -f "$MERGEN_PROVIDER_DUMP_PATH"

	provider_resolve "13335" 3>/dev/null
	assertNotEquals "Resolve fails without dump" 0 $?
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

#!/bin/sh
# Test suite for mergen/files/etc/mergen/providers/maxmind.sh
# Uses shunit2 framework — ash/busybox compatible
# Tests use mock MMDB reader and prefix map instead of real MMDB files

MERGEN_TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
MERGEN_ROOT="$(cd "$MERGEN_TEST_DIR/.." && pwd)"

# ── Test Temp Directory ─────────────────────────────────

_TEST_TMPDIR=""
_MOCK_HAS_READER=1
_MOCK_MMDBLOOKUP_OUTPUT=""

# ── Mock Dependencies ───────────────────────────────────

MERGEN_CONF="mergen"
MERGEN_UCI_RESULT=""
MERGEN_TMP=""
MERGEN_PROVIDER_DB_PATH=""
MERGEN_PROVIDER_PREFIX_MAP=""
MERGEN_PROVIDER_LICENSE_KEY=""

mergen_log() { :; }

mergen_uci_get() {
	MERGEN_UCI_RESULT="$3"
}

# ── Source provider under test ──────────────────────────

. "${MERGEN_ROOT}/files/etc/mergen/providers/maxmind.sh"

# Override _maxmind_has_reader to use mock
_maxmind_has_reader() {
	return "$_MOCK_HAS_READER"
}

# Override _maxmind_build_prefix_map to avoid real MMDB parsing
_maxmind_build_prefix_map() {
	return 1
}

# ── Setup/Teardown ──────────────────────────────────────

setUp() {
	_TEST_TMPDIR="$(mktemp -d)"
	_MOCK_HAS_READER=0
	MERGEN_TMP="$_TEST_TMPDIR"
	MERGEN_PROVIDER_DB_PATH="${_TEST_TMPDIR}/GeoLite2-ASN.mmdb"
	MERGEN_PROVIDER_PREFIX_MAP="${_TEST_TMPDIR}/prefix_map.txt"
	MERGEN_PROVIDER_LICENSE_KEY=""

	# Create a dummy MMDB file (just needs to exist for tests)
	echo "MMDB_DUMMY" > "$MERGEN_PROVIDER_DB_PATH"
}

tearDown() {
	if [ -n "$_TEST_TMPDIR" ] && [ -d "$_TEST_TMPDIR" ]; then
		rm -rf "$_TEST_TMPDIR"
	fi
}

# ── Mock Prefix Map ────────────────────────────────────

_create_mock_prefix_map() {
	cat > "$MERGEN_PROVIDER_PREFIX_MAP" <<'PREFIXMAP'
13335|104.16.0.0/12
13335|172.64.0.0/13
13335|2606:4700::/32
13335|2803:f800::/32
15169|8.8.8.0/24
15169|142.250.0.0/15
15169|2607:f8b0::/32
99999|10.0.0.0/8
PREFIXMAP
}

# ── Provider Name Tests ─────────────────────────────────

test_provider_name() {
	local name
	name="$(provider_name)"
	assertEquals "Provider name" "MaxMind GeoLite2" "$name"
}

# ── Provider Test (Availability) ────────────────────────

test_provider_test_success() {
	_MOCK_HAS_READER=0

	provider_test
	assertEquals "Test succeeds with MMDB and reader" 0 $?
}

test_provider_test_no_mmdb() {
	rm -f "$MERGEN_PROVIDER_DB_PATH"

	provider_test
	assertNotEquals "Test fails without MMDB file" 0 $?
}

test_provider_test_no_reader() {
	_MOCK_HAS_READER=1

	provider_test
	assertNotEquals "Test fails without MMDB reader" 0 $?
}

# ── IPv4 Resolution ────────────────────────────────────

test_resolve_ipv4_prefixes() {
	_create_mock_prefix_map

	local v4_output
	v4_output="$(provider_resolve "13335" 3>"${_TEST_TMPDIR}/v6.txt")"

	echo "$v4_output" | grep -q "104.16.0.0/12"
	assertEquals "Contains first v4 prefix" 0 $?

	echo "$v4_output" | grep -q "172.64.0.0/13"
	assertEquals "Contains second v4 prefix" 0 $?
}

# ── IPv6 Resolution ────────────────────────────────────

test_resolve_ipv6_prefixes() {
	_create_mock_prefix_map

	local v6_output
	provider_resolve "13335" 3>"${_TEST_TMPDIR}/v6.txt" >/dev/null
	v6_output="$(cat "${_TEST_TMPDIR}/v6.txt" 2>/dev/null)"

	echo "$v6_output" | grep -q "2606:4700::/32"
	assertEquals "Contains v6 prefix 1" 0 $?

	echo "$v6_output" | grep -q "2803:f800::/32"
	assertEquals "Contains v6 prefix 2" 0 $?
}

# ── Mixed V4/V6 Separation ─────────────────────────────

test_resolve_v4_v6_separation() {
	_create_mock_prefix_map

	local v4_output v6_output
	v4_output="$(provider_resolve "13335" 3>"${_TEST_TMPDIR}/v6.txt")"
	v6_output="$(cat "${_TEST_TMPDIR}/v6.txt" 2>/dev/null)"

	# V4 should not contain IPv6
	local v6_in_v4
	v6_in_v4="$(echo "$v4_output" | grep -c ':' 2>/dev/null)"
	assertEquals "No IPv6 in v4 output" "0" "$v6_in_v4"

	# V6 should not contain IPv4
	local v4_in_v6
	v4_in_v6="$(echo "$v6_output" | grep -cv ':' 2>/dev/null)"
	assertEquals "No IPv4 in v6 output" "0" "$v4_in_v6"
}

# ── Different ASN Resolution ───────────────────────────

test_resolve_different_asn() {
	_create_mock_prefix_map

	local v4_output
	v4_output="$(provider_resolve "15169" 3>/dev/null)"

	echo "$v4_output" | grep -q "8.8.8.0/24"
	assertEquals "Google DNS prefix" 0 $?

	echo "$v4_output" | grep -q "142.250.0.0/15"
	assertEquals "Google services prefix" 0 $?

	# Should NOT contain Cloudflare prefixes
	echo "$v4_output" | grep -q "104.16.0.0"
	assertNotEquals "No Cloudflare prefix in Google result" 0 $?
}

# ── Empty Result ────────────────────────────────────────

test_resolve_unknown_asn() {
	_create_mock_prefix_map

	local v4_output
	v4_output="$(provider_resolve "12345" 3>/dev/null)"
	assertEquals "Unknown ASN returns success" 0 $?

	local line_count
	line_count="$(echo "$v4_output" | grep -c '.' 2>/dev/null)"
	assertEquals "No output for unknown ASN" "0" "$line_count"
}

# ── No MMDB File ───────────────────────────────────────

test_resolve_no_mmdb() {
	rm -f "$MERGEN_PROVIDER_DB_PATH"

	provider_resolve "13335" 3>/dev/null
	assertNotEquals "Resolve fails without MMDB" 0 $?
}

# ── No Prefix Map (and build fails) ───────────────────

test_resolve_no_prefix_map_build_fails() {
	rm -f "$MERGEN_PROVIDER_PREFIX_MAP"
	# _maxmind_build_prefix_map is overridden to return 1

	provider_resolve "13335" 3>/dev/null
	assertNotEquals "Resolve fails when map build fails" 0 $?
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

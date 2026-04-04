#!/bin/sh
# Test suite for mergen/files/usr/lib/mergen/resolver.sh
# Uses shunit2 framework — ash/busybox compatible

MERGEN_TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
MERGEN_ROOT="$(cd "$MERGEN_TEST_DIR/.." && pwd)"

# ── Test Temp Directory ─────────────────────────────────

_TEST_TMPDIR=""
_ORIG_PROVIDERS_DIR=""

# ── Mock UCI System ─────────────────────────────────────

_MOCK_UCI_STORE=""
_MOCK_CONFIG_LOADED=""
_MOCK_FOREACH_SECTIONS=""

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

# ── Source modules under test ───────────────────────────

. "${MERGEN_ROOT}/files/usr/lib/mergen/core.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/utils.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/resolver.sh"

# ── Helper: Create mock provider ────────────────────────

# Create a mock provider plugin file that succeeds
# Usage: _create_mock_provider <name> <v4_prefixes> [v6_prefixes]
_create_mock_provider() {
	local name="$1"
	local v4_data="$2"
	local v6_data="$3"

	cat > "${_TEST_TMPDIR}/providers/${name}.sh" <<PROVEOF
#!/bin/sh
provider_name() { echo "${name}-mock"; }
provider_test() { return 0; }
provider_resolve() {
	local asn="\$1"
	echo "${v4_data}"
	if [ -n "${v6_data}" ]; then
		echo "${v6_data}" >&3
	fi
	return 0
}
PROVEOF
	chmod +x "${_TEST_TMPDIR}/providers/${name}.sh"
}

# Create a mock provider that fails
_create_failing_provider() {
	local name="$1"

	cat > "${_TEST_TMPDIR}/providers/${name}.sh" <<PROVEOF
#!/bin/sh
provider_name() { echo "${name}-mock"; }
provider_test() { return 1; }
provider_resolve() { return 1; }
PROVEOF
	chmod +x "${_TEST_TMPDIR}/providers/${name}.sh"
}

# Create a mock provider whose test fails but resolve succeeds
_create_test_fail_provider() {
	local name="$1"
	local v4_data="$2"

	cat > "${_TEST_TMPDIR}/providers/${name}.sh" <<PROVEOF
#!/bin/sh
provider_name() { echo "${name}-mock"; }
provider_test() { return 1; }
provider_resolve() {
	echo "${v4_data}"
	return 0
}
PROVEOF
	chmod +x "${_TEST_TMPDIR}/providers/${name}.sh"
}

# ── Setup/Teardown ──────────────────────────────────────

setUp() {
	_MOCK_UCI_STORE=""
	_MOCK_FOREACH_SECTIONS=""
	MERGEN_UCI_RESULT=""
	MERGEN_RESOLVE_RESULT_V4=""
	MERGEN_RESOLVE_RESULT_V6=""
	MERGEN_RESOLVE_PROVIDER=""
	MERGEN_RESOLVE_COUNT_V4=0
	MERGEN_RESOLVE_COUNT_V6=0

	# Create temp directory structure
	_TEST_TMPDIR="$(mktemp -d)"
	mkdir -p "${_TEST_TMPDIR}/providers"
	mkdir -p "${_TEST_TMPDIR}/cache"

	# Override module globals to use test directories
	MERGEN_PROVIDERS_DIR="${_TEST_TMPDIR}/providers"
	MERGEN_CACHE_DIR="${_TEST_TMPDIR}/cache"

	# Set up default UCI config
	_mock_uci_set "mergen.global.enabled=1"
	_mock_uci_set "mergen.global.log_level=info"
	_mock_uci_set "mergen.global.cache_dir=${_TEST_TMPDIR}/cache"
}

tearDown() {
	# Clean up temp directory
	if [ -n "$_TEST_TMPDIR" ] && [ -d "$_TEST_TMPDIR" ]; then
		rm -rf "$_TEST_TMPDIR"
	fi
}

# ── Provider Exists Tests ───────────────────────────────

test_provider_exists_true() {
	_create_mock_provider "ripe" "1.2.3.0/24"

	mergen_provider_exists "ripe"
	assertEquals "Existing provider should return 0" 0 $?
}

test_provider_exists_false() {
	mergen_provider_exists "nonexistent"
	assertNotEquals "Missing provider should return non-zero" 0 $?
}

# ── Provider Call Tests ─────────────────────────────────

test_provider_call_success() {
	_create_mock_provider "testprov" "10.0.0.0/8"

	local result
	result="$(_mergen_provider_call "testprov" "provider_name")"
	assertEquals "Provider name function" "testprov-mock" "$result"
}

test_provider_call_missing_plugin() {
	_mergen_provider_call "nonexistent" "provider_name" 2>/dev/null
	assertNotEquals "Missing plugin should fail" 0 $?
}

test_provider_call_missing_function() {
	# Create provider without provider_test
	cat > "${_TEST_TMPDIR}/providers/partial.sh" <<'EOF'
#!/bin/sh
provider_name() { echo "partial"; }
EOF
	chmod +x "${_TEST_TMPDIR}/providers/partial.sh"

	_mergen_provider_call "partial" "provider_resolve" "13335" 2>/dev/null
	assertNotEquals "Missing function should fail" 0 $?
}

# ── Single Provider Resolution Tests ────────────────────

test_try_provider_v4_only() {
	_create_mock_provider "ripe" "104.16.0.0/12
172.64.0.0/13"
	_mock_uci_set "mergen.ripe.enabled=1"
	_mock_uci_set "mergen.ripe.priority=10"

	# Set provider config for mergen_get_provider
	_MOCK_CONFIG_LOADED="mergen"
	_mock_uci_set "mergen.ripe.api_url=https://stat.ripe.net"
	_mock_uci_set "mergen.ripe.timeout=30"

	_mergen_try_provider "ripe" "13335"
	assertEquals "Provider should succeed" 0 $?
	assertNotNull "V4 result should not be empty" "$MERGEN_RESOLVE_RESULT_V4"
	assertEquals "Provider name stored" "ripe" "$MERGEN_RESOLVE_PROVIDER"
	assertEquals "V4 count" "2" "$MERGEN_RESOLVE_COUNT_V4"
}

test_try_provider_v4_and_v6() {
	_create_mock_provider "ripe" "104.16.0.0/12" "2606:4700::/32"
	_mock_uci_set "mergen.ripe.enabled=1"
	_mock_uci_set "mergen.ripe.priority=10"
	_MOCK_CONFIG_LOADED="mergen"

	_mergen_try_provider "ripe" "13335"
	assertEquals "Provider should succeed" 0 $?
	assertEquals "V4 count" "1" "$MERGEN_RESOLVE_COUNT_V4"
	assertEquals "V6 count" "1" "$MERGEN_RESOLVE_COUNT_V6"
}

test_try_provider_failure() {
	_create_failing_provider "badprov"
	_mock_uci_set "mergen.badprov.enabled=1"
	_mock_uci_set "mergen.badprov.priority=10"
	_MOCK_CONFIG_LOADED="mergen"

	_mergen_try_provider "badprov" "99999"
	assertNotEquals "Failing provider should return non-zero" 0 $?
}

# ── ASN Resolution with Provider Chain ──────────────────

test_resolve_asn_single_provider() {
	_create_mock_provider "ripe" "192.0.2.0/24"
	_MOCK_FOREACH_SECTIONS="ripe"
	_mock_uci_set "mergen.ripe.enabled=1"
	_mock_uci_set "mergen.ripe.priority=10"
	_MOCK_CONFIG_LOADED="mergen"

	mergen_resolve_asn "13335"
	assertEquals "Resolution should succeed" 0 $?
	assertEquals "Provider stored" "ripe" "$MERGEN_RESOLVE_PROVIDER"
	assertEquals "V4 count" "1" "$MERGEN_RESOLVE_COUNT_V4"
}

test_resolve_asn_strips_as_prefix() {
	_create_mock_provider "ripe" "192.0.2.0/24"
	_MOCK_FOREACH_SECTIONS="ripe"
	_mock_uci_set "mergen.ripe.enabled=1"
	_mock_uci_set "mergen.ripe.priority=10"
	_MOCK_CONFIG_LOADED="mergen"

	mergen_resolve_asn "AS13335"
	assertEquals "AS prefix strip should work" 0 $?
	assertEquals "V4 count" "1" "$MERGEN_RESOLVE_COUNT_V4"
}

test_resolve_asn_lowercase_as_prefix() {
	_create_mock_provider "ripe" "192.0.2.0/24"
	_MOCK_FOREACH_SECTIONS="ripe"
	_mock_uci_set "mergen.ripe.enabled=1"
	_mock_uci_set "mergen.ripe.priority=10"
	_MOCK_CONFIG_LOADED="mergen"

	mergen_resolve_asn "as13335"
	assertEquals "Lowercase as prefix strip should work" 0 $?
}

test_resolve_asn_fallback_to_second_provider() {
	_create_failing_provider "badprov"
	_create_mock_provider "goodprov" "10.0.0.0/8"

	_MOCK_FOREACH_SECTIONS="badprov goodprov"
	_mock_uci_set "mergen.badprov.enabled=1"
	_mock_uci_set "mergen.badprov.priority=10"
	_mock_uci_set "mergen.goodprov.enabled=1"
	_mock_uci_set "mergen.goodprov.priority=20"
	_MOCK_CONFIG_LOADED="mergen"

	mergen_resolve_asn "64496"
	assertEquals "Fallback resolution should succeed" 0 $?
	assertEquals "Second provider used" "goodprov" "$MERGEN_RESOLVE_PROVIDER"
}

test_resolve_asn_all_providers_fail() {
	_create_failing_provider "bad1"
	_create_failing_provider "bad2"

	_MOCK_FOREACH_SECTIONS="bad1 bad2"
	_mock_uci_set "mergen.bad1.enabled=1"
	_mock_uci_set "mergen.bad1.priority=10"
	_mock_uci_set "mergen.bad2.enabled=1"
	_mock_uci_set "mergen.bad2.priority=20"
	_MOCK_CONFIG_LOADED="mergen"

	mergen_resolve_asn "99999"
	assertNotEquals "All failing should return non-zero" 0 $?
}

test_resolve_asn_force_provider() {
	_create_mock_provider "forced" "198.51.100.0/24"
	_mock_uci_set "mergen.forced.enabled=1"
	_mock_uci_set "mergen.forced.priority=99"
	_MOCK_CONFIG_LOADED="mergen"

	mergen_resolve_asn "64496" "forced"
	assertEquals "Forced provider should succeed" 0 $?
	assertEquals "Forced provider used" "forced" "$MERGEN_RESOLVE_PROVIDER"
}

test_resolve_asn_force_missing_provider() {
	mergen_resolve_asn "64496" "nonexistent"
	assertNotEquals "Forcing missing provider should fail" 0 $?
}

# ── Provider Testing ────────────────────────────────────

test_provider_test_success() {
	_create_mock_provider "ripe" "1.2.3.0/24"

	mergen_provider_test "ripe"
	assertEquals "Reachable provider test" 0 $?
}

test_provider_test_failure() {
	_create_failing_provider "badprov"

	mergen_provider_test "badprov"
	assertNotEquals "Unreachable provider test" 0 $?
}

test_provider_test_missing() {
	mergen_provider_test "nonexistent"
	assertNotEquals "Missing provider test" 0 $?
}

# ── Provider Test All ───────────────────────────────────

test_provider_test_all_output() {
	_create_mock_provider "ripe" "1.2.3.0/24"
	_create_failing_provider "badprov"
	_MOCK_FOREACH_SECTIONS="ripe badprov"
	_mock_uci_set "mergen.ripe.enabled=1"
	_mock_uci_set "mergen.ripe.priority=10"
	_mock_uci_set "mergen.badprov.enabled=1"
	_mock_uci_set "mergen.badprov.priority=20"
	_MOCK_CONFIG_LOADED="mergen"

	local output
	output="$(mergen_provider_test_all)"

	echo "$output" | grep -q "ripe.*OK"
	assertEquals "Ripe should show OK" 0 $?

	echo "$output" | grep -q "badprov.*FAIL"
	assertEquals "Badprov should show FAIL" 0 $?
}

test_provider_test_all_missing_plugin() {
	_MOCK_FOREACH_SECTIONS="nonexistent"
	_mock_uci_set "mergen.nonexistent.enabled=1"
	_mock_uci_set "mergen.nonexistent.priority=10"
	_MOCK_CONFIG_LOADED="mergen"

	local output
	output="$(mergen_provider_test_all)"

	echo "$output" | grep -q "nonexistent.*MISSING"
	assertEquals "Missing provider should show MISSING" 0 $?
}

# ── Resolver Init Tests ─────────────────────────────────

test_resolver_init_creates_cache_dir() {
	local new_cache="${_TEST_TMPDIR}/newcache"
	_mock_uci_set "mergen.global.cache_dir=${new_cache}"

	mergen_resolver_init
	assertTrue "Cache directory should be created" "[ -d '${new_cache}' ]"
}

# ── Edge Cases ──────────────────────────────────────────

test_resolve_empty_result() {
	# Provider that returns empty output (success but no prefixes)
	cat > "${_TEST_TMPDIR}/providers/empty.sh" <<'EOF'
#!/bin/sh
provider_name() { echo "empty-mock"; }
provider_test() { return 0; }
provider_resolve() { return 0; }
EOF
	chmod +x "${_TEST_TMPDIR}/providers/empty.sh"

	_MOCK_FOREACH_SECTIONS="empty"
	_mock_uci_set "mergen.empty.enabled=1"
	_mock_uci_set "mergen.empty.priority=10"
	_MOCK_CONFIG_LOADED="mergen"

	mergen_resolve_asn "64496"
	assertEquals "Empty result should still succeed" 0 $?
	assertEquals "V4 count should be 0" "0" "$MERGEN_RESOLVE_COUNT_V4"
	assertEquals "V6 count should be 0" "0" "$MERGEN_RESOLVE_COUNT_V6"
}

test_provider_stops_after_first_success() {
	_create_mock_provider "first" "10.0.0.0/8"
	_create_mock_provider "second" "172.16.0.0/12"

	_MOCK_FOREACH_SECTIONS="first second"
	_mock_uci_set "mergen.first.enabled=1"
	_mock_uci_set "mergen.first.priority=10"
	_mock_uci_set "mergen.second.enabled=1"
	_mock_uci_set "mergen.second.priority=20"
	_MOCK_CONFIG_LOADED="mergen"

	mergen_resolve_asn "64496"
	assertEquals "Should use first provider" "first" "$MERGEN_RESOLVE_PROVIDER"
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

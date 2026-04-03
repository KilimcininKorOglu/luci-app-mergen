#!/bin/sh
# Test suite for Phase 3 provider resolution and resolve command (T033)
# Tests: individual provider mocks, IPv6 prefix parsing, force provider,
#        cache integration, and the CLI resolve command
# Uses shunit2 framework — ash/busybox compatible

MERGEN_TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
MERGEN_ROOT="$(cd "$MERGEN_TEST_DIR/.." && pwd)"

# ── Test Temp Directory ─────────────────────────────────

_TEST_TMPDIR=""

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

# Mock logger and flock
logger() { :; }
flock() { return 0; }

# ── Source modules under test ───────────────────────────

. "${MERGEN_ROOT}/files/usr/lib/mergen/core.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/utils.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/engine.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/resolver.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/route.sh"

# Source CLI for cmd_resolve tests (set lib dir and sourced flag first)
MERGEN_LIB_DIR="${MERGEN_ROOT}/files/usr/lib/mergen"
MERGEN_SOURCED=1
. "${MERGEN_ROOT}/files/usr/bin/mergen"

# Override lock functions for testing
mergen_lock_acquire() { return 0; }
mergen_lock_release() { return 0; }

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

# ── Mock Provider Helpers ───────────────────────────────

# Create a mock provider with v4 and v6 data
_create_mock_provider() {
	local name="$1"
	local v4_data="$2"
	local v6_data="${3:-}"

	cat > "${_TEST_TMPDIR}/providers/${name}.sh" <<PROVEOF
#!/bin/sh
provider_name() { echo "${name}"; }
provider_test() { return 0; }
provider_resolve() {
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
provider_name() { echo "${name}"; }
provider_test() { return 1; }
provider_resolve() { return 1; }
PROVEOF
	chmod +x "${_TEST_TMPDIR}/providers/${name}.sh"
}

# Pre-populate fresh cache
_create_fresh_cache() {
	local asn="$1"
	local v4_data="$2"
	local v6_data="${3:-}"

	echo "$v4_data" > "${_TEST_TMPDIR}/cache/AS${asn}.v4.txt"
	if [ -n "$v6_data" ]; then
		echo "$v6_data" > "${_TEST_TMPDIR}/cache/AS${asn}.v6.txt"
	fi
	cat > "${_TEST_TMPDIR}/cache/AS${asn}.meta" <<EOF
timestamp=$(date +%s)
provider=cache-provider
ttl=86400
EOF
}

# Pre-populate stale cache
_create_stale_cache() {
	local asn="$1"
	local v4_data="$2"

	echo "$v4_data" > "${_TEST_TMPDIR}/cache/AS${asn}.v4.txt"
	cat > "${_TEST_TMPDIR}/cache/AS${asn}.meta" <<EOF
timestamp=1000000
provider=stale-provider
ttl=86400
EOF
}

# Register a provider in UCI
_register_provider() {
	local name="$1" priority="${2:-10}"
	_MOCK_FOREACH_SECTIONS="${_MOCK_FOREACH_SECTIONS} ${name}"
	_mock_uci_set "mergen.${name}.enabled=1"
	_mock_uci_set "mergen.${name}.priority=${priority}"
}

# ── Setup/Teardown ──────────────────────────────────────

setUp() {
	_MOCK_UCI_STORE=""
	_MOCK_FOREACH_SECTIONS=""
	_MOCK_ADD_COUNTER=0
	MERGEN_UCI_RESULT=""
	MERGEN_RESOLVE_RESULT_V4=""
	MERGEN_RESOLVE_RESULT_V6=""
	MERGEN_RESOLVE_PROVIDER=""
	MERGEN_RESOLVE_COUNT_V4=0
	MERGEN_RESOLVE_COUNT_V6=0
	MERGEN_HEALTH_DIR=""

	# Create temp directory structure
	_TEST_TMPDIR="$(mktemp -d)"
	mkdir -p "${_TEST_TMPDIR}/providers"
	mkdir -p "${_TEST_TMPDIR}/cache"
	mkdir -p "${_TEST_TMPDIR}/health"

	# Override module globals
	MERGEN_PROVIDERS_DIR="${_TEST_TMPDIR}/providers"
	MERGEN_CACHE_DIR="${_TEST_TMPDIR}/cache"
	MERGEN_HEALTH_DIR="${_TEST_TMPDIR}/health"
	MERGEN_TMP="$_TEST_TMPDIR"

	# Set up default UCI config
	_mock_uci_set "mergen.global.enabled=1"
	_mock_uci_set "mergen.global.log_level=info"
	_mock_uci_set "mergen.global.cache_dir=${_TEST_TMPDIR}/cache"
	_mock_uci_set "mergen.global.update_interval=86400"
	_mock_uci_set "mergen.global.fallback_strategy=sequential"
	_mock_uci_set "mergen.global.set_type=nftables"
	_mock_uci_set "mergen.global.ipv6_enabled=0"
	_MOCK_CONFIG_LOADED="mergen"
}

tearDown() {
	if [ -n "$_TEST_TMPDIR" ] && [ -d "$_TEST_TMPDIR" ]; then
		rm -rf "$_TEST_TMPDIR"
	fi
}

# ══════════════════════════════════════════════════════════
# Individual Provider Mock Tests
# ══════════════════════════════════════════════════════════
# Each test simulates a provider's response pattern

test_ripe_provider_mock() {
	_create_mock_provider "ripe" "104.16.0.0/13
104.24.0.0/14
172.64.0.0/13"
	_register_provider "ripe" 10

	mergen_resolve_asn "13335"
	assertEquals "RIPE resolve succeeds" 0 $?
	assertEquals "Provider is ripe" "ripe" "$MERGEN_RESOLVE_PROVIDER"
	assertEquals "3 IPv4 prefixes" "3" "$MERGEN_RESOLVE_COUNT_V4"
}

test_bgptools_provider_mock() {
	_create_mock_provider "bgptools" "8.8.8.0/24
8.8.4.0/24"
	_register_provider "bgptools" 10

	mergen_resolve_asn "15169"
	assertEquals "bgp.tools resolve succeeds" 0 $?
	assertEquals "Provider is bgptools" "bgptools" "$MERGEN_RESOLVE_PROVIDER"
	assertEquals "2 IPv4 prefixes" "2" "$MERGEN_RESOLVE_COUNT_V4"
}

test_bgpview_provider_mock() {
	_create_mock_provider "bgpview" "185.60.216.0/22
157.240.0.0/16
31.13.24.0/21"
	_register_provider "bgpview" 10

	mergen_resolve_asn "32934"
	assertEquals "BGPView resolve succeeds" 0 $?
	assertEquals "Provider is bgpview" "bgpview" "$MERGEN_RESOLVE_PROVIDER"
	assertEquals "3 IPv4 prefixes" "3" "$MERGEN_RESOLVE_COUNT_V4"
}

test_maxmind_provider_mock() {
	_create_mock_provider "maxmind" "199.232.0.0/16
151.101.0.0/16"
	_register_provider "maxmind" 10

	mergen_resolve_asn "54113"
	assertEquals "MaxMind resolve succeeds" 0 $?
	assertEquals "Provider is maxmind" "maxmind" "$MERGEN_RESOLVE_PROVIDER"
	assertEquals "2 IPv4 prefixes" "2" "$MERGEN_RESOLVE_COUNT_V4"
}

test_routeviews_provider_mock() {
	_create_mock_provider "routeviews" "1.1.1.0/24
1.0.0.0/24"
	_register_provider "routeviews" 10

	mergen_resolve_asn "13335"
	assertEquals "RouteViews resolve succeeds" 0 $?
	assertEquals "Provider is routeviews" "routeviews" "$MERGEN_RESOLVE_PROVIDER"
	assertEquals "2 IPv4 prefixes" "2" "$MERGEN_RESOLVE_COUNT_V4"
}

test_irr_provider_mock() {
	_create_mock_provider "irr" "203.0.113.0/24
198.51.100.0/24"
	_register_provider "irr" 10

	mergen_resolve_asn "64496"
	assertEquals "IRR resolve succeeds" 0 $?
	assertEquals "Provider is irr" "irr" "$MERGEN_RESOLVE_PROVIDER"
	assertEquals "2 IPv4 prefixes" "2" "$MERGEN_RESOLVE_COUNT_V4"
}

# ══════════════════════════════════════════════════════════
# IPv6 Prefix Resolution Tests
# ══════════════════════════════════════════════════════════

test_ipv6_prefix_resolution() {
	_create_mock_provider "ripe" "104.16.0.0/13" "2606:4700::/32
2803:f800::/32"
	_register_provider "ripe" 10

	mergen_resolve_asn "13335"
	assertEquals "Resolve succeeds with IPv6" 0 $?
	assertEquals "1 IPv4 prefix" "1" "$MERGEN_RESOLVE_COUNT_V4"
	assertEquals "2 IPv6 prefixes" "2" "$MERGEN_RESOLVE_COUNT_V6"

	echo "$MERGEN_RESOLVE_RESULT_V6" | grep -q "2606:4700::/32"
	assertEquals "Contains first v6 prefix" 0 $?
}

test_ipv6_only_resolution() {
	# Provider returns only IPv6 (no IPv4)
	cat > "${_TEST_TMPDIR}/providers/v6only.sh" <<'PROVEOF'
#!/bin/sh
provider_name() { echo "v6only"; }
provider_test() { return 0; }
provider_resolve() {
	echo "2001:db8::/32
2001:db8:1::/48" >&3
	return 0
}
PROVEOF
	chmod +x "${_TEST_TMPDIR}/providers/v6only.sh"
	_register_provider "v6only" 10

	mergen_resolve_asn "64496"
	assertEquals "IPv6-only resolve succeeds" 0 $?
	assertEquals "0 IPv4 prefixes" "0" "$MERGEN_RESOLVE_COUNT_V4"
	assertEquals "2 IPv6 prefixes" "2" "$MERGEN_RESOLVE_COUNT_V6"
}

test_ipv6_cache_roundtrip() {
	_create_mock_provider "ripe" "10.0.0.0/8" "2001:db8::/32"
	_register_provider "ripe" 10

	# First resolve — will cache
	mergen_resolve_asn "64496"
	assertEquals "First resolve succeeds" 0 $?
	assertEquals "1 IPv6 from provider" "1" "$MERGEN_RESOLVE_COUNT_V6"

	# Reset state, second resolve should hit cache
	MERGEN_RESOLVE_RESULT_V4=""
	MERGEN_RESOLVE_RESULT_V6=""
	MERGEN_RESOLVE_PROVIDER=""
	MERGEN_RESOLVE_COUNT_V4=0
	MERGEN_RESOLVE_COUNT_V6=0

	mergen_resolve_asn "64496"
	assertEquals "Cache hit succeeds" 0 $?
	assertEquals "1 IPv6 from cache" "1" "$MERGEN_RESOLVE_COUNT_V6"
	echo "$MERGEN_RESOLVE_RESULT_V6" | grep -q "2001:db8::/32"
	assertEquals "Cached v6 prefix correct" 0 $?
}

# ══════════════════════════════════════════════════════════
# Force Provider Tests
# ══════════════════════════════════════════════════════════

test_force_provider_bypasses_cache() {
	# Pre-populate cache
	_create_fresh_cache "13335" "10.0.0.0/8"

	# Create provider with different data
	_create_mock_provider "ripe" "104.16.0.0/13"
	_register_provider "ripe" 10

	# Without force, should use cache
	mergen_resolve_asn "13335"
	assertEquals "Cache hit" 0 $?
	assertEquals "Cache provider" "cache-provider" "$MERGEN_RESOLVE_PROVIDER"

	# With force_provider, should use provider directly
	mergen_resolve_asn "13335" "ripe"
	assertEquals "Force provider succeeds" 0 $?
	assertEquals "Provider is ripe" "ripe" "$MERGEN_RESOLVE_PROVIDER"
}

test_force_nonexistent_provider() {
	mergen_resolve_asn "13335" "nonexistent"
	assertNotEquals "Nonexistent provider fails" 0 $?
}

test_force_provider_failing() {
	_create_failing_provider "badprov"

	mergen_resolve_asn "13335" "badprov"
	assertNotEquals "Failing forced provider returns error" 0 $?
}

# ══════════════════════════════════════════════════════════
# Fallback: First Provider Error -> Second Provider Success
# ══════════════════════════════════════════════════════════

test_fallback_first_fail_second_success() {
	_create_failing_provider "prov1"
	_create_mock_provider "prov2" "198.51.100.0/24"
	_register_provider "prov1" 10
	_register_provider "prov2" 20

	mergen_resolve_asn "64496"
	assertEquals "Fallback succeeds" 0 $?
	assertEquals "Second provider used" "prov2" "$MERGEN_RESOLVE_PROVIDER"
	assertEquals "1 prefix from second" "1" "$MERGEN_RESOLVE_COUNT_V4"
}

test_fallback_all_fail_stale_cache() {
	_create_failing_provider "prov1"
	_create_failing_provider "prov2"
	_create_stale_cache "64496" "203.0.113.0/24"
	_register_provider "prov1" 10
	_register_provider "prov2" 20

	mergen_resolve_asn "64496"
	assertEquals "Stale cache fallback" 0 $?
	assertEquals "Stale cache provider" "cache(stale)" "$MERGEN_RESOLVE_PROVIDER"
}

# ══════════════════════════════════════════════════════════
# AS Prefix Strip Tests
# ══════════════════════════════════════════════════════════

test_as_prefix_stripped() {
	_create_mock_provider "ripe" "10.0.0.0/8"
	_register_provider "ripe" 10

	mergen_resolve_asn "AS64496"
	assertEquals "AS prefix stripped and resolved" 0 $?
	assertEquals "Provider is ripe" "ripe" "$MERGEN_RESOLVE_PROVIDER"
}

test_lowercase_as_prefix_stripped() {
	_create_mock_provider "ripe" "10.0.0.0/8"
	_register_provider "ripe" 10

	mergen_resolve_asn "as64496"
	assertEquals "Lowercase as prefix stripped" 0 $?
}

# ══════════════════════════════════════════════════════════
# cmd_resolve CLI Tests
# ══════════════════════════════════════════════════════════

test_cmd_resolve_basic() {
	_create_mock_provider "ripe" "104.16.0.0/13
104.24.0.0/14"
	_register_provider "ripe" 10

	local output
	output="$(cmd_resolve "13335")"
	assertEquals "cmd_resolve succeeds" 0 $?

	echo "$output" | grep -q "AS13335"
	assertEquals "Output contains ASN" 0 $?

	echo "$output" | grep -q "104.16.0.0/13"
	assertEquals "Output contains prefix" 0 $?

	echo "$output" | grep -q "2 IPv4"
	assertEquals "Output contains count" 0 $?
}

test_cmd_resolve_with_provider() {
	_create_mock_provider "ripe" "10.0.0.0/8"
	_create_mock_provider "bgptools" "172.16.0.0/12"
	_register_provider "ripe" 10
	_register_provider "bgptools" 20

	local output
	output="$(cmd_resolve "64496" --provider bgptools)"
	assertEquals "Resolve with provider succeeds" 0 $?

	echo "$output" | grep -q "bgptools"
	assertEquals "Output shows forced provider" 0 $?

	echo "$output" | grep -q "172.16.0.0/12"
	assertEquals "Output shows provider-specific prefix" 0 $?
}

test_cmd_resolve_with_as_prefix() {
	_create_mock_provider "ripe" "10.0.0.0/8"
	_register_provider "ripe" 10

	local output
	output="$(cmd_resolve "AS15169")"
	assertEquals "Resolve with AS prefix succeeds" 0 $?

	echo "$output" | grep -q "AS15169"
	assertEquals "Output shows ASN" 0 $?
}

test_cmd_resolve_no_args() {
	cmd_resolve 2>/dev/null
	assertEquals "No args returns error" 2 $?
}

test_cmd_resolve_invalid_asn() {
	cmd_resolve "abc123" 2>/dev/null
	assertEquals "Invalid ASN returns error" 2 $?
}

test_cmd_resolve_nonexistent_provider() {
	cmd_resolve "13335" --provider fakeprov 2>/dev/null
	assertEquals "Nonexistent provider returns error" 1 $?
}

test_cmd_resolve_ipv6_output() {
	_create_mock_provider "ripe" "104.16.0.0/13" "2606:4700::/32"
	_register_provider "ripe" 10

	local output
	output="$(cmd_resolve "13335")"
	assertEquals "Resolve with IPv6 succeeds" 0 $?

	echo "$output" | grep -q "IPv6 Prefixler (1"
	assertEquals "Output shows IPv6 count" 0 $?

	echo "$output" | grep -q "2606:4700::/32"
	assertEquals "Output contains IPv6 prefix" 0 $?
}

# ══════════════════════════════════════════════════════════
# Cache Integration with Resolve
# ══════════════════════════════════════════════════════════

test_resolve_uses_cache() {
	_create_fresh_cache "13335" "1.1.1.0/24
104.16.0.0/13"

	local output
	output="$(cmd_resolve "13335")"
	assertEquals "Cached resolve succeeds" 0 $?

	echo "$output" | grep -q "cache-provider"
	assertEquals "Output shows cache provider" 0 $?

	echo "$output" | grep -q "2 IPv4"
	assertEquals "Output shows cached count" 0 $?
}

test_resolve_force_bypasses_cache() {
	_create_fresh_cache "13335" "1.1.1.0/24"
	_create_mock_provider "ripe" "104.16.0.0/13
104.24.0.0/14"
	_register_provider "ripe" 10

	local output
	output="$(cmd_resolve "13335" --provider ripe)"
	assertEquals "Force resolve succeeds" 0 $?

	echo "$output" | grep -q "ripe"
	assertEquals "Output shows forced provider" 0 $?

	echo "$output" | grep -q "2 IPv4"
	assertEquals "Shows 2 prefixes from provider" 0 $?
}

# ── Load shunit2 ────────────────────────────────────────

. "${MERGEN_TEST_DIR}/shunit2"

#!/bin/sh
# Test suite for provider fallback strategies and health tracking
# Tests: sequential, parallel, cache_only strategies + health monitoring
# Uses shunit2 framework — ash/busybox compatible

MERGEN_TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
MERGEN_ROOT="$(cd "$MERGEN_TEST_DIR/.." && pwd)"

# ── Test Temp Directory ─────────────────────────────────

_TEST_TMPDIR=""

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

# ── Mock Provider Helpers ───────────────────────────────

# Create a mock provider that succeeds with given data
_create_mock_provider() {
	local name="$1"
	local v4_data="$2"
	local v6_data="$3"

	cat > "${_TEST_TMPDIR}/providers/${name}.sh" <<PROVEOF
#!/bin/sh
provider_name() { echo "${name}-mock"; }
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

# Create a mock provider that always fails
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

# Create a mock provider that sleeps briefly then succeeds
_create_slow_provider() {
	local name="$1"
	local v4_data="$2"

	cat > "${_TEST_TMPDIR}/providers/${name}.sh" <<PROVEOF
#!/bin/sh
provider_name() { echo "${name}-mock"; }
provider_test() { return 0; }
provider_resolve() {
	echo "${v4_data}"
	return 0
}
PROVEOF
	chmod +x "${_TEST_TMPDIR}/providers/${name}.sh"
}

# Pre-populate stale cache (expired timestamp)
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
	MERGEN_HEALTH_DIR=""

	# Create temp directory structure
	_TEST_TMPDIR="$(mktemp -d)"
	mkdir -p "${_TEST_TMPDIR}/providers"
	mkdir -p "${_TEST_TMPDIR}/cache"
	mkdir -p "${_TEST_TMPDIR}/health"

	# Override module globals to use test directories
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
	_MOCK_CONFIG_LOADED="mergen"
}

tearDown() {
	if [ -n "$_TEST_TMPDIR" ] && [ -d "$_TEST_TMPDIR" ]; then
		rm -rf "$_TEST_TMPDIR"
	fi
}

# ══════════════════════════════════════════════════════════
# Sequential Strategy Tests
# ══════════════════════════════════════════════════════════

test_sequential_first_succeeds() {
	_create_mock_provider "prov1" "10.0.0.0/8"
	_create_mock_provider "prov2" "172.16.0.0/12"

	_MOCK_FOREACH_SECTIONS="prov1 prov2"
	_mock_uci_set "mergen.prov1.enabled=1"
	_mock_uci_set "mergen.prov1.priority=10"
	_mock_uci_set "mergen.prov2.enabled=1"
	_mock_uci_set "mergen.prov2.priority=20"

	mergen_resolve_asn "64496"
	assertEquals "Sequential first succeeds" 0 $?
	assertEquals "First provider used" "prov1" "$MERGEN_RESOLVE_PROVIDER"
}

test_sequential_fallback_to_second() {
	_create_failing_provider "prov1"
	_create_mock_provider "prov2" "172.16.0.0/12"

	_MOCK_FOREACH_SECTIONS="prov1 prov2"
	_mock_uci_set "mergen.prov1.enabled=1"
	_mock_uci_set "mergen.prov1.priority=10"
	_mock_uci_set "mergen.prov2.enabled=1"
	_mock_uci_set "mergen.prov2.priority=20"

	mergen_resolve_asn "64496"
	assertEquals "Fallback to second" 0 $?
	assertEquals "Second provider used" "prov2" "$MERGEN_RESOLVE_PROVIDER"
}

test_sequential_all_fail_uses_stale_cache() {
	_create_failing_provider "prov1"
	_create_failing_provider "prov2"
	_create_stale_cache "64496" "203.0.113.0/24"

	_MOCK_FOREACH_SECTIONS="prov1 prov2"
	_mock_uci_set "mergen.prov1.enabled=1"
	_mock_uci_set "mergen.prov1.priority=10"
	_mock_uci_set "mergen.prov2.enabled=1"
	_mock_uci_set "mergen.prov2.priority=20"

	mergen_resolve_asn "64496"
	assertEquals "Stale cache fallback succeeds" 0 $?
	assertEquals "Provider is stale cache" "cache(stale)" "$MERGEN_RESOLVE_PROVIDER"

	echo "$MERGEN_RESOLVE_RESULT_V4" | grep -q "203.0.113.0/24"
	assertEquals "Contains stale cached prefix" 0 $?
}

test_sequential_all_fail_no_cache() {
	_create_failing_provider "prov1"

	_MOCK_FOREACH_SECTIONS="prov1"
	_mock_uci_set "mergen.prov1.enabled=1"
	_mock_uci_set "mergen.prov1.priority=10"

	mergen_resolve_asn "64496"
	assertNotEquals "All fail without cache returns error" 0 $?
}

# ══════════════════════════════════════════════════════════
# Parallel Strategy Tests
# ══════════════════════════════════════════════════════════

test_parallel_picks_highest_priority() {
	_create_mock_provider "slowprov" "10.0.0.0/8"
	_create_mock_provider "fastprov" "172.16.0.0/12"

	_MOCK_FOREACH_SECTIONS="slowprov fastprov"
	_mock_uci_set "mergen.slowprov.enabled=1"
	_mock_uci_set "mergen.slowprov.priority=10"
	_mock_uci_set "mergen.fastprov.enabled=1"
	_mock_uci_set "mergen.fastprov.priority=20"
	_mock_uci_set "mergen.global.fallback_strategy=parallel"

	mergen_resolve_asn "64496"
	assertEquals "Parallel resolves" 0 $?
	assertEquals "Highest priority provider used" "slowprov" "$MERGEN_RESOLVE_PROVIDER"
}

test_parallel_one_fails_one_succeeds() {
	_create_failing_provider "badprov"
	_create_mock_provider "goodprov" "198.51.100.0/24"

	_MOCK_FOREACH_SECTIONS="badprov goodprov"
	_mock_uci_set "mergen.badprov.enabled=1"
	_mock_uci_set "mergen.badprov.priority=10"
	_mock_uci_set "mergen.goodprov.enabled=1"
	_mock_uci_set "mergen.goodprov.priority=20"
	_mock_uci_set "mergen.global.fallback_strategy=parallel"

	mergen_resolve_asn "64496"
	assertEquals "Parallel with one failure succeeds" 0 $?
	assertEquals "Working provider used" "goodprov" "$MERGEN_RESOLVE_PROVIDER"
}

test_parallel_all_fail_stale_cache() {
	_create_failing_provider "prov1"
	_create_failing_provider "prov2"
	_create_stale_cache "64496" "203.0.113.0/24"

	_MOCK_FOREACH_SECTIONS="prov1 prov2"
	_mock_uci_set "mergen.prov1.enabled=1"
	_mock_uci_set "mergen.prov1.priority=10"
	_mock_uci_set "mergen.prov2.enabled=1"
	_mock_uci_set "mergen.prov2.priority=20"
	_mock_uci_set "mergen.global.fallback_strategy=parallel"

	mergen_resolve_asn "64496"
	assertEquals "Parallel stale cache fallback" 0 $?
	assertEquals "Provider is stale cache" "cache(stale)" "$MERGEN_RESOLVE_PROVIDER"
}

test_parallel_all_fail_no_cache() {
	_create_failing_provider "prov1"

	_MOCK_FOREACH_SECTIONS="prov1"
	_mock_uci_set "mergen.prov1.enabled=1"
	_mock_uci_set "mergen.prov1.priority=10"
	_mock_uci_set "mergen.global.fallback_strategy=parallel"

	mergen_resolve_asn "64496"
	assertNotEquals "Parallel all fail returns error" 0 $?
}

# ══════════════════════════════════════════════════════════
# Cache-Only Strategy Tests
# ══════════════════════════════════════════════════════════

test_cache_only_fresh_hit() {
	# Pre-populate fresh cache
	echo "10.0.0.0/8" > "${_TEST_TMPDIR}/cache/AS64496.v4.txt"
	cat > "${_TEST_TMPDIR}/cache/AS64496.meta" <<EOF
timestamp=$(date +%s)
provider=cached-prov
ttl=86400
EOF
	_mock_uci_set "mergen.global.fallback_strategy=cache_only"

	mergen_resolve_asn "64496"
	assertEquals "Cache-only fresh hit" 0 $?
	assertEquals "Provider from cache" "cached-prov" "$MERGEN_RESOLVE_PROVIDER"
}

test_cache_only_stale_used() {
	_create_stale_cache "64496" "203.0.113.0/24"
	_mock_uci_set "mergen.global.fallback_strategy=cache_only"

	mergen_resolve_asn "64496"
	assertEquals "Cache-only stale fallback" 0 $?
	assertEquals "Provider is stale cache" "cache(stale)" "$MERGEN_RESOLVE_PROVIDER"
}

test_cache_only_miss() {
	_mock_uci_set "mergen.global.fallback_strategy=cache_only"

	mergen_resolve_asn "64496"
	assertNotEquals "Cache-only miss returns error" 0 $?
}

# ══════════════════════════════════════════════════════════
# Health Tracking Tests
# ══════════════════════════════════════════════════════════

test_health_record_success() {
	_mergen_health_record "ripe" "success" 150

	local health_file="${_TEST_TMPDIR}/health/ripe.dat"
	assertTrue "Health file created" "[ -f '$health_file' ]"

	local content
	content="$(cat "$health_file")"

	echo "$content" | grep -q "success_count=1"
	assertEquals "Success count is 1" 0 $?

	echo "$content" | grep -q "failure_count=0"
	assertEquals "Failure count is 0" 0 $?

	echo "$content" | grep -q "total_response_ms=150"
	assertEquals "Response time recorded" 0 $?
}

test_health_record_failure() {
	_mergen_health_record "ripe" "failure" 5000

	local content
	content="$(cat "${_TEST_TMPDIR}/health/ripe.dat")"

	echo "$content" | grep -q "failure_count=1"
	assertEquals "Failure count is 1" 0 $?
}

test_health_record_accumulates() {
	_mergen_health_record "ripe" "success" 100
	_mergen_health_record "ripe" "success" 200
	_mergen_health_record "ripe" "failure" 5000

	local content
	content="$(cat "${_TEST_TMPDIR}/health/ripe.dat")"

	echo "$content" | grep -q "success_count=2"
	assertEquals "Two successes accumulated" 0 $?

	echo "$content" | grep -q "failure_count=1"
	assertEquals "One failure accumulated" 0 $?

	echo "$content" | grep -q "query_count=3"
	assertEquals "Three total queries" 0 $?

	echo "$content" | grep -q "total_response_ms=5300"
	assertEquals "Total response time accumulated" 0 $?
}

test_health_get_stats() {
	_mergen_health_record "testprov" "success" 100
	_mergen_health_record "testprov" "success" 200

	_mergen_health_get "testprov"
	assertEquals "Health get succeeds" 0 $?
	assertEquals "Success count" "2" "$MERGEN_HEALTH_SUCCESS"
	assertEquals "Failure count" "0" "$MERGEN_HEALTH_FAILURE"
	assertEquals "Average response time" "150" "$MERGEN_HEALTH_AVG_MS"
}

test_health_get_missing_provider() {
	_mergen_health_get "nonexistent"
	assertNotEquals "Missing provider returns error" 0 $?
}

test_health_status_display() {
	_create_mock_provider "prov1" "10.0.0.0/8"
	_mergen_health_record "prov1" "success" 200

	_MOCK_FOREACH_SECTIONS="prov1"
	_mock_uci_set "mergen.prov1.enabled=1"
	_mock_uci_set "mergen.prov1.priority=10"

	local output
	output="$(mergen_health_status)"

	echo "$output" | grep -q "prov1"
	assertEquals "Status shows provider name" 0 $?

	echo "$output" | grep -q "1"
	assertEquals "Status shows success count" 0 $?
}

test_health_clear() {
	_mergen_health_record "prov1" "success" 100
	_mergen_health_record "prov2" "failure" 200

	assertTrue "Health file 1 exists" "[ -f '${_TEST_TMPDIR}/health/prov1.dat' ]"
	assertTrue "Health file 2 exists" "[ -f '${_TEST_TMPDIR}/health/prov2.dat' ]"

	mergen_health_clear

	assertFalse "Health file 1 removed" "[ -f '${_TEST_TMPDIR}/health/prov1.dat' ]"
	assertFalse "Health file 2 removed" "[ -f '${_TEST_TMPDIR}/health/prov2.dat' ]"
}

# ══════════════════════════════════════════════════════════
# Health Recording During Resolution
# ══════════════════════════════════════════════════════════

test_sequential_records_health_on_success() {
	_create_mock_provider "prov1" "10.0.0.0/8"

	_MOCK_FOREACH_SECTIONS="prov1"
	_mock_uci_set "mergen.prov1.enabled=1"
	_mock_uci_set "mergen.prov1.priority=10"

	mergen_resolve_asn "64496"
	assertEquals "Resolve succeeds" 0 $?

	assertTrue "Health file created" "[ -f '${_TEST_TMPDIR}/health/prov1.dat' ]"

	local content
	content="$(cat "${_TEST_TMPDIR}/health/prov1.dat")"
	echo "$content" | grep -q "success_count=1"
	assertEquals "Health records success" 0 $?
}

test_sequential_records_health_on_failure() {
	_create_failing_provider "prov1"
	_create_mock_provider "prov2" "10.0.0.0/8"

	_MOCK_FOREACH_SECTIONS="prov1 prov2"
	_mock_uci_set "mergen.prov1.enabled=1"
	_mock_uci_set "mergen.prov1.priority=10"
	_mock_uci_set "mergen.prov2.enabled=1"
	_mock_uci_set "mergen.prov2.priority=20"

	mergen_resolve_asn "64496"

	assertTrue "Failed provider health recorded" "[ -f '${_TEST_TMPDIR}/health/prov1.dat' ]"

	local content
	content="$(cat "${_TEST_TMPDIR}/health/prov1.dat")"
	echo "$content" | grep -q "failure_count=1"
	assertEquals "Failure recorded for prov1" 0 $?
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

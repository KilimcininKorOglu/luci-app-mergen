#!/bin/sh
# Test suite for cache layer in mergen/files/usr/lib/mergen/resolver.sh
# Uses shunit2 framework — ash/busybox compatible

MERGEN_TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
MERGEN_ROOT="$(cd "$MERGEN_TEST_DIR/.." && pwd)"

# ── Test Temp Directory ─────────────────────────────────

_TEST_TMPDIR=""

# ── Mock UCI System ─────────────────────────────────────

_MOCK_UCI_STORE=""
_MOCK_CONFIG_LOADED=""
_MOCK_FOREACH_SECTIONS=""
_MOCK_PROVIDER_CALL_COUNT=0

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
. "${MERGEN_ROOT}/files/usr/lib/mergen/resolver.sh"

# ── Mock Provider ───────────────────────────────────────

# Create a mock provider that tracks call count
_create_counting_provider() {
	cat > "${_TEST_TMPDIR}/providers/mock.sh" <<'PROVEOF'
#!/bin/sh
provider_name() { echo "mock-provider"; }
provider_test() { return 0; }
provider_resolve() {
	echo "192.0.2.0/24"
	echo "198.51.100.0/24"
	echo "2001:db8::/32" >&3
	return 0
}
PROVEOF
	chmod +x "${_TEST_TMPDIR}/providers/mock.sh"
}

# ── Setup/Teardown ──────────────────────────────────────

setUp() {
	_MOCK_UCI_STORE=""
	_MOCK_FOREACH_SECTIONS=""
	_MOCK_PROVIDER_CALL_COUNT=0
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

	# Override module globals
	MERGEN_PROVIDERS_DIR="${_TEST_TMPDIR}/providers"
	MERGEN_CACHE_DIR="${_TEST_TMPDIR}/cache"

	# Set up default UCI config
	_mock_uci_set "mergen.global.enabled=1"
	_mock_uci_set "mergen.global.log_level=info"
	_mock_uci_set "mergen.global.cache_dir=${_TEST_TMPDIR}/cache"
	_mock_uci_set "mergen.global.update_interval=86400"
	_MOCK_CONFIG_LOADED="mergen"

	# Set up mock provider
	_create_counting_provider
	_MOCK_FOREACH_SECTIONS="mock"
	_mock_uci_set "mergen.mock.enabled=1"
	_mock_uci_set "mergen.mock.priority=10"
}

tearDown() {
	if [ -n "$_TEST_TMPDIR" ] && [ -d "$_TEST_TMPDIR" ]; then
		rm -rf "$_TEST_TMPDIR"
	fi
}

# ── Cache Write Tests ───────────────────────────────────

test_cache_write_creates_files() {
	# Resolve — should write to cache
	mergen_resolve_asn "13335"
	assertEquals "Resolve succeeds" 0 $?

	assertTrue "V4 cache file exists" "[ -f '${_TEST_TMPDIR}/cache/AS13335.v4.txt' ]"
	assertTrue "Meta file exists" "[ -f '${_TEST_TMPDIR}/cache/AS13335.meta' ]"
}

test_cache_write_v4_content() {
	mergen_resolve_asn "13335"

	local content
	content="$(cat "${_TEST_TMPDIR}/cache/AS13335.v4.txt")"

	echo "$content" | grep -q "192.0.2.0/24"
	assertEquals "V4 cache contains first prefix" 0 $?

	echo "$content" | grep -q "198.51.100.0/24"
	assertEquals "V4 cache contains second prefix" 0 $?
}

test_cache_write_v6_content() {
	mergen_resolve_asn "13335"

	assertTrue "V6 cache file exists" "[ -f '${_TEST_TMPDIR}/cache/AS13335.v6.txt' ]"

	local content
	content="$(cat "${_TEST_TMPDIR}/cache/AS13335.v6.txt")"

	echo "$content" | grep -q "2001:db8::/32"
	assertEquals "V6 cache contains prefix" 0 $?
}

test_cache_write_meta_content() {
	mergen_resolve_asn "13335"

	local meta
	meta="$(cat "${_TEST_TMPDIR}/cache/AS13335.meta")"

	echo "$meta" | grep -q "timestamp="
	assertEquals "Meta has timestamp" 0 $?

	echo "$meta" | grep -q "provider=mock"
	assertEquals "Meta has provider" 0 $?
}

# ── Cache Hit Tests ─────────────────────────────────────

test_cache_hit_reads_from_file() {
	# Pre-populate cache
	echo "10.0.0.0/8" > "${_TEST_TMPDIR}/cache/AS99999.v4.txt"
	cat > "${_TEST_TMPDIR}/cache/AS99999.meta" <<EOF
timestamp=$(date +%s)
provider=precached
ttl=86400
EOF

	mergen_resolve_asn "99999"
	assertEquals "Cached resolve succeeds" 0 $?
	assertEquals "Provider is from cache" "precached" "$MERGEN_RESOLVE_PROVIDER"

	echo "$MERGEN_RESOLVE_RESULT_V4" | grep -q "10.0.0.0/8"
	assertEquals "Returns cached prefix" 0 $?
}

test_cache_hit_does_not_call_provider() {
	# Pre-populate cache with fresh data
	echo "10.0.0.0/8" > "${_TEST_TMPDIR}/cache/AS88888.v4.txt"
	cat > "${_TEST_TMPDIR}/cache/AS88888.meta" <<EOF
timestamp=$(date +%s)
provider=precached
ttl=86400
EOF

	# Remove provider to ensure it's not called
	rm -f "${_TEST_TMPDIR}/providers/mock.sh"

	mergen_resolve_asn "88888"
	assertEquals "Cached resolve succeeds without provider" 0 $?
	assertEquals "Provider is from cache" "precached" "$MERGEN_RESOLVE_PROVIDER"
}

# ── Cache Expiry Tests ──────────────────────────────────

test_cache_expired_refetches() {
	# Pre-populate cache with expired data (timestamp = 0)
	echo "10.0.0.0/8" > "${_TEST_TMPDIR}/cache/AS77777.v4.txt"
	cat > "${_TEST_TMPDIR}/cache/AS77777.meta" <<EOF
timestamp=0
provider=old-provider
ttl=86400
EOF

	mergen_resolve_asn "77777"
	assertEquals "Expired cache resolve succeeds" 0 $?

	# Should have fetched from mock provider, not cache
	assertEquals "Provider is mock, not cache" "mock" "$MERGEN_RESOLVE_PROVIDER"

	# Should have new data from mock provider
	echo "$MERGEN_RESOLVE_RESULT_V4" | grep -q "192.0.2.0/24"
	assertEquals "Has fresh data from provider" 0 $?
}

test_cache_missing_meta_refetches() {
	# V4 file exists but no meta
	echo "10.0.0.0/8" > "${_TEST_TMPDIR}/cache/AS66666.v4.txt"

	mergen_resolve_asn "66666"
	assertEquals "Missing meta resolve succeeds" 0 $?
	assertEquals "Fetched from provider" "mock" "$MERGEN_RESOLVE_PROVIDER"
}

# ── Cache Clear Tests ───────────────────────────────────

test_cache_clear_removes_files() {
	# Create some cache files
	echo "10.0.0.0/8" > "${_TEST_TMPDIR}/cache/AS11111.v4.txt"
	echo "2001:db8::/32" > "${_TEST_TMPDIR}/cache/AS11111.v6.txt"
	echo "timestamp=123" > "${_TEST_TMPDIR}/cache/AS11111.meta"
	echo "172.16.0.0/12" > "${_TEST_TMPDIR}/cache/AS22222.v4.txt"
	echo "timestamp=456" > "${_TEST_TMPDIR}/cache/AS22222.meta"

	mergen_cache_clear

	assertFalse "V4 file 1 removed" "[ -f '${_TEST_TMPDIR}/cache/AS11111.v4.txt' ]"
	assertFalse "V6 file removed" "[ -f '${_TEST_TMPDIR}/cache/AS11111.v6.txt' ]"
	assertFalse "Meta file 1 removed" "[ -f '${_TEST_TMPDIR}/cache/AS11111.meta' ]"
	assertFalse "V4 file 2 removed" "[ -f '${_TEST_TMPDIR}/cache/AS22222.v4.txt' ]"
	assertFalse "Meta file 2 removed" "[ -f '${_TEST_TMPDIR}/cache/AS22222.meta' ]"
}

test_cache_clear_empty_dir() {
	# Should not error on empty cache
	mergen_cache_clear
	assertEquals "Clear empty cache succeeds" 0 $?
}

# ── Cache Stats Tests ───────────────────────────────────

test_cache_stats_empty() {
	local output
	output="$(mergen_cache_stats)"
	echo "$output" | grep -q "0 ASN"
	assertEquals "Empty cache shows 0" 0 $?
}

test_cache_stats_with_data() {
	echo "10.0.0.0/8" > "${_TEST_TMPDIR}/cache/AS11111.v4.txt"
	echo "timestamp=123" > "${_TEST_TMPDIR}/cache/AS11111.meta"
	echo "172.16.0.0/12" > "${_TEST_TMPDIR}/cache/AS22222.v4.txt"
	echo "timestamp=456" > "${_TEST_TMPDIR}/cache/AS22222.meta"

	local output
	output="$(mergen_cache_stats)"
	echo "$output" | grep -q "2 ASN"
	assertEquals "Shows 2 cached ASNs" 0 $?
}

# ── Force Provider Bypasses Cache ───────────────────────

test_force_provider_bypasses_cache() {
	# Pre-populate cache
	echo "10.0.0.0/8" > "${_TEST_TMPDIR}/cache/AS55555.v4.txt"
	cat > "${_TEST_TMPDIR}/cache/AS55555.meta" <<EOF
timestamp=$(date +%s)
provider=cached
ttl=86400
EOF

	mergen_resolve_asn "55555" "mock"
	assertEquals "Force provider succeeds" 0 $?
	assertEquals "Used forced provider, not cache" "mock" "$MERGEN_RESOLVE_PROVIDER"

	# Should have updated cache with new data
	local cached
	cached="$(cat "${_TEST_TMPDIR}/cache/AS55555.v4.txt")"
	echo "$cached" | grep -q "192.0.2.0/24"
	assertEquals "Cache updated with fresh data" 0 $?
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

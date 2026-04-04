#!/bin/sh
# Platform Compatibility Test Suite for Mergen
# Tests: POSIX compliance, busybox compatibility, OpenWrt environment checks
# Uses shunit2 framework — ash/busybox compatible

MERGEN_TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
MERGEN_ROOT="$(cd "$MERGEN_TEST_DIR/.." && pwd)"

# ── Mock UCI System ──────────────────────────────────────

_MOCK_UCI_STORE=""
_MOCK_CONFIG_LOADED=""

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
			if [ "$1" = "-q" ]; then shift; fi
			_mock_uci_get "$1"
			;;
		set) _mock_uci_set "$1" ;;
		commit) return 0 ;;
		*) return 0 ;;
	esac
}

_mock_uci_get() {
	local path="$1"
	local key
	key="$(echo "$path" | tr '.' '_')"
	eval "echo \"\${_UCI_${key}:-}\""
}

_mock_uci_set() {
	local assignment="$1"
	local path="${assignment%%=*}"
	local value="${assignment#*=}"
	local key
	key="$(echo "$path" | tr '.' '_')"
	eval "_UCI_${key}=\"${value}\""
}

config_load() { _MOCK_CONFIG_LOADED="$1"; }
config_get() {
	local var="$1" section="$2" option="$3" default="$4"
	local key="_UCI_${_MOCK_CONFIG_LOADED}_${section}_${option}"
	local val
	eval "val=\"\${${key}:-}\""
	if [ -z "$val" ]; then
		eval "${var}=\"${default}\""
	else
		eval "${var}=\"${val}\""
	fi
}
config_set() { return 0; }
config_foreach() { return 0; }

# ── Test Temp Setup ──────────────────────────────────────

setUp() {
	MERGEN_TMP="$(mktemp -d)"
	MERGEN_CONF="mergen"
	MERGEN_LIB_DIR="${MERGEN_ROOT}/files/usr/lib/mergen"
	export MERGEN_TMP MERGEN_CONF MERGEN_LIB_DIR

	mkdir -p "${MERGEN_TMP}/cache"

	_UCI_mergen_global_enabled="1"
	_UCI_mergen_global_log_level="error"
	_UCI_mergen_global_default_table="100"
	_UCI_mergen_global_packet_engine="auto"
	_UCI_mergen_global_mode="standalone"
}

tearDown() {
	rm -rf "$MERGEN_TMP"
}

# ── Source Libraries ─────────────────────────────────────

. "${MERGEN_ROOT}/files/usr/lib/mergen/core.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/utils.sh"

# ── POSIX Shell Compliance Tests ─────────────────────────

# Test: All shell scripts use /bin/sh shebang
test_shebang_compliance() {
	local fail_count=0
	local checked=0

	for script in "${MERGEN_ROOT}/files/usr/lib/mergen"/*.sh \
		"${MERGEN_ROOT}/files/usr/bin/mergen" \
		"${MERGEN_ROOT}/files/usr/sbin/mergen-watchdog"; do
		[ -f "$script" ] || continue
		checked=$((checked + 1))

		local shebang
		shebang="$(head -1 "$script")"
		case "$shebang" in
			"#!/bin/sh"*) ;;
			*)
				fail_count=$((fail_count + 1))
				;;
		esac
	done

	assertTrue "Should check at least 5 scripts" "[ $checked -ge 5 ]"
	assertEquals "All scripts should use #!/bin/sh shebang" 0 "$fail_count"
}

# Test: No bash-specific syntax in shell scripts
test_no_bashisms() {
	local fail_count=0
	local checked=0

	for script in "${MERGEN_ROOT}/files/usr/lib/mergen"/*.sh; do
		[ -f "$script" ] || continue
		checked=$((checked + 1))

		# Check for common bashisms
		# Arrays: declare -a, ${array[@]}
		if grep -qE 'declare\s+-[aA]|local\s+-[aA]' "$script" 2>/dev/null; then
			fail_count=$((fail_count + 1))
		fi

		# [[ ]] double brackets (bash-specific)
		if grep -qE '\[\[.*\]\]' "$script" 2>/dev/null; then
			fail_count=$((fail_count + 1))
		fi

		# $((RANDOM)) or $RANDOM (not POSIX)
		if grep -qE '\$RANDOM|\$\(\(RANDOM' "$script" 2>/dev/null; then
			fail_count=$((fail_count + 1))
		fi

		# &>> redirect (bash-specific)
		if grep -qE '&>>' "$script" 2>/dev/null; then
			fail_count=$((fail_count + 1))
		fi

		# function keyword (bash-style function definition)
		if grep -qE '^[[:space:]]*function[[:space:]]' "$script" 2>/dev/null; then
			fail_count=$((fail_count + 1))
		fi
	done

	assertTrue "Should check at least 5 library scripts" "[ $checked -ge 5 ]"
	assertEquals "No bashisms detected" 0 "$fail_count"
}

# Test: No process substitution <() or >() in shell scripts
test_no_process_substitution() {
	local fail_count=0

	for script in "${MERGEN_ROOT}/files/usr/lib/mergen"/*.sh \
		"${MERGEN_ROOT}/files/usr/bin/mergen" \
		"${MERGEN_ROOT}/files/usr/sbin/mergen-watchdog"; do
		[ -f "$script" ] || continue

		if grep -qE '<\(|>\(' "$script" 2>/dev/null; then
			fail_count=$((fail_count + 1))
		fi
	done

	assertEquals "No process substitution in any script" 0 "$fail_count"
}

# ── File Structure Tests ─────────────────────────────────

# Test: All required library files exist
test_library_files_exist() {
	local required_libs="core.sh utils.sh engine.sh resolver.sh route.sh"

	for lib in $required_libs; do
		assertTrue "Library ${lib} should exist" \
			"[ -f '${MERGEN_ROOT}/files/usr/lib/mergen/${lib}' ]"
	done
}

# Test: Main CLI binary exists and is executable
test_cli_binary_exists() {
	assertTrue "CLI binary should exist" \
		"[ -f '${MERGEN_ROOT}/files/usr/bin/mergen' ]"
}

# Test: Watchdog daemon exists
test_watchdog_exists() {
	assertTrue "Watchdog should exist" \
		"[ -f '${MERGEN_ROOT}/files/usr/sbin/mergen-watchdog' ]"
}

# Test: UCI config template exists
test_uci_config_exists() {
	assertTrue "UCI config should exist" \
		"[ -f '${MERGEN_ROOT}/files/etc/config/mergen' ]"
}

# Test: Init script exists
test_init_script_exists() {
	assertTrue "Init script should exist" \
		"[ -f '${MERGEN_ROOT}/files/etc/init.d/mergen' ]"
}

# Test: Migration script exists
test_migration_script_exists() {
	assertTrue "Migration script should exist" \
		"[ -f '${MERGEN_ROOT}/files/usr/lib/mergen/migrate.sh' ]"
}

# ── OpenWrt Package Structure Tests ──────────────────────

# Test: Makefile exists and has required variables
test_makefile_exists() {
	assertTrue "Makefile should exist" \
		"[ -f '${MERGEN_ROOT}/Makefile' ]"

	# Check for required OpenWrt package Makefile variables
	local makefile="${MERGEN_ROOT}/Makefile"
	assertTrue "Makefile should define PKG_NAME" \
		"grep -q 'PKG_NAME' '$makefile'"
	assertTrue "Makefile should define PKG_VERSION" \
		"grep -q 'PKG_VERSION' '$makefile'"
}

# Test: Package directory structure
test_package_structure() {
	assertTrue "files/ directory should exist" \
		"[ -d '${MERGEN_ROOT}/files' ]"
	assertTrue "files/usr/lib/mergen/ should exist" \
		"[ -d '${MERGEN_ROOT}/files/usr/lib/mergen' ]"
	assertTrue "files/usr/bin/ should exist" \
		"[ -d '${MERGEN_ROOT}/files/usr/bin' ]"
	assertTrue "files/etc/config/ should exist" \
		"[ -d '${MERGEN_ROOT}/files/etc/config' ]"
	assertTrue "files/etc/init.d/ should exist" \
		"[ -d '${MERGEN_ROOT}/files/etc/init.d' ]"
}

# ── Utility Function Compatibility Tests ─────────────────

# Test: validate_name works with various inputs
test_validate_name_compat() {
	assertTrue "Simple name" "validate_name 'test-rule'"
	assertTrue "Underscore name" "validate_name 'my_rule'"
	assertTrue "Number name" "validate_name 'rule123'"
	assertFalse "Space in name" "validate_name 'my rule'"
	assertFalse "Special chars" "validate_name 'rule!@#'"
	assertFalse "Empty name" "validate_name ''"
}

# Test: validate_asn works with valid/invalid inputs
test_validate_asn_compat() {
	assertTrue "Valid ASN" "validate_asn '13335'"
	assertTrue "Large ASN" "validate_asn '4294967295'"
	assertFalse "Zero ASN" "validate_asn '0'"
	assertFalse "Negative ASN" "validate_asn '-1'"
	assertFalse "Non-numeric ASN" "validate_asn 'abc'"
}

# Test: validate_cidr works with IPv4 and IPv6
test_validate_cidr_compat() {
	assertTrue "IPv4 /24" "validate_ip_cidr '10.0.0.0/24'"
	assertTrue "IPv4 /32" "validate_ip_cidr '192.168.1.1/32'"
	assertTrue "IPv4 /8" "validate_ip_cidr '10.0.0.0/8'"
	assertTrue "Bare IP (valid)" "validate_ip_cidr '10.0.0.0'"
	assertFalse "Invalid prefix" "validate_ip_cidr '10.0.0.0/33'"
	assertFalse "Non-IP" "validate_ip_cidr 'not-an-ip/24'"
}

# Test: validate_domain works across platforms
test_validate_domain_compat() {
	assertTrue "Simple domain" "validate_domain 'example.com'"
	assertTrue "Subdomain" "validate_domain 'sub.example.com'"
	assertTrue "Wildcard" "validate_domain '*.example.com'"
	assertFalse "Bare TLD" "validate_domain 'com'"
	assertFalse "Empty domain" "validate_domain ''"
}

# Test: validate_country_code works
test_validate_country_code_compat() {
	assertTrue "US code" "validate_country_code 'US'"
	assertTrue "TR code" "validate_country_code 'TR'"
	assertTrue "Lowercase auto-uppercase" "validate_country_code 'us'"
	assertFalse "Three chars" "validate_country_code 'USA'"
	assertFalse "One char" "validate_country_code 'A'"
}

# ── External Tool Detection Tests ────────────────────────

# Test: Required external tools (POSIX)
test_posix_tools_available() {
	local required_tools="sed awk grep wc head tail cut tr date cat mkdir rm"

	for tool in $required_tools; do
		assertTrue "POSIX tool ${tool} should be available" \
			"command -v $tool >/dev/null 2>&1"
	done
}

# Test: Network tools detection (optional — may not be present in CI)
test_network_tools_detection() {
	# These are informational — skip if not available
	if command -v ip >/dev/null 2>&1; then
		assertTrue "ip command found" "true"
	else
		startSkipping
	fi
}

# ── UCI Config Compatibility Tests ───────────────────────

# Test: Default UCI config has all required fields
test_uci_config_completeness() {
	local config_file="${MERGEN_ROOT}/files/etc/config/mergen"
	assertTrue "Config file should exist" "[ -f '$config_file' ]"

	local required_fields="enabled log_level update_interval default_table ipv6_enabled mode config_version"
	for field in $required_fields; do
		assertTrue "Config should contain '${field}'" \
			"grep -q '${field}' '$config_file'"
	done
}

# Test: Provider sections exist in default config
test_uci_provider_sections() {
	local config_file="${MERGEN_ROOT}/files/etc/config/mergen"

	assertTrue "Config should have ripe provider" \
		"grep -q \"config provider 'ripe'\" '$config_file'"
}

# ── LuCI Package Structure Tests ─────────────────────────

# Test: LuCI app package structure
test_luci_package_structure() {
	local luci_root="${MERGEN_ROOT}/../luci-app-mergen"

	if [ -d "$luci_root" ]; then
		assertTrue "LuCI controller should exist" \
			"[ -f '${luci_root}/luasrc/controller/mergen.lua' ]"
		assertTrue "LuCI CSS should exist" \
			"[ -f '${luci_root}/htdocs/luci-static/mergen/mergen.css' ]"
		assertTrue "LuCI JS should exist" \
			"[ -f '${luci_root}/htdocs/luci-static/mergen/mergen.js' ]"
		assertTrue "English translations should exist" \
			"[ -f '${luci_root}/po/en/mergen.po' ]"
		assertTrue "Turkish translations should exist" \
			"[ -f '${luci_root}/po/tr/mergen.po' ]"
	else
		startSkipping
	fi
}

# ── Run Tests ────────────────────────────────────────────

. "${MERGEN_TEST_DIR}/shunit2"

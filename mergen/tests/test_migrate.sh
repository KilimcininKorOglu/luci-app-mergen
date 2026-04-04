#!/bin/sh
# Test suite for mergen/files/usr/lib/mergen/migrate.sh
# Uses shunit2 framework — ash/busybox compatible

MERGEN_TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
MERGEN_ROOT="$(cd "$MERGEN_TEST_DIR/.." && pwd)"

# ── Test Temp Directory ─────────────────────────────────

_TEST_TMPDIR=""

# ── Mock UCI System ─────────────────────────────────────

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

# Mock logger
logger() { :; }

# ── Source modules under test ───────────────────────────

. "${MERGEN_ROOT}/files/usr/lib/mergen/core.sh"

# Source migrate with guard
MERGEN_MIGRATE_SOURCED=1
. "${MERGEN_ROOT}/files/usr/lib/mergen/migrate.sh"

# ── Setup/Teardown ──────────────────────────────────────

setUp() {
	_MOCK_UCI_STORE=""
	_MOCK_CONFIG_LOADED=""

	# Create temp directory structure
	_TEST_TMPDIR="$(mktemp -d)"

	# Override globals
	MERGEN_TMP="${_TEST_TMPDIR}"
	MERGEN_BACKUP_FILE="${_TEST_TMPDIR}/config.backup"
	MERGEN_CONFIG_FILE="${_TEST_TMPDIR}/config/mergen"
	MERGEN_CONF="mergen"

	# Create mock config file
	mkdir -p "${_TEST_TMPDIR}/config"
	cat > "$MERGEN_CONFIG_FILE" <<'CONFEOF'
config mergen 'global'
	option enabled '0'
	option log_level 'info'
	option config_version '1'
CONFEOF

	# Set up UCI store to match
	_mock_uci_set "mergen.global.enabled=0"
	_mock_uci_set "mergen.global.log_level=info"
	_mock_uci_set "mergen.global.config_version=1"
}

tearDown() {
	if [ -n "$_TEST_TMPDIR" ] && [ -d "$_TEST_TMPDIR" ]; then
		rm -rf "$_TEST_TMPDIR"
	fi
}

# ── Version Detection Tests ─────────────────────────────

test_get_version_returns_current() {
	_mock_uci_set "mergen.global.config_version=1"
	local ver
	ver="$(migrate_get_version)"
	assertEquals "Config version is 1" "1" "$ver"
}

test_get_version_missing_returns_zero() {
	# Clear the store — no config_version set
	_MOCK_UCI_STORE=""
	local ver
	ver="$(migrate_get_version)"
	assertEquals "Missing version returns 0" "0" "$ver"
}

test_get_version_higher_value() {
	_mock_uci_set "mergen.global.config_version=5"
	local ver
	ver="$(migrate_get_version)"
	assertEquals "Config version is 5" "5" "$ver"
}

# ── Backup Tests ────────────────────────────────────────

test_backup_creates_file() {
	migrate_backup
	assertTrue "Backup file created" "[ -f '$MERGEN_BACKUP_FILE' ]"
}

test_backup_content_matches_original() {
	migrate_backup
	local orig_content backup_content
	orig_content="$(cat "$MERGEN_CONFIG_FILE")"
	backup_content="$(cat "$MERGEN_BACKUP_FILE")"
	assertEquals "Backup matches original" "$orig_content" "$backup_content"
}

test_backup_missing_config_fails() {
	rm -f "$MERGEN_CONFIG_FILE"
	migrate_backup
	local ret=$?
	assertEquals "Backup fails when config missing" 1 "$ret"
}

test_backup_creates_tmp_dir() {
	rm -rf "$MERGEN_TMP"
	MERGEN_BACKUP_FILE="${MERGEN_TMP}/config.backup"
	migrate_backup
	assertTrue "TMP dir created" "[ -d '$MERGEN_TMP' ]"
}

# ── Restore Tests ───────────────────────────────────────

test_restore_from_backup() {
	# Create backup first
	migrate_backup

	# Modify the config
	echo "MODIFIED" > "$MERGEN_CONFIG_FILE"

	# Restore
	migrate_restore
	local content
	content="$(cat "$MERGEN_CONFIG_FILE")"

	echo "$content" | grep -q "config mergen"
	assertEquals "Config restored from backup" 0 $?
}

test_restore_no_backup_fails() {
	rm -f "$MERGEN_BACKUP_FILE"
	migrate_restore
	local ret=$?
	assertEquals "Restore fails without backup" 1 "$ret"
}

# ── Migration Run Tests ─────────────────────────────────

test_run_current_version_noop() {
	_mock_uci_set "mergen.global.config_version=1"
	MERGEN_EXPECTED_VERSION="1"

	migrate_run
	local ret=$?
	assertEquals "No migration needed" 0 "$ret"

	# No backup should be created for noop
	assertFalse "No backup for noop" "[ -f '$MERGEN_BACKUP_FILE' ]"
}

test_run_v0_to_v1_migration() {
	# Simulate version 0 (no config_version)
	_MOCK_UCI_STORE=""
	_mock_uci_set "mergen.global.enabled=0"
	MERGEN_EXPECTED_VERSION="1"

	migrate_run
	local ret=$?
	assertEquals "Migration succeeds" 0 "$ret"

	# Verify version was updated
	local ver
	ver="$(_mock_uci_get "mergen.global.config_version")"
	assertEquals "Version updated to 1" "1" "$ver"
}

test_run_creates_backup_before_migration() {
	_MOCK_UCI_STORE=""
	_mock_uci_set "mergen.global.enabled=0"
	MERGEN_EXPECTED_VERSION="1"

	migrate_run

	assertTrue "Backup created during migration" "[ -f '$MERGEN_BACKUP_FILE' ]"
}

test_run_v0_ensures_defaults() {
	# Start with empty config (version 0)
	_MOCK_UCI_STORE=""
	MERGEN_EXPECTED_VERSION="1"

	migrate_run

	# Check defaults were applied
	local enabled log_level update_interval default_table
	enabled="$(_mock_uci_get "mergen.global.enabled")"
	log_level="$(_mock_uci_get "mergen.global.log_level")"
	update_interval="$(_mock_uci_get "mergen.global.update_interval")"
	default_table="$(_mock_uci_get "mergen.global.default_table")"

	assertEquals "Enabled default set" "0" "$enabled"
	assertEquals "Log level default set" "info" "$log_level"
	assertEquals "Update interval default set" "86400" "$update_interval"
	assertEquals "Default table set" "100" "$default_table"
}

test_run_missing_migrate_func_restores_backup() {
	# Set version to something with no migration function
	_mock_uci_set "mergen.global.config_version=50"
	MERGEN_EXPECTED_VERSION="51"

	migrate_run
	local ret=$?
	assertEquals "Migration fails" 1 "$ret"

	# Config should be restored
	local content
	content="$(cat "$MERGEN_CONFIG_FILE")"
	echo "$content" | grep -q "config mergen"
	assertEquals "Config restored after failure" 0 $?
}

# ── Set Version Test ────────────────────────────────────

test_set_version_updates_uci() {
	migrate_set_version "2"
	local ver
	ver="$(_mock_uci_get "mergen.global.config_version")"
	assertEquals "Version set to 2" "2" "$ver"
}

# ── Check Mode Test ─────────────────────────────────────

test_check_reports_current_status() {
	_mock_uci_set "mergen.global.config_version=1"
	MERGEN_EXPECTED_VERSION="1"

	# Simulate --check by calling the functions directly
	local ver
	ver="$(migrate_get_version)"
	assertEquals "Check returns current version" "1" "$ver"
	assertEquals "Expected version matches" "1" "$MERGEN_EXPECTED_VERSION"
}

test_check_reports_needs_migration() {
	_MOCK_UCI_STORE=""
	MERGEN_EXPECTED_VERSION="1"

	local ver
	ver="$(migrate_get_version)"
	assertEquals "Old version detected" "0" "$ver"
	assertNotEquals "Versions differ" "$ver" "$MERGEN_EXPECTED_VERSION"
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

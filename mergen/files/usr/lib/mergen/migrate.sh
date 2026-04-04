#!/bin/sh
# Mergen Config Migration Script
# Handles UCI configuration schema upgrades between versions
# Called by postinst during package upgrade
#
# Usage: /usr/lib/mergen/migrate.sh [--check]
#   --check: only report current version, do not migrate

MERGEN_LIB_DIR="${MERGEN_LIB_DIR:-/usr/lib/mergen}"
MERGEN_TMP="${MERGEN_TMP:-/tmp/mergen}"
MERGEN_CONF="mergen"
MERGEN_BACKUP_FILE="${MERGEN_TMP}/config.backup"
MERGEN_CONFIG_FILE="/etc/config/mergen"

# Current expected config version
MERGEN_EXPECTED_VERSION="1"

# Load OpenWrt shell functions
type config_load >/dev/null 2>&1 || { [ -f /lib/functions.sh ] && . /lib/functions.sh; }

# Load core library for logging
type mergen_log >/dev/null 2>&1 || . "${MERGEN_LIB_DIR}/core.sh"

# ── Helpers ────────────────────────────────────────────────

# Read the current config_version from UCI
migrate_get_version() {
	local ver
	ver="$(uci -q get "${MERGEN_CONF}.global.config_version" 2>/dev/null)"
	echo "${ver:-0}"
}

# Create a backup of the config file before migration
migrate_backup() {
	[ -d "$MERGEN_TMP" ] || mkdir -p "$MERGEN_TMP"

	if [ -f "$MERGEN_CONFIG_FILE" ]; then
		cp "$MERGEN_CONFIG_FILE" "$MERGEN_BACKUP_FILE"
		mergen_log "info" "Migrate" "Yedek olusturuldu: ${MERGEN_BACKUP_FILE}"
		return 0
	else
		mergen_log "warning" "Migrate" "Config dosyasi bulunamadi: ${MERGEN_CONFIG_FILE}"
		return 1
	fi
}

# Restore config from backup
migrate_restore() {
	if [ -f "$MERGEN_BACKUP_FILE" ]; then
		cp "$MERGEN_BACKUP_FILE" "$MERGEN_CONFIG_FILE"
		mergen_log "info" "Migrate" "Yedekten geri yuklendi: ${MERGEN_BACKUP_FILE}"
		return 0
	else
		mergen_log "error" "Migrate" "Yedek dosyasi bulunamadi: ${MERGEN_BACKUP_FILE}"
		return 1
	fi
}

# Set config version in UCI
migrate_set_version() {
	local ver="$1"
	uci set "${MERGEN_CONF}.global.config_version=${ver}"
	uci commit "$MERGEN_CONF"
}

# ── Migration Functions ────────────────────────────────────
# Each function migrates from version N to N+1
# Add new migration functions as the config schema evolves

# Example: migrate from version 0 (no version field) to version 1
_migrate_0_to_1() {
	mergen_log "info" "Migrate" "v0 -> v1: config_version alani ekleniyor"

	# Version 0 had no config_version field — add it
	# Also ensure all required global options exist with defaults
	local has_enabled has_log_level has_update_interval has_default_table

	has_enabled="$(uci -q get "${MERGEN_CONF}.global.enabled" 2>/dev/null)"
	[ -z "$has_enabled" ] && uci set "${MERGEN_CONF}.global.enabled=0"

	has_log_level="$(uci -q get "${MERGEN_CONF}.global.log_level" 2>/dev/null)"
	[ -z "$has_log_level" ] && uci set "${MERGEN_CONF}.global.log_level=info"

	has_update_interval="$(uci -q get "${MERGEN_CONF}.global.update_interval" 2>/dev/null)"
	[ -z "$has_update_interval" ] && uci set "${MERGEN_CONF}.global.update_interval=86400"

	has_default_table="$(uci -q get "${MERGEN_CONF}.global.default_table" 2>/dev/null)"
	[ -z "$has_default_table" ] && uci set "${MERGEN_CONF}.global.default_table=100"

	uci set "${MERGEN_CONF}.global.config_version=1"
	uci commit "$MERGEN_CONF"

	return 0
}

# ── Migration Engine ──────────────────────────────────────

# Run all necessary migrations from current to expected version
migrate_run() {
	local current_version
	current_version="$(migrate_get_version)"

	if [ "$current_version" = "$MERGEN_EXPECTED_VERSION" ]; then
		mergen_log "info" "Migrate" "Config surumu guncel (v${current_version})"
		return 0
	fi

	mergen_log "info" "Migrate" "Migrasyon baslatiliyor: v${current_version} -> v${MERGEN_EXPECTED_VERSION}"

	# Create backup before any migration
	if ! migrate_backup; then
		mergen_log "error" "Migrate" "Yedek olusturulamadi, migrasyon iptal edildi"
		return 1
	fi

	# Apply migrations sequentially
	local ver="$current_version"
	while [ "$ver" -lt "$MERGEN_EXPECTED_VERSION" ]; do
		local next=$((ver + 1))
		local migrate_func="_migrate_${ver}_to_${next}"

		# Check if migration function exists
		if type "$migrate_func" >/dev/null 2>&1; then
			mergen_log "info" "Migrate" "Migrasyon calistiriliyor: v${ver} -> v${next}"

			if ! "$migrate_func"; then
				mergen_log "error" "Migrate" "Migrasyon basarisiz: v${ver} -> v${next}"
				mergen_log "info" "Migrate" "Yedekten geri yukleniyor..."
				migrate_restore
				return 1
			fi

			mergen_log "info" "Migrate" "Migrasyon basarili: v${ver} -> v${next}"
		else
			mergen_log "error" "Migrate" "Migrasyon fonksiyonu bulunamadi: ${migrate_func}"
			mergen_log "info" "Migrate" "Yedekten geri yukleniyor..."
			migrate_restore
			return 1
		fi

		ver="$next"
	done

	# Verify final version
	local final_version
	final_version="$(migrate_get_version)"
	if [ "$final_version" = "$MERGEN_EXPECTED_VERSION" ]; then
		mergen_log "info" "Migrate" "Migrasyon tamamlandi: v${final_version}"
		return 0
	else
		mergen_log "error" "Migrate" "Son surum beklenen ile eslesmiyor: v${final_version} != v${MERGEN_EXPECTED_VERSION}"
		migrate_restore
		return 1
	fi
}

# ── Entry Point ────────────────────────────────────────────
# Guard: skip when sourced for testing (MERGEN_MIGRATE_SOURCED=1)

if [ "${MERGEN_MIGRATE_SOURCED:-0}" != "1" ]; then
	case "${1:-}" in
		--check)
			ver="$(migrate_get_version)"
			echo "current=${ver}"
			echo "expected=${MERGEN_EXPECTED_VERSION}"
			if [ "$ver" = "$MERGEN_EXPECTED_VERSION" ]; then
				echo "status=current"
			else
				echo "status=needs_migration"
			fi
			;;
		*)
			migrate_run
			exit $?
			;;
	esac
fi

#!/bin/sh
# Mergen Core Library
# UCI read/write wrappers, logging, and lock management
# All Mergen components source this file

MERGEN_CONF="mergen"
MERGEN_UCI_RESULT=""

# ── Logging ──────────────────────────────────────────────

# Log levels: debug=0, info=1, warning=2, error=3
_mergen_log_level_num() {
	case "$1" in
		debug)   echo 0 ;;
		info)    echo 1 ;;
		warning) echo 2 ;;
		error)   echo 3 ;;
		*)       echo 1 ;;
	esac
}

mergen_log() {
	local level="$1" component="$2" message="$3"
	local configured_level

	# Read configured log level (default: info)
	configured_level="$(uci -q get ${MERGEN_CONF}.global.log_level 2>/dev/null)"
	configured_level="${configured_level:-info}"

	local msg_num configured_num
	msg_num="$(_mergen_log_level_num "$level")"
	configured_num="$(_mergen_log_level_num "$configured_level")"

	# Only log if message level >= configured level
	[ "$msg_num" -ge "$configured_num" ] || return 0

	local tag="mergen"
	local syslog_priority="daemon.info"
	case "$level" in
		debug)   syslog_priority="daemon.debug" ;;
		info)    syslog_priority="daemon.info" ;;
		warning) syslog_priority="daemon.warning" ;;
		error)   syslog_priority="daemon.err" ;;
	esac

	logger -t "$tag" -p "$syslog_priority" "[${level}] [${component}] ${message}"
}

# ── UCI Wrappers ─────────────────────────────────────────

mergen_uci_get() {
	local section="$1" option="$2" default="$3"
	MERGEN_UCI_RESULT="$(uci -q get "${MERGEN_CONF}.${section}.${option}" 2>/dev/null)"
	[ -z "$MERGEN_UCI_RESULT" ] && MERGEN_UCI_RESULT="$default"
}

mergen_uci_set() {
	local section="$1" option="$2" value="$3"
	uci set "${MERGEN_CONF}.${section}.${option}=${value}" 2>/dev/null
}

mergen_uci_add() {
	local type="$1"
	MERGEN_UCI_RESULT="$(uci add "$MERGEN_CONF" "$type" 2>/dev/null)"
}

mergen_uci_delete() {
	local path="$1"
	uci delete "${MERGEN_CONF}.${path}" 2>/dev/null
}

mergen_uci_commit() {
	uci commit "$MERGEN_CONF" 2>/dev/null
}

# ── Lock Management ──────────────────────────────────────

MERGEN_LOCK="/var/lock/mergen.lock"
MERGEN_LOCK_FD=9

mergen_lock_acquire() {
	local timeout="${1:-30}"

	# Create lock directory if needed
	[ -d /var/lock ] || mkdir -p /var/lock

	# Clean stale lock (older than 5 minutes)
	if [ -f "$MERGEN_LOCK" ]; then
		local lock_age
		lock_age="$(find "$MERGEN_LOCK" -mmin +5 2>/dev/null)"
		if [ -n "$lock_age" ]; then
			mergen_log "warning" "Core" "Removing stale lock file"
			rm -f "$MERGEN_LOCK"
		fi
	fi

	# Attempt to acquire lock with flock
	eval "exec ${MERGEN_LOCK_FD}>${MERGEN_LOCK}"
	if ! flock -w "$timeout" "$MERGEN_LOCK_FD" 2>/dev/null; then
		mergen_log "error" "Core" "Failed to acquire lock within ${timeout}s"
		return 1
	fi
	return 0
}

mergen_lock_release() {
	flock -u "$MERGEN_LOCK_FD" 2>/dev/null
	eval "exec ${MERGEN_LOCK_FD}>&-" 2>/dev/null
	rm -f "$MERGEN_LOCK"
}

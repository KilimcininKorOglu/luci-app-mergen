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

	# Output errors and warnings to stderr for CLI visibility
	# In daemon mode, stderr goes to /dev/null; in CLI mode, it reaches the terminal
	case "$level" in
		error|warning) echo "$message" >&2 ;;
	esac
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

# Get a list-type UCI option (returns newline-separated values)
# Usage: mergen_uci_get_list "section" "option"
# Result stored in MERGEN_UCI_LIST_RESULT (newline-separated)
MERGEN_UCI_LIST_RESULT=""

mergen_uci_get_list() {
	local section="$1" option="$2"
	MERGEN_UCI_LIST_RESULT="$(uci -q get "${MERGEN_CONF}.${section}.${option}" 2>/dev/null)"
}

# Add a value to a list-type UCI option
mergen_uci_add_list() {
	local section="$1" option="$2" value="$3"
	uci add_list "${MERGEN_CONF}.${section}.${option}=${value}" 2>/dev/null
}

# Delete a value from a list-type UCI option
mergen_uci_del_list() {
	local section="$1" option="$2" value="$3"
	uci del_list "${MERGEN_CONF}.${section}.${option}=${value}" 2>/dev/null
}

# ── Rule Iteration ───────────────────────────────────────

# List all rule section identifiers (UCI anonymous section names)
# Calls callback function for each rule: callback <section_id>
# Usage: mergen_list_rules callback_fn
mergen_list_rules() {
	local callback="$1"
	local section_id

	config_load "$MERGEN_CONF"
	config_foreach "$callback" "rule"
}

# Get a rule by its name option
# Returns the UCI section identifier in MERGEN_UCI_RESULT
# Returns 0 if found, 1 if not found
mergen_find_rule_by_name() {
	local target_name="$1"
	MERGEN_UCI_RESULT=""

	_mergen_find_rule_cb() {
		local section="$1"
		local name
		config_get name "$section" "name" ""
		if [ "$name" = "$target_name" ]; then
			MERGEN_UCI_RESULT="$section"
		fi
	}

	config_load "$MERGEN_CONF"
	config_foreach _mergen_find_rule_cb "rule"

	[ -n "$MERGEN_UCI_RESULT" ] && return 0
	return 1
}

# Count total rules
mergen_count_rules() {
	local count=0

	_mergen_count_rule_cb() {
		count=$((count + 1))
	}

	config_load "$MERGEN_CONF"
	config_foreach _mergen_count_rule_cb "rule"

	echo "$count"
}

# Count rules filtered by enabled status
# Usage: mergen_count_rules_enabled "1" (active) or "0" (inactive)
mergen_count_rules_enabled() {
	local filter="$1"
	local count=0

	_mergen_count_enabled_cb() {
		local section="$1"
		local enabled
		config_get enabled "$section" "enabled" "1"
		[ "$enabled" = "$filter" ] && count=$((count + 1))
	}

	config_load "$MERGEN_CONF"
	config_foreach _mergen_count_enabled_cb "rule"

	echo "$count"
}

# ── Provider Iteration ───────────────────────────────────

# List active providers sorted by priority (lowest first)
# Calls callback function for each enabled provider: callback <section_id>
# Usage: mergen_list_providers callback_fn
mergen_list_providers() {
	local callback="$1"

	# Collect enabled providers with their priorities
	local provider_list=""

	_mergen_collect_providers_cb() {
		local section="$1"
		local enabled priority
		config_get enabled "$section" "enabled" "0"
		[ "$enabled" = "1" ] || return 0
		config_get priority "$section" "priority" "99"
		provider_list="${provider_list}${priority}:${section}
"
	}

	config_load "$MERGEN_CONF"
	config_foreach _mergen_collect_providers_cb "provider"

	# Sort by priority and call callback
	# NOTE: Here-document is used instead of pipe to avoid subshell.
	# A piped while loop (echo | while) runs in a subshell, which means
	# variable changes inside the callback would be lost.
	local _sorted_providers
	_sorted_providers="$(echo "$provider_list" | sort -t: -k1 -n)"

	local _prio _section_id
	while IFS=: read -r _prio _section_id; do
		[ -z "$_section_id" ] && continue
		"$callback" "$_section_id"
	done <<EOF
$_sorted_providers
EOF
}

# Get provider details into variables
# Usage: mergen_get_provider "ripe"
# Sets: MERGEN_PROVIDER_ENABLED, MERGEN_PROVIDER_PRIORITY, MERGEN_PROVIDER_URL, MERGEN_PROVIDER_TIMEOUT
mergen_get_provider() {
	local section="$1"
	config_load "$MERGEN_CONF"
	config_get MERGEN_PROVIDER_ENABLED "$section" "enabled" "0"
	config_get MERGEN_PROVIDER_PRIORITY "$section" "priority" "99"
	config_get MERGEN_PROVIDER_URL "$section" "api_url" ""
	config_get MERGEN_PROVIDER_TIMEOUT "$section" "timeout" "30"
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

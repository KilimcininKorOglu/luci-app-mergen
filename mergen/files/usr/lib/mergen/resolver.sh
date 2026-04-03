#!/bin/sh
# Mergen ASN Resolver
# Provider plugin orchestration, prefix resolution, and caching

# Source core.sh if not already loaded (allows test override)
if ! type mergen_log >/dev/null 2>&1; then
	. /usr/lib/mergen/core.sh
fi

MERGEN_PROVIDERS_DIR="/etc/mergen/providers"
MERGEN_CACHE_DIR=""
MERGEN_RESOLVE_RESULT_V4=""
MERGEN_RESOLVE_RESULT_V6=""
MERGEN_RESOLVE_PROVIDER=""
MERGEN_RESOLVE_COUNT_V4=0
MERGEN_RESOLVE_COUNT_V6=0

# ── Initialization ───────────────────────────────────────

# Initialize resolver — called once at startup or before resolve operations
mergen_resolver_init() {
	mergen_uci_get "global" "cache_dir" "/tmp/mergen/cache"
	MERGEN_CACHE_DIR="$MERGEN_UCI_RESULT"
	[ -d "$MERGEN_CACHE_DIR" ] || mkdir -p "$MERGEN_CACHE_DIR"
}

# ── Provider Plugin Interface ────────────────────────────
#
# Each provider plugin in /etc/mergen/providers/<name>.sh MUST implement:
#
#   provider_name()          — echo the provider display name
#   provider_resolve <asn>   — resolve ASN to prefix list
#                              write IPv4 CIDRs to stdout (one per line)
#                              write IPv6 CIDRs to fd 3 if available
#                              return 0 on success, 1 on error
#   provider_test()          — connectivity test
#                              return 0 if reachable, 1 if not
#
# The resolver loads and unloads plugins dynamically. Each plugin
# is sourced in a subshell to prevent namespace pollution.

# ── Plugin Loading ───────────────────────────────────────

# Check if a provider plugin file exists
mergen_provider_exists() {
	local name="$1"
	[ -f "${MERGEN_PROVIDERS_DIR}/${name}.sh" ]
}

# Load a provider plugin and call a function
# Usage: _mergen_provider_call <provider_name> <function> [args...]
# Runs in a subshell to isolate plugin state
_mergen_provider_call() {
	local prov_name="$1"
	local func="$2"
	shift 2

	local plugin_file="${MERGEN_PROVIDERS_DIR}/${prov_name}.sh"

	if [ ! -f "$plugin_file" ]; then
		mergen_log "error" "Resolver" "Provider plugin not found: ${plugin_file}"
		return 1
	fi

	# Source plugin and call function in subshell
	(
		. "$plugin_file"
		if type "$func" >/dev/null 2>&1; then
			"$func" "$@"
		else
			mergen_log "error" "Resolver" "Provider '${prov_name}' does not implement ${func}()"
			return 1
		fi
	)
}

# ── Cache Layer ──────────────────────────────────────────

# Check if a cached result exists and is still valid
# Usage: _mergen_cache_check <asn>
# Returns 0 if cache hit (results loaded), 1 if cache miss
_mergen_cache_check() {
	local asn="$1"
	local cache_v4="${MERGEN_CACHE_DIR}/AS${asn}.v4.txt"
	local cache_v6="${MERGEN_CACHE_DIR}/AS${asn}.v6.txt"
	local cache_meta="${MERGEN_CACHE_DIR}/AS${asn}.meta"

	# Check if cache files exist
	[ -f "$cache_meta" ] || return 1
	[ -f "$cache_v4" ] || return 1

	# Read TTL from UCI
	mergen_uci_get "global" "update_interval" "86400"
	local ttl="$MERGEN_UCI_RESULT"

	# Read cache timestamp
	local cache_ts=""
	local cache_provider=""
	while IFS='=' read -r key value; do
		case "$key" in
			timestamp) cache_ts="$value" ;;
			provider) cache_provider="$value" ;;
		esac
	done < "$cache_meta"

	[ -z "$cache_ts" ] && return 1

	# Check TTL expiry
	local now
	now="$(date +%s)"
	local age=$((now - cache_ts))

	if [ "$age" -ge "$ttl" ]; then
		mergen_log "debug" "Cache" "ASN ${asn} cache expired (age: ${age}s, ttl: ${ttl}s)"
		return 1
	fi

	# Cache hit — load results
	MERGEN_RESOLVE_RESULT_V4="$(cat "$cache_v4" 2>/dev/null)"
	MERGEN_RESOLVE_RESULT_V6=""
	[ -f "$cache_v6" ] && MERGEN_RESOLVE_RESULT_V6="$(cat "$cache_v6" 2>/dev/null)"
	MERGEN_RESOLVE_PROVIDER="${cache_provider:-cache}"

	# Count prefixes
	MERGEN_RESOLVE_COUNT_V4=0
	MERGEN_RESOLVE_COUNT_V6=0
	if [ -n "$MERGEN_RESOLVE_RESULT_V4" ]; then
		MERGEN_RESOLVE_COUNT_V4="$(echo "$MERGEN_RESOLVE_RESULT_V4" | wc -l | tr -d ' ')"
	fi
	if [ -n "$MERGEN_RESOLVE_RESULT_V6" ]; then
		MERGEN_RESOLVE_COUNT_V6="$(echo "$MERGEN_RESOLVE_RESULT_V6" | wc -l | tr -d ' ')"
	fi

	mergen_log "info" "Cache" "ASN ${asn}: cache hit (${MERGEN_RESOLVE_COUNT_V4} v4, ${MERGEN_RESOLVE_COUNT_V6} v6, age: ${age}s)"
	return 0
}

# Write resolved results to cache
# Usage: _mergen_cache_write <asn>
_mergen_cache_write() {
	local asn="$1"
	local cache_v4="${MERGEN_CACHE_DIR}/AS${asn}.v4.txt"
	local cache_v6="${MERGEN_CACHE_DIR}/AS${asn}.v6.txt"
	local cache_meta="${MERGEN_CACHE_DIR}/AS${asn}.meta"

	[ -d "$MERGEN_CACHE_DIR" ] || mkdir -p "$MERGEN_CACHE_DIR"

	# Write prefix files
	if [ -n "$MERGEN_RESOLVE_RESULT_V4" ]; then
		echo "$MERGEN_RESOLVE_RESULT_V4" > "$cache_v4"
	else
		: > "$cache_v4"
	fi

	if [ -n "$MERGEN_RESOLVE_RESULT_V6" ]; then
		echo "$MERGEN_RESOLVE_RESULT_V6" > "$cache_v6"
	else
		rm -f "$cache_v6"
	fi

	# Write metadata
	cat > "$cache_meta" <<METAEOF
timestamp=$(date +%s)
provider=${MERGEN_RESOLVE_PROVIDER}
ttl=${MERGEN_UCI_RESULT:-86400}
METAEOF

	mergen_log "debug" "Cache" "ASN ${asn} cached (provider: ${MERGEN_RESOLVE_PROVIDER})"
}

# Clear all cached prefix data
mergen_cache_clear() {
	mergen_resolver_init

	if [ -d "$MERGEN_CACHE_DIR" ]; then
		rm -f "${MERGEN_CACHE_DIR}"/AS*.v4.txt
		rm -f "${MERGEN_CACHE_DIR}"/AS*.v6.txt
		rm -f "${MERGEN_CACHE_DIR}"/AS*.meta
		mergen_log "info" "Cache" "Önbellek temizlendi"
	fi
}

# Get cache statistics
# Outputs: total cached ASNs, total size
mergen_cache_stats() {
	mergen_resolver_init

	local count=0
	local total_size=0

	if [ -d "$MERGEN_CACHE_DIR" ]; then
		count="$(ls -1 "${MERGEN_CACHE_DIR}"/AS*.meta 2>/dev/null | wc -l | tr -d ' ')"

		# Calculate total cache size in bytes
		if [ "$count" -gt 0 ]; then
			total_size="$(du -sb "$MERGEN_CACHE_DIR" 2>/dev/null | cut -f1)"
			[ -z "$total_size" ] && total_size="$(du -sk "$MERGEN_CACHE_DIR" 2>/dev/null | cut -f1)"
		fi
	fi

	printf "Önbellekte %s ASN, toplam boyut: %s bayt\n" "$count" "${total_size:-0}"
}

# ── Resolve ASN ──────────────────────────────────────────

# Resolve an ASN number to prefix lists using the provider chain
# Tries cache first, then providers in priority order
# Results stored in MERGEN_RESOLVE_RESULT_V4, MERGEN_RESOLVE_RESULT_V6
# Returns 0 on success, 1 if all providers failed
mergen_resolve_asn() {
	local asn="$1"
	local force_provider="$2"

	MERGEN_RESOLVE_RESULT_V4=""
	MERGEN_RESOLVE_RESULT_V6=""
	MERGEN_RESOLVE_PROVIDER=""
	MERGEN_RESOLVE_COUNT_V4=0
	MERGEN_RESOLVE_COUNT_V6=0

	mergen_resolver_init

	# Strip AS prefix if present
	case "$asn" in
		AS*|as*) asn="${asn#[Aa][Ss]}" ;;
	esac

	mergen_log "debug" "Resolver" "Resolving ASN ${asn}"

	# Check cache first (unless force_provider is specified)
	if [ -z "$force_provider" ] && _mergen_cache_check "$asn"; then
		return 0
	fi

	# If a specific provider is forced, use only that one
	if [ -n "$force_provider" ]; then
		if _mergen_try_provider "$force_provider" "$asn"; then
			_mergen_cache_write "$asn"
			return 0
		fi
		return 1
	fi

	# Try providers in priority order
	local resolved=1

	_resolve_try_cb() {
		local section="$1"
		# Skip if already resolved
		[ "$resolved" -eq 0 ] && return 0

		if mergen_provider_exists "$section"; then
			if _mergen_try_provider "$section" "$asn"; then
				resolved=0
			fi
		else
			mergen_log "warning" "Resolver" "Provider '${section}' enabled but plugin file missing"
		fi
	}

	mergen_list_providers _resolve_try_cb

	if [ "$resolved" -ne 0 ]; then
		mergen_log "error" "Resolver" "All providers failed for ASN ${asn}"
		return 1
	fi

	# Write successful result to cache
	_mergen_cache_write "$asn"

	return 0
}

# Try a single provider for ASN resolution
# Returns 0 on success, 1 on failure
_mergen_try_provider() {
	local prov_name="$1"
	local asn="$2"
	local tmpfile_v4 tmpfile_v6

	mergen_log "info" "Resolver" "Trying provider '${prov_name}' for ASN ${asn}"

	tmpfile_v4="${MERGEN_CACHE_DIR}/.resolve_v4.tmp"
	tmpfile_v6="${MERGEN_CACHE_DIR}/.resolve_v6.tmp"

	# Get provider config
	mergen_get_provider "$prov_name"

	# Call provider_resolve, capture v4 on stdout, v6 on fd 3
	if _mergen_provider_call "$prov_name" "provider_resolve" "$asn" \
		>"$tmpfile_v4" 3>"$tmpfile_v6"; then

		MERGEN_RESOLVE_RESULT_V4="$(cat "$tmpfile_v4" 2>/dev/null)"
		MERGEN_RESOLVE_RESULT_V6="$(cat "$tmpfile_v6" 2>/dev/null)"
		MERGEN_RESOLVE_PROVIDER="$prov_name"

		# Count prefixes
		if [ -n "$MERGEN_RESOLVE_RESULT_V4" ]; then
			MERGEN_RESOLVE_COUNT_V4="$(echo "$MERGEN_RESOLVE_RESULT_V4" | wc -l | tr -d ' ')"
		fi
		if [ -n "$MERGEN_RESOLVE_RESULT_V6" ]; then
			MERGEN_RESOLVE_COUNT_V6="$(echo "$MERGEN_RESOLVE_RESULT_V6" | wc -l | tr -d ' ')"
		fi

		mergen_log "info" "Resolver" "ASN ${asn}: ${MERGEN_RESOLVE_COUNT_V4} IPv4, ${MERGEN_RESOLVE_COUNT_V6} IPv6 prefixes from ${prov_name}"

		rm -f "$tmpfile_v4" "$tmpfile_v6"
		return 0
	else
		mergen_log "warning" "Resolver" "Provider '${prov_name}' failed for ASN ${asn}"
		rm -f "$tmpfile_v4" "$tmpfile_v6"
		return 1
	fi
}

# ── Provider Testing ─────────────────────────────────────

# Test connectivity to a specific provider
# Returns 0 if provider is reachable, 1 if not
mergen_provider_test() {
	local prov_name="$1"

	if ! mergen_provider_exists "$prov_name"; then
		mergen_log "error" "Resolver" "Provider '${prov_name}' plugin not found"
		return 1
	fi

	_mergen_provider_call "$prov_name" "provider_test"
}

# Test all enabled providers
# Outputs: provider_name status (OK/FAIL)
mergen_provider_test_all() {
	_test_all_cb() {
		local section="$1"
		if mergen_provider_exists "$section"; then
			if mergen_provider_test "$section"; then
				printf "  %-15s OK\n" "$section"
			else
				printf "  %-15s FAIL\n" "$section"
			fi
		else
			printf "  %-15s MISSING\n" "$section"
		fi
	}

	mergen_list_providers _test_all_cb
}

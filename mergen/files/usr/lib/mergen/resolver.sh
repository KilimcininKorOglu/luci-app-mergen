#!/bin/sh
# Mergen ASN Resolver
# Provider plugin orchestration, prefix resolution, caching,
# fallback strategies, and provider health monitoring

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

# Health tracking state
MERGEN_HEALTH_DIR=""
MERGEN_HEALTH_SUCCESS=0
MERGEN_HEALTH_FAILURE=0
MERGEN_HEALTH_AVG_MS=0
MERGEN_HEALTH_LAST_SUCCESS=0
MERGEN_HEALTH_LAST_FAILURE=0

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

# ── Health Tracking ─────────────────────────────────────

# Initialize health tracking directory
_mergen_health_init() {
	if [ -z "$MERGEN_HEALTH_DIR" ]; then
		MERGEN_HEALTH_DIR="${MERGEN_TMP:-/tmp/mergen}/health"
	fi
	[ -d "$MERGEN_HEALTH_DIR" ] || mkdir -p "$MERGEN_HEALTH_DIR"
}

# Record a provider result (success or failure)
# Usage: _mergen_health_record <provider> <success|failure> <duration_ms>
_mergen_health_record() {
	local prov="$1" result="$2" duration_ms="${3:-0}"
	_mergen_health_init

	local health_file="${MERGEN_HEALTH_DIR}/${prov}.dat"
	local success=0 failure=0 last_success=0 last_failure=0 total_ms=0 queries=0

	# Read existing data
	if [ -f "$health_file" ]; then
		while IFS='=' read -r key value; do
			case "$key" in
				success_count) success="$value" ;;
				failure_count) failure="$value" ;;
				last_success) last_success="$value" ;;
				last_failure) last_failure="$value" ;;
				total_response_ms) total_ms="$value" ;;
				query_count) queries="$value" ;;
			esac
		done < "$health_file"
	fi

	local now
	now="$(date +%s)"
	queries=$((queries + 1))
	total_ms=$((total_ms + duration_ms))

	case "$result" in
		success)
			success=$((success + 1))
			last_success="$now"
			;;
		failure)
			failure=$((failure + 1))
			last_failure="$now"
			;;
	esac

	# Write updated data
	cat > "$health_file" <<HEALTHEOF
success_count=${success}
failure_count=${failure}
last_success=${last_success}
last_failure=${last_failure}
total_response_ms=${total_ms}
query_count=${queries}
HEALTHEOF
}

# Get health stats for a provider
# Sets: MERGEN_HEALTH_SUCCESS, MERGEN_HEALTH_FAILURE, MERGEN_HEALTH_AVG_MS,
#       MERGEN_HEALTH_LAST_SUCCESS, MERGEN_HEALTH_LAST_FAILURE
_mergen_health_get() {
	local prov="$1"
	_mergen_health_init

	MERGEN_HEALTH_SUCCESS=0
	MERGEN_HEALTH_FAILURE=0
	MERGEN_HEALTH_AVG_MS=0
	MERGEN_HEALTH_LAST_SUCCESS=0
	MERGEN_HEALTH_LAST_FAILURE=0

	local health_file="${MERGEN_HEALTH_DIR}/${prov}.dat"
	[ -f "$health_file" ] || return 1

	local total_ms=0 queries=0
	while IFS='=' read -r key value; do
		case "$key" in
			success_count) MERGEN_HEALTH_SUCCESS="$value" ;;
			failure_count) MERGEN_HEALTH_FAILURE="$value" ;;
			last_success) MERGEN_HEALTH_LAST_SUCCESS="$value" ;;
			last_failure) MERGEN_HEALTH_LAST_FAILURE="$value" ;;
			total_response_ms) total_ms="$value" ;;
			query_count) queries="$value" ;;
		esac
	done < "$health_file"

	if [ "$queries" -gt 0 ]; then
		MERGEN_HEALTH_AVG_MS=$((total_ms / queries))
	fi

	return 0
}

# Display health status table for all providers
mergen_health_status() {
	_mergen_health_init

	printf "  %-15s %-8s %-8s %-10s\n" "Provider" "Basari" "Hata" "Ort. ms"
	printf "  %-15s %-8s %-8s %-10s\n" "--------" "------" "----" "-------"

	_health_status_cb() {
		local section="$1"
		if _mergen_health_get "$section"; then
			printf "  %-15s %-8s %-8s %-10s\n" \
				"$section" "$MERGEN_HEALTH_SUCCESS" "$MERGEN_HEALTH_FAILURE" "${MERGEN_HEALTH_AVG_MS}ms"
		else
			printf "  %-15s %-8s %-8s %-10s\n" "$section" "-" "-" "-"
		fi
	}

	mergen_list_providers _health_status_cb
}

# Clear all health tracking data
mergen_health_clear() {
	_mergen_health_init
	if [ -d "$MERGEN_HEALTH_DIR" ]; then
		rm -f "${MERGEN_HEALTH_DIR}"/*.dat
		mergen_log "info" "Health" "Saglik verileri temizlendi"
	fi
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

# Check for stale (expired) cache — used as last resort when all providers fail
# Returns 0 if stale cache found and loaded, 1 if no cache at all
_mergen_cache_check_stale() {
	local asn="$1"
	local cache_v4="${MERGEN_CACHE_DIR}/AS${asn}.v4.txt"
	local cache_v6="${MERGEN_CACHE_DIR}/AS${asn}.v6.txt"
	local cache_meta="${MERGEN_CACHE_DIR}/AS${asn}.meta"

	[ -f "$cache_v4" ] || return 1
	[ -f "$cache_meta" ] || return 1

	# Check v4 file is non-empty
	[ -s "$cache_v4" ] || return 1

	MERGEN_RESOLVE_RESULT_V4="$(cat "$cache_v4" 2>/dev/null)"
	MERGEN_RESOLVE_RESULT_V6=""
	[ -f "$cache_v6" ] && MERGEN_RESOLVE_RESULT_V6="$(cat "$cache_v6" 2>/dev/null)"
	MERGEN_RESOLVE_PROVIDER="cache(stale)"

	MERGEN_RESOLVE_COUNT_V4=0
	MERGEN_RESOLVE_COUNT_V6=0
	if [ -n "$MERGEN_RESOLVE_RESULT_V4" ]; then
		MERGEN_RESOLVE_COUNT_V4="$(echo "$MERGEN_RESOLVE_RESULT_V4" | wc -l | tr -d ' ')"
	fi
	if [ -n "$MERGEN_RESOLVE_RESULT_V6" ]; then
		MERGEN_RESOLVE_COUNT_V6="$(echo "$MERGEN_RESOLVE_RESULT_V6" | wc -l | tr -d ' ')"
	fi

	mergen_log "warning" "Resolver" "ASN ${asn}: stale cache kullaniliyor (${MERGEN_RESOLVE_COUNT_V4} v4, ${MERGEN_RESOLVE_COUNT_V6} v6)"
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
		mergen_log "info" "Cache" "Onbellek temizlendi"
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

	printf "Onbellekte %s ASN, toplam boyut: %s bayt\n" "$count" "${total_size:-0}"
}

# ── Resolve ASN ──────────────────────────────────────────

# Resolve an ASN number to prefix lists using the provider chain
# Supports three fallback strategies: sequential, parallel, cache_only
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

	# Get fallback strategy from UCI
	mergen_uci_get "global" "fallback_strategy" "sequential"
	local strategy="$MERGEN_UCI_RESULT"

	case "$strategy" in
		cache_only)
			# Already checked fresh cache above — try stale cache
			mergen_log "warning" "Resolver" "Cache-only modu: ASN ${asn} icin taze cache bulunamadi"
			if _mergen_cache_check_stale "$asn"; then
				return 0
			fi
			return 1
			;;
		parallel)
			_mergen_resolve_parallel "$asn"
			return $?
			;;
		*)
			# sequential (default)
			_mergen_resolve_sequential "$asn"
			return $?
			;;
	esac
}

# ── Sequential Strategy ─────────────────────────────────

# Try providers one by one in priority order, stop at first success
# Falls back to stale cache if all providers fail
_mergen_resolve_sequential() {
	local asn="$1"
	local resolved=1

	_resolve_seq_cb() {
		local section="$1"
		# Skip if already resolved
		[ "$resolved" -eq 0 ] && return 0

		if mergen_provider_exists "$section"; then
			if _mergen_try_provider "$section" "$asn"; then
				resolved=0
			fi
		else
			mergen_log "warning" "Resolver" "Provider '${section}' aktif ama plugin dosyasi eksik"
		fi
	}

	mergen_list_providers _resolve_seq_cb

	if [ "$resolved" -ne 0 ]; then
		# Try stale cache as last resort
		if _mergen_cache_check_stale "$asn"; then
			return 0
		fi
		mergen_log "error" "Resolver" "Tum providerlar basarisiz: ASN ${asn}"
		return 1
	fi

	# Write successful result to cache
	_mergen_cache_write "$asn"
	return 0
}

# ── Parallel Strategy ────────────────────────────────────

# Launch all providers simultaneously, collect results, pick highest priority
# Falls back to stale cache if all providers fail
_mergen_resolve_parallel() {
	local asn="$1"
	local parallel_dir="${MERGEN_CACHE_DIR}/.parallel_$$"
	mkdir -p "$parallel_dir"

	local pids=""

	_parallel_launch_cb() {
		local section="$1"
		if mergen_provider_exists "$section"; then
			(
				local start_ts end_ts duration_ms
				start_ts="$(date +%s)"

				# Load provider config (in subshell — isolated)
				mergen_get_provider "$section"

				# HTTPS enforcement
				if [ -n "$MERGEN_PROVIDER_URL" ]; then
					if type validate_url_https >/dev/null 2>&1; then
						if ! validate_url_https "$MERGEN_PROVIDER_URL" 2>/dev/null; then
							echo "failure" > "${parallel_dir}/${section}.status"
							echo "0" > "${parallel_dir}/${section}.duration"
							exit 1
						fi
					fi
				fi

				if _mergen_provider_call "$section" "provider_resolve" "$asn" \
					>"${parallel_dir}/${section}.v4" 3>"${parallel_dir}/${section}.v6" 2>/dev/null; then
					end_ts="$(date +%s)"
					duration_ms=$(( (end_ts - start_ts) * 1000 ))
					echo "success" > "${parallel_dir}/${section}.status"
					echo "$duration_ms" > "${parallel_dir}/${section}.duration"
				else
					end_ts="$(date +%s)"
					duration_ms=$(( (end_ts - start_ts) * 1000 ))
					echo "failure" > "${parallel_dir}/${section}.status"
					echo "$duration_ms" > "${parallel_dir}/${section}.duration"
				fi
			) &
			pids="$pids $!"
		fi
	}

	mergen_list_providers _parallel_launch_cb

	# Wait for all background processes to complete
	local pid
	for pid in $pids; do
		wait "$pid" 2>/dev/null
	done

	# Collect results — pick highest priority (lowest number) successful provider
	local resolved=1

	_parallel_collect_cb() {
		local section="$1"
		[ "$resolved" -eq 0 ] && return 0

		local duration_ms=0
		[ -f "${parallel_dir}/${section}.duration" ] && duration_ms="$(cat "${parallel_dir}/${section}.duration")"

		if [ -f "${parallel_dir}/${section}.status" ] && \
			[ "$(cat "${parallel_dir}/${section}.status")" = "success" ]; then
			MERGEN_RESOLVE_RESULT_V4="$(cat "${parallel_dir}/${section}.v4" 2>/dev/null)"
			MERGEN_RESOLVE_RESULT_V6="$(cat "${parallel_dir}/${section}.v6" 2>/dev/null)"
			MERGEN_RESOLVE_PROVIDER="$section"

			MERGEN_RESOLVE_COUNT_V4=0
			MERGEN_RESOLVE_COUNT_V6=0
			if [ -n "$MERGEN_RESOLVE_RESULT_V4" ]; then
				MERGEN_RESOLVE_COUNT_V4="$(echo "$MERGEN_RESOLVE_RESULT_V4" | wc -l | tr -d ' ')"
			fi
			if [ -n "$MERGEN_RESOLVE_RESULT_V6" ]; then
				MERGEN_RESOLVE_COUNT_V6="$(echo "$MERGEN_RESOLVE_RESULT_V6" | wc -l | tr -d ' ')"
			fi

			mergen_log "info" "Resolver" \
				"ASN ${asn}: ${MERGEN_RESOLVE_COUNT_V4} IPv4, ${MERGEN_RESOLVE_COUNT_V6} IPv6 from ${section} (parallel, ${duration_ms}ms)"
			_mergen_health_record "$section" "success" "$duration_ms"
			resolved=0
		else
			_mergen_health_record "$section" "failure" "$duration_ms"
		fi
	}

	mergen_list_providers _parallel_collect_cb

	rm -rf "$parallel_dir"

	if [ "$resolved" -ne 0 ]; then
		# Try stale cache as last resort
		if _mergen_cache_check_stale "$asn"; then
			return 0
		fi
		mergen_log "error" "Resolver" "Tum providerlar basarisiz: ASN ${asn} (parallel)"
		return 1
	fi

	_mergen_cache_write "$asn"
	return 0
}

# ── Provider Try ─────────────────────────────────────────

# Try a single provider for ASN resolution
# Records health metrics (timing, success/failure)
# Returns 0 on success, 1 on failure
_mergen_try_provider() {
	local prov_name="$1"
	local asn="$2"
	local tmpfile_v4 tmpfile_v6
	local start_ts end_ts duration_ms

	mergen_log "info" "Resolver" "Trying provider '${prov_name}' for ASN ${asn}"

	tmpfile_v4="${MERGEN_CACHE_DIR}/.resolve_v4.tmp"
	tmpfile_v6="${MERGEN_CACHE_DIR}/.resolve_v6.tmp"

	# Get provider config
	mergen_get_provider "$prov_name"

	# Enforce HTTPS on provider URL
	if [ -n "$MERGEN_PROVIDER_URL" ]; then
		if type validate_url_https >/dev/null 2>&1; then
			if ! validate_url_https "$MERGEN_PROVIDER_URL"; then
				mergen_log "error" "Resolver" "$MERGEN_VALIDATE_ERR"
				_mergen_health_record "$prov_name" "failure" 0
				return 1
			fi
		fi
	fi

	start_ts="$(date +%s)"

	# Call provider_resolve, capture v4 on stdout, v6 on fd 3
	if _mergen_provider_call "$prov_name" "provider_resolve" "$asn" \
		>"$tmpfile_v4" 3>"$tmpfile_v6"; then

		end_ts="$(date +%s)"
		duration_ms=$(( (end_ts - start_ts) * 1000 ))

		MERGEN_RESOLVE_RESULT_V4="$(cat "$tmpfile_v4" 2>/dev/null)"
		MERGEN_RESOLVE_RESULT_V6="$(cat "$tmpfile_v6" 2>/dev/null)"
		MERGEN_RESOLVE_PROVIDER="$prov_name"

		# Count prefixes
		MERGEN_RESOLVE_COUNT_V4=0
		MERGEN_RESOLVE_COUNT_V6=0
		if [ -n "$MERGEN_RESOLVE_RESULT_V4" ]; then
			MERGEN_RESOLVE_COUNT_V4="$(echo "$MERGEN_RESOLVE_RESULT_V4" | wc -l | tr -d ' ')"
		fi
		if [ -n "$MERGEN_RESOLVE_RESULT_V6" ]; then
			MERGEN_RESOLVE_COUNT_V6="$(echo "$MERGEN_RESOLVE_RESULT_V6" | wc -l | tr -d ' ')"
		fi

		mergen_log "info" "Resolver" \
			"ASN ${asn}: ${MERGEN_RESOLVE_COUNT_V4} IPv4, ${MERGEN_RESOLVE_COUNT_V6} IPv6 from ${prov_name} (${duration_ms}ms)"

		_mergen_health_record "$prov_name" "success" "$duration_ms"

		rm -f "$tmpfile_v4" "$tmpfile_v6"
		return 0
	else
		end_ts="$(date +%s)"
		duration_ms=$(( (end_ts - start_ts) * 1000 ))

		mergen_log "warning" "Resolver" "Provider '${prov_name}' failed for ASN ${asn} (${duration_ms}ms)"
		_mergen_health_record "$prov_name" "failure" "$duration_ms"

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

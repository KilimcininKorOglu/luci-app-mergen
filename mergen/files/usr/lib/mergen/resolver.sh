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

# ── Country-Based Resolution ─────────────────────────────

MERGEN_COUNTRY_MAP_DIR="/tmp/mergen/country"
MERGEN_COUNTRY_PREFIXES_V4=""
MERGEN_COUNTRY_PREFIXES_V6=""
MERGEN_COUNTRY_ASN_COUNT=0

# Resolve a country code to prefix lists
# Uses delegated stats from RIR or MaxMind country-ASN mapping
# Usage: mergen_resolve_country <country_code>
# Sets: MERGEN_COUNTRY_PREFIXES_V4, MERGEN_COUNTRY_PREFIXES_V6, MERGEN_COUNTRY_ASN_COUNT
# Returns 0 on success, 1 on failure
mergen_resolve_country() {
	local country="$1"

	MERGEN_COUNTRY_PREFIXES_V4=""
	MERGEN_COUNTRY_PREFIXES_V6=""
	MERGEN_COUNTRY_ASN_COUNT=0

	# Uppercase
	country="$(echo "$country" | tr '[:lower:]' '[:upper:]')"

	if [ -z "$country" ]; then
		mergen_log "error" "Country" "[!] Hata: Ülke kodu belirtilmeli."
		return 1
	fi

	mergen_log "info" "Country" "Ülke çözümleniyor: ${country}"

	# Ensure cache directory exists
	[ -d "$MERGEN_COUNTRY_MAP_DIR" ] || mkdir -p "$MERGEN_COUNTRY_MAP_DIR"

	local country_asn_file="${MERGEN_COUNTRY_MAP_DIR}/${country}_asns.txt"
	local country_cache_file="${MERGEN_COUNTRY_MAP_DIR}/${country}_prefixes.cache"

	# Check if we have a cached result (TTL: 24 hours)
	if [ -f "$country_cache_file" ]; then
		local cache_age
		cache_age="$(( $(date +%s) - $(date -r "$country_cache_file" +%s 2>/dev/null || echo 0) ))"
		if [ "$cache_age" -lt 86400 ]; then
			mergen_log "debug" "Country" "Cache kullanılıyor: ${country}"
			MERGEN_COUNTRY_PREFIXES_V4="$(sed -n '/^#V4$/,/^#V6$/p' "$country_cache_file" | grep -v '^#')"
			MERGEN_COUNTRY_PREFIXES_V6="$(sed -n '/^#V6$/,/^#END$/p' "$country_cache_file" | grep -v '^#')"
			MERGEN_COUNTRY_ASN_COUNT="$(grep -c '^#ASN:' "$country_cache_file" 2>/dev/null || echo 0)"
			return 0
		fi
	fi

	# Step 1: Get ASN list for the country
	# Try RIR delegated stats first (RIPE NCC publishes delegated-extended)
	if ! _country_fetch_asn_list "$country" "$country_asn_file"; then
		mergen_log "error" "Country" "[!] Hata: '${country}' için ASN listesi alınamadı."
		return 1
	fi

	local asn_count
	asn_count="$(wc -l < "$country_asn_file" | tr -d ' ')"
	MERGEN_COUNTRY_ASN_COUNT="$asn_count"

	if [ "$asn_count" -eq 0 ]; then
		mergen_log "warning" "Country" "Ülke '${country}' için ASN bulunamadı."
		return 1
	fi

	mergen_log "info" "Country" "${country}: ${asn_count} ASN bulundu, prefix çözümleniyor..."

	# Prefix limit warning
	mergen_uci_get "global" "total_prefix_limit" "50000"
	local total_limit="$MERGEN_UCI_RESULT"
	if [ "$asn_count" -gt 100 ]; then
		mergen_log "warning" "Country" "Ülke '${country}' ${asn_count} ASN içeriyor — çok sayıda prefix oluşabilir."
	fi

	# Step 2: Resolve each ASN to prefixes
	local all_v4="" all_v6=""
	local resolved_count=0
	local asn_item

	mergen_resolver_init

	while IFS= read -r asn_item; do
		[ -z "$asn_item" ] && continue

		if mergen_resolve_asn "$asn_item"; then
			if [ -n "$MERGEN_RESOLVE_RESULT_V4" ]; then
				all_v4="${all_v4}
${MERGEN_RESOLVE_RESULT_V4}"
			fi
			if [ -n "$MERGEN_RESOLVE_RESULT_V6" ]; then
				all_v6="${all_v6}
${MERGEN_RESOLVE_RESULT_V6}"
			fi
			resolved_count=$((resolved_count + 1))
		fi

		# Safety: stop if we exceed the total prefix limit
		local current_count
		current_count="$(echo "$all_v4" | grep -c '.' 2>/dev/null || echo 0)"
		if [ "$current_count" -gt "$total_limit" ]; then
			mergen_log "warning" "Country" "Prefix limiti aşıldı (${current_count}/${total_limit}), erken durduruluyor."
			break
		fi
	done < "$country_asn_file"

	# Clean empty lines
	all_v4="$(echo "$all_v4" | sed '/^$/d')"
	all_v6="$(echo "$all_v6" | sed '/^$/d')"

	MERGEN_COUNTRY_PREFIXES_V4="$all_v4"
	MERGEN_COUNTRY_PREFIXES_V6="$all_v6"

	# Write cache
	{
		echo "#ASN_COUNT: ${asn_count}"
		echo "#RESOLVED: ${resolved_count}"
		local asn_line
		while IFS= read -r asn_line; do
			[ -n "$asn_line" ] && echo "#ASN: ${asn_line}"
		done < "$country_asn_file"
		echo "#V4"
		echo "$all_v4"
		echo "#V6"
		echo "$all_v6"
		echo "#END"
	} > "$country_cache_file"

	local v4_count v6_count
	v4_count="$(echo "$all_v4" | grep -c '.' 2>/dev/null || echo 0)"
	v6_count="$(echo "$all_v6" | grep -c '.' 2>/dev/null || echo 0)"

	mergen_log "info" "Country" "Ülke ${country}: ${resolved_count}/${asn_count} ASN çözümlendi (${v4_count} IPv4, ${v6_count} IPv6 prefix)"
	return 0
}

# Fetch ASN list for a country code from RIR delegated stats
# Uses RIPE NCC combined delegated-extended file
# Output: one ASN per line to the output file
_country_fetch_asn_list() {
	local country="$1"
	local output_file="$2"
	local delegated_file="${MERGEN_COUNTRY_MAP_DIR}/delegated-combined.txt"

	# Download delegated stats if not cached (TTL: 7 days)
	local need_download=1
	if [ -f "$delegated_file" ]; then
		local file_age
		file_age="$(( $(date +%s) - $(date -r "$delegated_file" +%s 2>/dev/null || echo 0) ))"
		[ "$file_age" -lt 604800 ] && need_download=0
	fi

	if [ "$need_download" -eq 1 ]; then
		mergen_log "info" "Country" "RIR delegated stats indiriliyor..."
		local url="https://ftp.ripe.net/pub/stats/ripencc/nro-stats/latest/nro-delegated-stats"
		if command -v wget >/dev/null 2>&1; then
			wget -q -O "$delegated_file" "$url" 2>/dev/null
		elif command -v curl >/dev/null 2>&1; then
			curl -sL -o "$delegated_file" "$url" 2>/dev/null
		else
			mergen_log "error" "Country" "wget veya curl bulunamadı"
			return 1
		fi

		if [ ! -s "$delegated_file" ]; then
			rm -f "$delegated_file"
			mergen_log "error" "Country" "Delegated stats indirilemedi"
			return 1
		fi
	fi

	# Extract ASN numbers for the country
	# Format: registry|CC|asn|ASN_START|COUNT|date|status
	grep "|${country}|asn|" "$delegated_file" 2>/dev/null | \
		awk -F'|' '{ print $4 }' | \
		sort -un > "$output_file"

	if [ ! -s "$output_file" ]; then
		mergen_log "warning" "Country" "Delegated stats'ta '${country}' için ASN bulunamadı"
		return 1
	fi

	return 0
}

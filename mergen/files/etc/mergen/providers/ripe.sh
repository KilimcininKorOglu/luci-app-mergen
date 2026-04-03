#!/bin/sh
# Mergen RIPE Stat Provider
# Fetches announced prefix lists from RIPE Stat API
#
# Provider interface:
#   provider_name()        — display name
#   provider_resolve <asn> — resolve ASN to prefixes (v4 on stdout, v6 on fd 3)
#   provider_test()        — connectivity test

# ── Provider Meta ───────────────────────────────────────

provider_name() {
	echo "RIPE Stat"
}

# ── Connectivity Test ───────────────────────────────────

# Test if RIPE Stat API is reachable
# Uses a lightweight status endpoint
provider_test() {
	local api_url timeout

	# Read config from UCI (set by resolver before calling)
	api_url="${MERGEN_PROVIDER_URL:-https://stat.ripe.net/data/announced-prefixes/data.json}"
	timeout="${MERGEN_PROVIDER_TIMEOUT:-10}"

	# Extract base URL for connectivity check
	local base_url
	base_url="$(echo "$api_url" | sed 's|/data/.*|/data/announced-prefixes/data.json?resource=AS13335|')"

	if _ripe_http_get "$base_url" "$timeout" >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

# ── ASN Resolution ──────────────────────────────────────

# Resolve an ASN to its announced prefix list
# IPv4 prefixes written to stdout, IPv6 to fd 3
# Returns 0 on success, 1 on error
provider_resolve() {
	local asn="$1"
	local api_url timeout response

	api_url="${MERGEN_PROVIDER_URL:-https://stat.ripe.net/data/announced-prefixes/data.json}"
	timeout="${MERGEN_PROVIDER_TIMEOUT:-30}"

	# Build request URL
	local request_url="${api_url}?resource=AS${asn}"

	mergen_log "debug" "RIPE" "Fetching: ${request_url}"

	# Fetch data
	response="$(_ripe_http_get "$request_url" "$timeout")"

	if [ -z "$response" ]; then
		mergen_log "error" "RIPE" "[!] RIPE API yanıt vermedi (timeout: ${timeout}s)"
		return 1
	fi

	# Check API status
	local status
	status="$(echo "$response" | jsonfilter -e '@.status' 2>/dev/null)"

	if [ "$status" != "ok" ]; then
		local message
		message="$(echo "$response" | jsonfilter -e '@.messages[0][1]' 2>/dev/null)"
		mergen_log "error" "RIPE" "[!] RIPE API hatası: ${message:-bilinmeyen hata}"
		return 1
	fi

	# Extract prefix list
	local prefixes
	prefixes="$(echo "$response" | jsonfilter -e '@.data.prefixes[*].prefix' 2>/dev/null)"

	if [ -z "$prefixes" ]; then
		mergen_log "warning" "RIPE" "ASN ${asn} için prefix bulunamadı"
		return 0
	fi

	# Separate IPv4 and IPv6
	local line
	echo "$prefixes" | while IFS= read -r line; do
		[ -z "$line" ] && continue
		case "$line" in
			*:*)
				# IPv6 prefix — write to fd 3
				echo "$line" >&3
				;;
			*)
				# IPv4 prefix — write to stdout
				echo "$line"
				;;
		esac
	done

	return 0
}

# ── HTTP Client ─────────────────────────────────────────

# HTTP GET with curl (primary) or wget (fallback)
# Usage: _ripe_http_get <url> <timeout>
# Returns response body on stdout
_ripe_http_get() {
	local url="$1"
	local timeout="$2"

	if command -v curl >/dev/null 2>&1; then
		curl -s --max-time "$timeout" \
			-H "Accept: application/json" \
			"$url" 2>/dev/null
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O - \
			--timeout="$timeout" \
			--header="Accept: application/json" \
			"$url" 2>/dev/null
	else
		mergen_log "error" "RIPE" "HTTP istemcisi bulunamadı (curl veya wget gerekli)"
		return 1
	fi
}

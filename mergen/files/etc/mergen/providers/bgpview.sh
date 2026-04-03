#!/bin/sh
# Mergen bgpview.io Provider
# Fetches announced prefix lists from BGPView API
# JSON format response with ipv4_prefixes and ipv6_prefixes arrays
#
# Rate limit: 30 requests/minute
#
# Provider interface:
#   provider_name()        — display name
#   provider_resolve <asn> — resolve ASN to prefixes (v4 on stdout, v6 on fd 3)
#   provider_test()        — connectivity test

# ── Provider Meta ───────────────────────────────────────

provider_name() {
	echo "BGPView"
}

# ── Connectivity Test ───────────────────────────────────

# Test if BGPView API is reachable
# Uses a lightweight ASN lookup (Cloudflare AS13335) for connectivity check
provider_test() {
	local api_url timeout

	api_url="${MERGEN_PROVIDER_URL:-https://api.bgpview.io}"
	timeout="${MERGEN_PROVIDER_TIMEOUT:-10}"

	local test_url="${api_url}/asn/13335"

	if _bgpview_http_get "$test_url" "$timeout" >/dev/null 2>&1; then
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

	api_url="${MERGEN_PROVIDER_URL:-https://api.bgpview.io}"
	timeout="${MERGEN_PROVIDER_TIMEOUT:-30}"

	# Build request URL
	local request_url="${api_url}/asn/${asn}/prefixes"

	mergen_log "debug" "BGPView" "Fetching: ${request_url}"

	# Fetch data
	response="$(_bgpview_http_get "$request_url" "$timeout")"

	if [ -z "$response" ]; then
		mergen_log "error" "BGPView" "[!] BGPView API yanit vermedi (timeout: ${timeout}s)"
		return 1
	fi

	# Check API status
	local status
	status="$(echo "$response" | jsonfilter -e '@.status' 2>/dev/null)"

	if [ "$status" != "ok" ]; then
		local message
		message="$(echo "$response" | jsonfilter -e '@.status_message' 2>/dev/null)"
		mergen_log "error" "BGPView" "[!] BGPView API hatasi: ${message:-bilinmeyen hata}"
		return 1
	fi

	# Extract IPv4 prefixes: data.ipv4_prefixes[*].prefix
	local v4_prefixes
	v4_prefixes="$(echo "$response" | jsonfilter -e '@.data.ipv4_prefixes[*].prefix' 2>/dev/null)"

	# Extract IPv6 prefixes: data.ipv6_prefixes[*].prefix
	local v6_prefixes
	v6_prefixes="$(echo "$response" | jsonfilter -e '@.data.ipv6_prefixes[*].prefix' 2>/dev/null)"

	# Output IPv4 to stdout
	if [ -n "$v4_prefixes" ]; then
		echo "$v4_prefixes" | while IFS= read -r line; do
			[ -z "$line" ] && continue
			echo "$line"
		done
	fi

	# Output IPv6 to fd 3
	if [ -n "$v6_prefixes" ]; then
		echo "$v6_prefixes" | while IFS= read -r line; do
			[ -z "$line" ] && continue
			echo "$line" >&3
		done
	fi

	return 0
}

# ── HTTP Client ─────────────────────────────────────────

# HTTP GET with curl (primary) or wget (fallback)
# Usage: _bgpview_http_get <url> <timeout>
# Returns response body on stdout
_bgpview_http_get() {
	local url="$1"
	local timeout="$2"

	# Enforce HTTPS — reject plain HTTP URLs
	case "$url" in
		https://*) ;;
		http://*)
			mergen_log "error" "BGPView" "HTTP reddedildi, HTTPS gerekli: ${url}"
			return 1
			;;
	esac

	if command -v curl >/dev/null 2>&1; then
		curl -s --proto '=https' --max-time "$timeout" \
			-H "Accept: application/json" \
			"$url" 2>/dev/null
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O - \
			--timeout="$timeout" \
			--header="Accept: application/json" \
			"$url" 2>/dev/null
	else
		mergen_log "error" "BGPView" "HTTP istemcisi bulunamadi (curl veya wget gerekli)"
		return 1
	fi
}

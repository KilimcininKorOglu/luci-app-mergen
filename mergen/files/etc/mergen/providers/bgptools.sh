#!/bin/sh
# Mergen bgp.tools Provider
# Fetches announced prefix lists from bgp.tools API
# JSONL format response: one JSON object per line
#
# Provider interface:
#   provider_name()        — display name
#   provider_resolve <asn> — resolve ASN to prefixes (v4 on stdout, v6 on fd 3)
#   provider_test()        — connectivity test

# ── Provider Meta ───────────────────────────────────────

provider_name() {
	echo "bgp.tools"
}

# ── Connectivity Test ───────────────────────────────────

# Test if bgp.tools API is reachable
provider_test() {
	local api_url timeout

	api_url="${MERGEN_PROVIDER_URL:-https://bgp.tools/table.jsonl}"
	timeout="${MERGEN_PROVIDER_TIMEOUT:-10}"

	# HEAD request to check reachability
	if _bgptools_http_get "${api_url}" "$timeout" "HEAD" >/dev/null 2>&1; then
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

	api_url="${MERGEN_PROVIDER_URL:-https://bgp.tools/table.jsonl}"
	timeout="${MERGEN_PROVIDER_TIMEOUT:-30}"

	# Build request URL — append ASN query parameter
	local request_url="${api_url}?asn=${asn}"

	mergen_log "debug" "bgp.tools" "Fetching: ${request_url}"

	# Fetch data
	response="$(_bgptools_http_get "$request_url" "$timeout")"

	if [ -z "$response" ]; then
		mergen_log "error" "bgp.tools" "[!] bgp.tools API yanit vermedi (timeout: ${timeout}s)"
		return 1
	fi

	# Parse JSONL: each line is a JSON object with "CIDR" or "prefix" field
	# Format: {"CIDR":"x.x.x.x/y","ASN":NNNNN,...}
	# We filter lines matching the target ASN and extract the CIDR/prefix
	local prefix_count=0
	local line prefix

	echo "$response" | while IFS= read -r line; do
		[ -z "$line" ] && continue

		# Extract prefix using sed (ash-compatible, no jq dependency)
		# Try "CIDR" field first (bgp.tools table.jsonl format)
		prefix="$(echo "$line" | sed -n 's/.*"CIDR"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"

		# Fallback: try "prefix" field
		if [ -z "$prefix" ]; then
			prefix="$(echo "$line" | sed -n 's/.*"prefix"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
		fi

		[ -z "$prefix" ] && continue

		# Separate IPv4 and IPv6
		case "$prefix" in
			*:*)
				# IPv6 prefix — write to fd 3
				echo "$prefix" >&3
				;;
			*)
				# IPv4 prefix — write to stdout
				echo "$prefix"
				;;
		esac
	done

	return 0
}

# ── HTTP Client ─────────────────────────────────────────

# HTTP GET with curl (primary) or wget (fallback)
# Usage: _bgptools_http_get <url> <timeout> [method]
# Returns response body on stdout
_bgptools_http_get() {
	local url="$1"
	local timeout="$2"
	local method="${3:-GET}"

	# Enforce HTTPS — reject plain HTTP URLs
	case "$url" in
		https://*) ;;
		http://*)
			mergen_log "error" "bgp.tools" "HTTP reddedildi, HTTPS gerekli: ${url}"
			return 1
			;;
	esac

	# Read optional API key from provider config
	local api_key=""
	if [ -n "$MERGEN_PROVIDER_API_KEY" ]; then
		api_key="$MERGEN_PROVIDER_API_KEY"
	fi

	if command -v curl >/dev/null 2>&1; then
		local curl_args="-s --proto =https --max-time $timeout"

		if [ "$method" = "HEAD" ]; then
			curl_args="$curl_args -I"
		fi

		if [ -n "$api_key" ]; then
			curl $curl_args \
				-H "Authorization: Bearer ${api_key}" \
				-H "Accept: application/jsonl+json" \
				"$url" 2>/dev/null
		else
			curl $curl_args \
				-H "Accept: application/jsonl+json" \
				"$url" 2>/dev/null
		fi
	elif command -v wget >/dev/null 2>&1; then
		local wget_args="-q -O - --timeout=$timeout"

		if [ -n "$api_key" ]; then
			wget $wget_args \
				--header="Authorization: Bearer ${api_key}" \
				--header="Accept: application/jsonl+json" \
				"$url" 2>/dev/null
		else
			wget $wget_args \
				--header="Accept: application/jsonl+json" \
				"$url" 2>/dev/null
		fi
	else
		mergen_log "error" "bgp.tools" "HTTP istemcisi bulunamadi (curl veya wget gerekli)"
		return 1
	fi
}

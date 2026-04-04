#!/bin/sh
# Mergen IRR/RADB Provider
# ASN resolution using RADB/IRR whois queries
# Queries: whois -h whois.radb.net -- -i origin AS{asn}
# Extracts route: and route6: lines for prefix list
#
# Provider interface:
#   provider_name()        — display name
#   provider_resolve <asn> — resolve ASN to prefixes (v4 on stdout, v6 on fd 3)
#   provider_test()        — connectivity test

# ── Provider Meta ───────────────────────────────────────

provider_name() {
	echo "IRR/RADB"
}

# ── Connectivity Test ───────────────────────────────────

# Test if RADB whois server is reachable
provider_test() {
	local server
	server="${MERGEN_PROVIDER_WHOIS_SERVER:-whois.radb.net}"

	# Quick whois test with a known ASN
	local result
	result="$(_irr_whois_query "$server" "AS13335" 2>/dev/null)"

	if [ -n "$result" ]; then
		return 0
	fi
	return 1
}

# ── ASN Resolution ──────────────────────────────────────

# Resolve an ASN to its announced prefix list from IRR/RADB
# IPv4 prefixes written to stdout, IPv6 to fd 3
# Returns 0 on success, 1 on error
provider_resolve() {
	local asn="$1"
	local server timeout

	server="${MERGEN_PROVIDER_WHOIS_SERVER:-whois.radb.net}"
	timeout="${MERGEN_PROVIDER_TIMEOUT:-30}"

	mergen_log "debug" "IRR" "RADB sorgusu: AS${asn} @ ${server}"

	# Query RADB for routes originated by this ASN
	local response
	response="$(_irr_whois_query "$server" "AS${asn}" "$timeout")"

	if [ -z "$response" ]; then
		mergen_log "error" "IRR" "[!] RADB sunucusu yanit vermedi (${server})"
		return 1
	fi

	# Extract route: and route6: lines
	# Format: "route:          x.x.x.x/y" or "route6:         xxxx::/y"
	local prefixes
	prefixes="$(echo "$response" | sed -n 's/^route6\{0,1\}:[[:space:]]*\([^ ]*\).*/\1/p')"

	if [ -z "$prefixes" ]; then
		mergen_log "warning" "IRR" "ASN ${asn} icin prefix bulunamadi"
		return 0
	fi

	# Separate IPv4 and IPv6
	echo "$prefixes" | while IFS= read -r line; do
		[ -z "$line" ] && continue
		case "$line" in
			*:*)
				echo "$line" >&3
				;;
			*)
				echo "$line"
				;;
		esac
	done

	return 0
}

# ── Whois Client ────────────────────────────────────────

# Execute a whois query for route objects originated by an ASN
# Usage: _irr_whois_query <server> <asn_with_prefix> [timeout]
# Returns whois response on stdout
_irr_whois_query() {
	local server="$1"
	local asn="$2"
	local timeout="${3:-30}"

	# Try native whois command first
	if command -v whois >/dev/null 2>&1; then
		whois -h "$server" -- "-i origin ${asn}" 2>/dev/null
		return $?
	fi

	# Fallback: use netcat for raw whois query
	if command -v nc >/dev/null 2>&1; then
		printf -- "-i origin %s\r\n" "$asn" | \
			nc -w "$timeout" "$server" 43 2>/dev/null
		return $?
	fi

	# Fallback: use busybox ncat or bash /dev/tcp
	if command -v ncat >/dev/null 2>&1; then
		printf -- "-i origin %s\r\n" "$asn" | \
			ncat -w "$timeout" "$server" 43 2>/dev/null
		return $?
	fi

	mergen_log "error" "IRR" "Whois istemcisi bulunamadi (whois veya nc gerekli)"
	return 1
}

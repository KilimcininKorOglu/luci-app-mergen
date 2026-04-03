#!/bin/sh
# Mergen RouteViews Provider
# ASN resolution from RouteViews MRT/RIB dump files
# Heavy/slow provider — intended as fallback for offline or bulk use
#
# Provider interface:
#   provider_name()        — display name
#   provider_resolve <asn> — resolve ASN to prefixes (v4 on stdout, v6 on fd 3)
#   provider_test()        — connectivity/availability test

# ── Provider Meta ───────────────────────────────────────

provider_name() {
	echo "RouteViews"
}

# ── Connectivity Test ───────────────────────────────────

# Test if RouteViews data is available (local dump or download endpoint)
provider_test() {
	local dump_path
	dump_path="${MERGEN_PROVIDER_DUMP_PATH:-/tmp/mergen/routeviews/rib.txt}"

	# If local parsed dump exists, provider is available
	if [ -f "$dump_path" ]; then
		return 0
	fi

	# Otherwise, check if download URL is reachable
	local api_url timeout
	api_url="${MERGEN_PROVIDER_URL:-https://routeviews.org/bgpdata/}"
	timeout="${MERGEN_PROVIDER_TIMEOUT:-10}"

	if _routeviews_http_check "$api_url" "$timeout"; then
		return 0
	fi

	return 1
}

# ── ASN Resolution ──────────────────────────────────────

# Resolve an ASN to its announced prefix list from RouteViews dump
# IPv4 prefixes written to stdout, IPv6 to fd 3
# Returns 0 on success, 1 on error
provider_resolve() {
	local asn="$1"
	local dump_path

	dump_path="${MERGEN_PROVIDER_DUMP_PATH:-/tmp/mergen/routeviews/rib.txt}"

	if [ ! -f "$dump_path" ]; then
		mergen_log "info" "RouteViews" "Yerel dump bulunamadi, indirme deneniyor..."
		if ! _routeviews_download_and_parse; then
			mergen_log "error" "RouteViews" "[!] RouteViews dump alinamadi"
			return 1
		fi
	fi

	if [ ! -f "$dump_path" ]; then
		mergen_log "error" "RouteViews" "[!] RouteViews dump dosyasi mevcut degil: ${dump_path}"
		return 1
	fi

	mergen_log "debug" "RouteViews" "ASN ${asn} icin dump taranıyor..."

	# Parsed dump format: ASN|prefix (one per line, same as maxmind prefix map)
	local results
	results="$(grep "^${asn}|" "$dump_path" 2>/dev/null | cut -d'|' -f2)"

	if [ -z "$results" ]; then
		mergen_log "warning" "RouteViews" "ASN ${asn} icin prefix bulunamadi"
		return 0
	fi

	# Separate IPv4 and IPv6
	echo "$results" | while IFS= read -r line; do
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

# ── Download & Parse ────────────────────────────────────

# Download latest RouteViews RIB dump and parse to prefix map
# Uses streaming approach to avoid memory overflow
_routeviews_download_and_parse() {
	local api_url timeout dump_dir dump_path
	api_url="${MERGEN_PROVIDER_URL:-https://routeviews.org/bgpdata/}"
	timeout="${MERGEN_PROVIDER_TIMEOUT:-120}"
	dump_path="${MERGEN_PROVIDER_DUMP_PATH:-/tmp/mergen/routeviews/rib.txt}"
	dump_dir="$(dirname "$dump_path")"

	[ -d "$dump_dir" ] || mkdir -p "$dump_dir"

	local tmpfile="${dump_dir}/rib.raw.tmp"

	# Download RIB dump (text format — bgpdump pre-processed or direct text)
	mergen_log "info" "RouteViews" "RouteViews dump indiriliyor..."

	if command -v curl >/dev/null 2>&1; then
		curl -s --proto '=https' --max-time "$timeout" \
			-o "$tmpfile" "$api_url" 2>/dev/null
	elif command -v wget >/dev/null 2>&1; then
		wget -q --timeout="$timeout" \
			-O "$tmpfile" "$api_url" 2>/dev/null
	else
		mergen_log "error" "RouteViews" "HTTP istemcisi bulunamadi"
		return 1
	fi

	if [ ! -s "$tmpfile" ]; then
		rm -f "$tmpfile"
		mergen_log "error" "RouteViews" "Indirme basarisiz veya bos dosya"
		return 1
	fi

	# Parse: extract ASN|prefix pairs
	# Expected input format varies; handle common bgpdump text output:
	# TABLE_DUMP2|timestamp|B|peer_ip|peer_asn|prefix|as_path|origin|...
	# Or simple: prefix|as_path (where origin AS is last in path)
	mergen_log "info" "RouteViews" "Dump parse ediliyor..."

	> "$dump_path"

	while IFS= read -r line; do
		[ -z "$line" ] && continue
		# Skip comments
		case "$line" in '#'*) continue ;; esac

		local prefix origin_as

		# Try TABLE_DUMP2 format
		prefix="$(echo "$line" | cut -d'|' -f6 2>/dev/null)"
		local as_path
		as_path="$(echo "$line" | cut -d'|' -f7 2>/dev/null)"

		if [ -n "$prefix" ] && [ -n "$as_path" ]; then
			# Origin AS is the last AS in the path
			origin_as="$(echo "$as_path" | tr ' ' '\n' | tail -1)"
			# Strip AS set notation {x,y}
			origin_as="$(echo "$origin_as" | tr -d '{}' | cut -d',' -f1)"

			if [ -n "$origin_as" ] && [ -n "$prefix" ]; then
				echo "${origin_as}|${prefix}" >> "$dump_path"
			fi
		fi
	done < "$tmpfile"

	rm -f "$tmpfile"

	if [ ! -s "$dump_path" ]; then
		mergen_log "error" "RouteViews" "Parse sonucu bos"
		rm -f "$dump_path"
		return 1
	fi

	# Sort and deduplicate
	local sorted_file="${dump_path}.sorted"
	sort -u -t'|' -k1,1n -k2,2 "$dump_path" > "$sorted_file" 2>/dev/null
	mv "$sorted_file" "$dump_path"

	local line_count
	line_count="$(wc -l < "$dump_path" | tr -d ' ')"
	mergen_log "info" "RouteViews" "RouteViews dump parse edildi: ${line_count} kayit"

	return 0
}

# ── HTTP Connectivity Check ─────────────────────────────

_routeviews_http_check() {
	local url="$1"
	local timeout="$2"

	case "$url" in
		https://*) ;;
		http://*)
			mergen_log "error" "RouteViews" "HTTP reddedildi, HTTPS gerekli: ${url}"
			return 1
			;;
	esac

	if command -v curl >/dev/null 2>&1; then
		curl -s --proto '=https' --max-time "$timeout" -I "$url" >/dev/null 2>&1
	elif command -v wget >/dev/null 2>&1; then
		wget -q --timeout="$timeout" --spider "$url" 2>/dev/null
	else
		return 1
	fi
}

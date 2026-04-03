#!/bin/sh
# Mergen MaxMind GeoLite2 Provider
# Offline ASN resolution using local MMDB database
# Requires: mmdblookup (libmaxminddb) or mmdbinspect CLI tool
#
# Provider interface:
#   provider_name()        — display name
#   provider_resolve <asn> — resolve ASN to prefixes (v4 on stdout, v6 on fd 3)
#   provider_test()        — connectivity/availability test

# ── Provider Meta ───────────────────────────────────────

provider_name() {
	echo "MaxMind GeoLite2"
}

# ── Availability Test ───────────────────────────────────

# Test if MaxMind MMDB file is available and readable
provider_test() {
	local db_path

	db_path="${MERGEN_PROVIDER_DB_PATH:-/usr/share/mergen/GeoLite2-ASN.mmdb}"

	if [ ! -f "$db_path" ]; then
		mergen_log "error" "MaxMind" "MMDB dosyasi bulunamadi: ${db_path}"
		return 1
	fi

	# Check for MMDB reader tool
	if ! _maxmind_has_reader; then
		mergen_log "error" "MaxMind" "MMDB okuyucu bulunamadi (mmdblookup veya mmdbinspect gerekli)"
		return 1
	fi

	return 0
}

# ── ASN Resolution ──────────────────────────────────────

# Resolve an ASN to its announced prefix list from MMDB
# Uses a pre-built ASN-to-prefix mapping file generated from the MMDB
# IPv4 prefixes written to stdout, IPv6 to fd 3
# Returns 0 on success, 1 on error
provider_resolve() {
	local asn="$1"
	local db_path prefix_map_file

	db_path="${MERGEN_PROVIDER_DB_PATH:-/usr/share/mergen/GeoLite2-ASN.mmdb}"
	prefix_map_file="${MERGEN_PROVIDER_PREFIX_MAP:-/tmp/mergen/maxmind_prefix_map.txt}"

	if [ ! -f "$db_path" ]; then
		mergen_log "error" "MaxMind" "[!] MMDB dosyasi bulunamadi: ${db_path}"
		return 1
	fi

	mergen_log "debug" "MaxMind" "ASN ${asn} icin prefix haritasi sorgulanıyor..."

	# Strategy: Use pre-built prefix map if available, otherwise build one
	if [ ! -f "$prefix_map_file" ]; then
		mergen_log "info" "MaxMind" "Prefix haritasi bulunamadi, olusturuluyor..."
		if ! _maxmind_build_prefix_map "$db_path" "$prefix_map_file"; then
			mergen_log "error" "MaxMind" "[!] Prefix haritasi olusturulamadi."
			return 1
		fi
	fi

	# Look up ASN in the prefix map
	# Format: ASN|prefix (one per line)
	local results
	results="$(grep "^${asn}|" "$prefix_map_file" 2>/dev/null | cut -d'|' -f2)"

	if [ -z "$results" ]; then
		mergen_log "warning" "MaxMind" "ASN ${asn} icin prefix bulunamadi"
		return 0
	fi

	# Separate IPv4 and IPv6
	echo "$results" | while IFS= read -r line; do
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

# ── MMDB Reader Detection ──────────────────────────────

# Check if an MMDB reader tool is available
_maxmind_has_reader() {
	command -v mmdblookup >/dev/null 2>&1 || \
	command -v mmdbinspect >/dev/null 2>&1
}

# ── Prefix Map Builder ─────────────────────────────────

# Build an ASN-to-prefix mapping file from the MMDB
# Uses mmdblookup to query known subnets and extract ASN assignments
# Output format: ASN|prefix (one per line, sorted)
_maxmind_build_prefix_map() {
	local db_path="$1"
	local output_file="$2"
	local tmpfile="${output_file}.tmp"

	# Ensure output directory exists
	local output_dir
	output_dir="$(dirname "$output_file")"
	[ -d "$output_dir" ] || mkdir -p "$output_dir"

	if command -v mmdblookup >/dev/null 2>&1; then
		_maxmind_build_with_mmdblookup "$db_path" "$tmpfile"
	elif command -v mmdbinspect >/dev/null 2>&1; then
		_maxmind_build_with_mmdbinspect "$db_path" "$tmpfile"
	else
		mergen_log "error" "MaxMind" "MMDB okuyucu bulunamadi"
		return 1
	fi

	if [ -s "$tmpfile" ]; then
		sort -t'|' -k1 -n "$tmpfile" > "$output_file" 2>/dev/null
		rm -f "$tmpfile"
		local line_count
		line_count="$(wc -l < "$output_file" | tr -d ' ')"
		mergen_log "info" "MaxMind" "Prefix haritasi olusturuldu: ${line_count} kayit"
		return 0
	else
		rm -f "$tmpfile"
		mergen_log "error" "MaxMind" "Prefix haritasi bos"
		return 1
	fi
}

# Build prefix map using mmdblookup
# Iterates common IPv4 /8 blocks and queries each
_maxmind_build_with_mmdblookup() {
	local db_path="$1"
	local output_file="$2"

	> "$output_file"

	# Query well-known IPv4 ranges (/8 blocks)
	local octet=1
	while [ "$octet" -le 223 ]; do
		local ip="${octet}.0.0.0"
		local result
		result="$(mmdblookup --file "$db_path" --ip "$ip" 2>/dev/null)"

		if [ -n "$result" ]; then
			local asn_num prefix
			asn_num="$(echo "$result" | sed -n 's/.*"autonomous_system_number"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)"
			prefix="$(echo "$result" | sed -n 's/.*"network"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"

			if [ -n "$asn_num" ] && [ -n "$prefix" ]; then
				echo "${asn_num}|${prefix}" >> "$output_file"
			fi
		fi

		octet=$((octet + 1))
	done
}

# Build prefix map using mmdbinspect (JSON output)
_maxmind_build_with_mmdbinspect() {
	local db_path="$1"
	local output_file="$2"

	> "$output_file"

	local octet=1
	while [ "$octet" -le 223 ]; do
		local ip="${octet}.0.0.0"
		local result
		result="$(mmdbinspect -db "$db_path" -ip "$ip" 2>/dev/null)"

		if [ -n "$result" ]; then
			local asn_num prefix
			asn_num="$(echo "$result" | sed -n 's/.*"autonomous_system_number"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)"
			prefix="$(echo "$result" | sed -n 's/.*"Network"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"

			if [ -n "$asn_num" ] && [ -n "$prefix" ]; then
				echo "${asn_num}|${prefix}" >> "$output_file"
			fi
		fi

		octet=$((octet + 1))
	done
}

# ── Database Update ─────────────────────────────────────

# Download or update the GeoLite2-ASN MMDB file
# Requires a MaxMind license key configured in UCI
# Usage: _maxmind_update_db
# Returns 0 on success, 1 on failure
_maxmind_update_db() {
	local db_path license_key

	db_path="${MERGEN_PROVIDER_DB_PATH:-/usr/share/mergen/GeoLite2-ASN.mmdb}"
	license_key="${MERGEN_PROVIDER_LICENSE_KEY:-}"

	if [ -z "$license_key" ]; then
		mergen_log "error" "MaxMind" "[!] Lisans anahtari ayarlanmamis. UCI: mergen.maxmind.license_key"
		return 1
	fi

	local download_url="https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-ASN&license_key=${license_key}&suffix=tar.gz"
	local tmpdir="${MERGEN_TMP:-/tmp/mergen}/maxmind_update"
	local tmpfile="${tmpdir}/GeoLite2-ASN.tar.gz"

	[ -d "$tmpdir" ] || mkdir -p "$tmpdir"

	mergen_log "info" "MaxMind" "GeoLite2-ASN veritabani indiriliyor..."

	# Download
	if command -v curl >/dev/null 2>&1; then
		curl -s --proto '=https' --max-time 120 -o "$tmpfile" "$download_url" 2>/dev/null
	elif command -v wget >/dev/null 2>&1; then
		wget -q --timeout=120 -O "$tmpfile" "$download_url" 2>/dev/null
	else
		mergen_log "error" "MaxMind" "HTTP istemcisi bulunamadi"
		rm -rf "$tmpdir"
		return 1
	fi

	if [ ! -s "$tmpfile" ]; then
		mergen_log "error" "MaxMind" "[!] Indirme basarisiz"
		rm -rf "$tmpdir"
		return 1
	fi

	# Extract MMDB from tar.gz
	local db_dir
	db_dir="$(dirname "$db_path")"
	[ -d "$db_dir" ] || mkdir -p "$db_dir"

	tar -xzf "$tmpfile" -C "$tmpdir" 2>/dev/null
	local mmdb_file
	mmdb_file="$(find "$tmpdir" -name '*.mmdb' -type f 2>/dev/null | head -1)"

	if [ -z "$mmdb_file" ]; then
		mergen_log "error" "MaxMind" "[!] MMDB dosyasi arsivde bulunamadi"
		rm -rf "$tmpdir"
		return 1
	fi

	# Move to target location
	cp "$mmdb_file" "$db_path" 2>/dev/null
	chmod 0644 "$db_path" 2>/dev/null

	# Remove stale prefix map so it gets rebuilt
	local prefix_map="${MERGEN_PROVIDER_PREFIX_MAP:-/tmp/mergen/maxmind_prefix_map.txt}"
	rm -f "$prefix_map"

	# Cleanup
	rm -rf "$tmpdir"

	mergen_log "info" "MaxMind" "GeoLite2-ASN veritabani guncellendi: ${db_path}"
	return 0
}

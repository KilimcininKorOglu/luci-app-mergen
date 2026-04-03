#!/bin/sh
# Mergen Utilities
# Input validation, sanitization, and helper functions

# Source core.sh if not already loaded (allows test override)
if ! type mergen_log >/dev/null 2>&1; then
	. /usr/lib/mergen/core.sh
fi

# ── Shell Injection Protection ───────────────────────────

# Check for dangerous shell characters in a string
# Returns 0 if safe, 1 if dangerous
mergen_sanitize_input() {
	local value="$1"
	case "$value" in
		*\;*|*\|*|*\&*|*\`*|*\$\(*|*\>*|*\<*|*\'*|*\"*|*\\*)
			return 1
			;;
	esac
	return 0
}

# ── Prefix Limit Checks ─────────────────────────────────

# Check per-rule prefix limit
# Returns 0 if within limit, 1 if over limit
# Sets MERGEN_PREFIX_LIMIT_ERR on failure
MERGEN_PREFIX_LIMIT_ERR=""

mergen_check_prefix_limit() {
	local rule_name="$1"
	local prefix_count="$2"
	MERGEN_PREFIX_LIMIT_ERR=""

	# Read per-rule limit from UCI
	mergen_uci_get "global" "max_prefix_per_rule" "10000"
	local max_per_rule="$MERGEN_UCI_RESULT"

	if [ "$prefix_count" -gt "$max_per_rule" ] 2>/dev/null; then
		MERGEN_PREFIX_LIMIT_ERR="[!] Hata: '${rule_name}' icin ${prefix_count} prefix, limit: ${max_per_rule}. --force ile zorlayabilirsiniz."
		return 1
	fi

	return 0
}

# Check total prefix limit across all rules
# Returns 0 if within limit, 1 if over limit
# Sets MERGEN_PREFIX_LIMIT_ERR on failure
mergen_check_prefix_total() {
	local new_count="$1"
	MERGEN_PREFIX_LIMIT_ERR=""

	# Read total limit from UCI
	mergen_uci_get "global" "max_prefix_total" "50000"
	local max_total="$MERGEN_UCI_RESULT"

	# Count existing prefixes from managed tables
	local existing_count=0
	mergen_uci_get "global" "default_table" "100"
	local table_start="$MERGEN_UCI_RESULT"
	local table_end=$((table_start + 999))
	local tbl

	for tbl in $(seq "$table_start" "$table_end"); do
		local count
		count="$(ip route show table "$tbl" 2>/dev/null | wc -l | tr -d ' ')"
		existing_count=$((existing_count + count))
	done

	local total=$((existing_count + new_count))

	if [ "$total" -gt "$max_total" ] 2>/dev/null; then
		MERGEN_PREFIX_LIMIT_ERR="[!] Hata: Toplam prefix sayisi (${total}) limiti (${max_total}) asiyor. --force ile zorlayabilirsiniz."
		return 1
	fi

	return 0
}

# Validate URL uses HTTPS protocol
# Returns 0 if HTTPS, 1 if not
# Sets MERGEN_VALIDATE_ERR on failure
validate_url_https() {
	local url="$1"
	MERGEN_VALIDATE_ERR=""

	if [ -z "$url" ]; then
		MERGEN_VALIDATE_ERR="[!] Hata: URL bos olamaz."
		return 1
	fi

	case "$url" in
		https://*)
			return 0
			;;
		http://*)
			MERGEN_VALIDATE_ERR="[!] Hata: HTTP URL'ler guvenlik nedeniyle reddedildi. HTTPS kullanin: ${url}"
			return 1
			;;
		*)
			MERGEN_VALIDATE_ERR="[!] Hata: Gecersiz URL protokolu. HTTPS gerekli: ${url}"
			return 1
			;;
	esac
}

# ── ASN Validation ───────────────────────────────────────

# Validate ASN number: numeric, range 1-4294967295
# Returns 0 if valid, 1 if invalid
# Sets MERGEN_VALIDATE_ERR on failure
validate_asn() {
	local value="$1"
	MERGEN_VALIDATE_ERR=""

	# Strip leading "AS" or "as" prefix if present
	case "$value" in
		AS*|as*) value="${value#[Aa][Ss]}" ;;
	esac

	# Check not empty
	if [ -z "$value" ]; then
		MERGEN_VALIDATE_ERR="[!] Hata: ASN numarası boş olamaz. Örnek: 13335"
		return 1
	fi

	# Sanitize
	if ! mergen_sanitize_input "$value"; then
		MERGEN_VALIDATE_ERR="[!] Hata: '$value' geçersiz karakter içeriyor."
		return 1
	fi

	# Check numeric (ash-compatible: no regex)
	case "$value" in
		*[!0-9]*)
			MERGEN_VALIDATE_ERR="[!] Hata: '$value' geçerli bir ASN numarası değil. Örnek: 13335"
			return 1
			;;
	esac

	# Check range: must be >= 1
	if [ "$value" -le 0 ] 2>/dev/null; then
		MERGEN_VALIDATE_ERR="[!] Hata: ASN numarası 0'dan büyük olmalı. Örnek: 13335"
		return 1
	fi

	# Check range: must be <= 4294967295 (32-bit unsigned)
	# ash can't handle large numbers in [ ], use string comparison for very large values
	if [ "${#value}" -gt 10 ]; then
		MERGEN_VALIDATE_ERR="[!] Hata: '$value' geçerli bir ASN numarası değil. Maksimum: 4294967295"
		return 1
	fi
	if [ "${#value}" -eq 10 ] && [ "$value" \> "4294967295" ]; then
		MERGEN_VALIDATE_ERR="[!] Hata: '$value' geçerli bir ASN numarası değil. Maksimum: 4294967295"
		return 1
	fi

	return 0
}

# ── IPv4 CIDR Validation ─────────────────────────────────

# Validate a single IPv4 octet (0-255)
_validate_ipv4_octet() {
	local octet="$1"
	case "$octet" in
		*[!0-9]*) return 1 ;;
	esac
	[ -z "$octet" ] && return 1
	[ "$octet" -ge 0 ] && [ "$octet" -le 255 ] 2>/dev/null && return 0
	return 1
}

# Validate IPv4 address (without prefix)
_validate_ipv4_addr() {
	local addr="$1"
	local IFS='.'
	local count=0 octet

	# shellcheck disable=SC2086
	set -- $addr
	[ $# -eq 4 ] || return 1

	for octet in "$@"; do
		_validate_ipv4_octet "$octet" || return 1
		count=$((count + 1))
	done

	[ "$count" -eq 4 ] && return 0
	return 1
}

# ── IPv6 Validation ──────────────────────────────────────

# Basic IPv6 address validation
# Accepts full and compressed (::) notation
_validate_ipv6_addr() {
	local addr="$1"

	# Must contain at least one colon
	case "$addr" in
		*:*) ;;
		*) return 1 ;;
	esac

	# Must not contain invalid characters
	local cleaned
	cleaned="$(printf '%s' "$addr" | tr -d '0123456789abcdefABCDEF:')"
	[ -z "$cleaned" ] || return 1

	# Must not have more than one :: sequence
	local double_colons
	double_colons="$(printf '%s' "$addr" | tr -cd ':' | wc -c)"
	case "$addr" in
		*::*::*) return 1 ;;
	esac

	# Group count check: without ::, must have exactly 8 groups
	# With ::, must have fewer than 8 groups
	local group_count=0
	local remaining="$addr"
	while [ -n "$remaining" ]; do
		case "$remaining" in
			*:*) remaining="${remaining#*:}"; group_count=$((group_count + 1)) ;;
			*)   group_count=$((group_count + 1)); break ;;
		esac
	done

	case "$addr" in
		*::*)
			[ "$group_count" -le 8 ] && return 0
			return 1
			;;
		*)
			[ "$group_count" -eq 8 ] && return 0
			return 1
			;;
	esac
}

# ── IP/CIDR Validation (combined) ────────────────────────

# Validate IP address or CIDR block (IPv4 or IPv6)
# Returns 0 if valid, 1 if invalid
# Sets MERGEN_VALIDATE_ERR on failure
validate_ip_cidr() {
	local value="$1"
	MERGEN_VALIDATE_ERR=""

	if [ -z "$value" ]; then
		MERGEN_VALIDATE_ERR="[!] Hata: IP/CIDR değeri boş olamaz. Örnek: 10.0.0.0/8"
		return 1
	fi

	if ! mergen_sanitize_input "$value"; then
		MERGEN_VALIDATE_ERR="[!] Hata: '$value' geçersiz karakter içeriyor."
		return 1
	fi

	local addr prefix

	case "$value" in
		*/*)
			addr="${value%/*}"
			prefix="${value#*/}"
			;;
		*)
			addr="$value"
			prefix=""
			;;
	esac

	# Determine if IPv4 or IPv6
	case "$addr" in
		*:*)
			# IPv6
			if ! _validate_ipv6_addr "$addr"; then
				MERGEN_VALIDATE_ERR="[!] Hata: '$value' geçerli bir IPv6 adresi değil."
				return 1
			fi
			if [ -n "$prefix" ]; then
				case "$prefix" in
					*[!0-9]*) MERGEN_VALIDATE_ERR="[!] Hata: '$value' geçersiz prefix uzunluğu."; return 1 ;;
				esac
				if [ "$prefix" -lt 0 ] || [ "$prefix" -gt 128 ] 2>/dev/null; then
					MERGEN_VALIDATE_ERR="[!] Hata: IPv6 prefix uzunluğu 0-128 arasında olmalı."
					return 1
				fi
			fi
			;;
		*)
			# IPv4
			if ! _validate_ipv4_addr "$addr"; then
				MERGEN_VALIDATE_ERR="[!] Hata: '$value' geçerli bir IPv4 adresi/CIDR bloğu değil. Örnek: 10.0.0.0/8"
				return 1
			fi
			if [ -n "$prefix" ]; then
				case "$prefix" in
					*[!0-9]*) MERGEN_VALIDATE_ERR="[!] Hata: '$value' geçersiz prefix uzunluğu."; return 1 ;;
				esac
				if [ "$prefix" -lt 0 ] || [ "$prefix" -gt 32 ] 2>/dev/null; then
					MERGEN_VALIDATE_ERR="[!] Hata: IPv4 prefix uzunluğu 0-32 arasında olmalı."
					return 1
				fi
			fi
			;;
	esac

	return 0
}

# ── Interface Validation ─────────────────────────────────

# Validate that a network interface exists on the system
# Returns 0 if valid, 1 if invalid
# Sets MERGEN_VALIDATE_ERR on failure
validate_interface() {
	local name="$1"
	MERGEN_VALIDATE_ERR=""

	if [ -z "$name" ]; then
		MERGEN_VALIDATE_ERR="[!] Hata: Arayüz adı boş olamaz."
		return 1
	fi

	if ! mergen_sanitize_input "$name"; then
		MERGEN_VALIDATE_ERR="[!] Hata: '$name' geçersiz karakter içeriyor."
		return 1
	fi

	# Check interface name format (alphanumeric, hyphens, dots, max 15 chars)
	case "$name" in
		*[!a-zA-Z0-9._-]*)
			MERGEN_VALIDATE_ERR="[!] Hata: '$name' geçersiz arayüz adı."
			return 1
			;;
	esac

	if [ "${#name}" -gt 15 ]; then
		MERGEN_VALIDATE_ERR="[!] Hata: Arayüz adı 15 karakterden uzun olamaz."
		return 1
	fi

	# Check if interface actually exists
	if ! ip link show "$name" >/dev/null 2>&1; then
		local available
		available="$(ip -br link show 2>/dev/null | awk '{print $1}' | tr '\n' ', ' | sed 's/,$//')"
		MERGEN_VALIDATE_ERR="[!] Hata: '$name' arayüzü bulunamadı. Mevcut: ${available:-bilinmiyor}"
		return 1
	fi

	return 0
}

# ── Rule Name Validation ─────────────────────────────────

# Validate rule name: alphanumeric + hyphen/underscore, 1-32 chars
# Returns 0 if valid, 1 if invalid
# Sets MERGEN_VALIDATE_ERR on failure
validate_name() {
	local value="$1"
	MERGEN_VALIDATE_ERR=""

	if [ -z "$value" ]; then
		MERGEN_VALIDATE_ERR="[!] Hata: Kural adı boş olamaz."
		return 1
	fi

	if ! mergen_sanitize_input "$value"; then
		MERGEN_VALIDATE_ERR="[!] Hata: '$value' geçersiz karakter içeriyor."
		return 1
	fi

	# Only alphanumeric, hyphen, underscore
	case "$value" in
		*[!a-zA-Z0-9_-]*)
			MERGEN_VALIDATE_ERR="[!] Hata: Kural adı sadece harf, rakam, tire (-) ve alt çizgi (_) içerebilir."
			return 1
			;;
	esac

	if [ "${#value}" -gt 32 ]; then
		MERGEN_VALIDATE_ERR="[!] Hata: Kural adı en fazla 32 karakter olabilir."
		return 1
	fi

	return 0
}

# ── Priority Validation ──────────────────────────────────

# Validate priority: numeric, range 1-32000
# Returns 0 if valid, 1 if invalid
# Sets MERGEN_VALIDATE_ERR on failure
validate_priority() {
	local value="$1"
	MERGEN_VALIDATE_ERR=""

	if [ -z "$value" ]; then
		MERGEN_VALIDATE_ERR="[!] Hata: Öncelik değeri boş olamaz."
		return 1
	fi

	if ! mergen_sanitize_input "$value"; then
		MERGEN_VALIDATE_ERR="[!] Hata: '$value' geçersiz karakter içeriyor."
		return 1
	fi

	case "$value" in
		*[!0-9]*)
			MERGEN_VALIDATE_ERR="[!] Hata: Öncelik değeri sayısal olmalı (1-32000)."
			return 1
			;;
	esac

	if [ "$value" -lt 1 ] || [ "$value" -gt 32000 ] 2>/dev/null; then
		MERGEN_VALIDATE_ERR="[!] Hata: Öncelik değeri 1-32000 arasında olmalı."
		return 1
	fi

	return 0
}

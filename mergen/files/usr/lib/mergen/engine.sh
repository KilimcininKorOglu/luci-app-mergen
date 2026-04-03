#!/bin/sh
# Mergen Rule Engine
# Rule CRUD operations, conflict detection, and rule compilation
# Implemented in T007 (Rule CRUD), T028 (Conflict Detection), T029 (Tags)

# Source core.sh if not already loaded (allows test override)
if ! type mergen_log >/dev/null 2>&1; then
	. /usr/lib/mergen/core.sh
fi

# Source utils.sh if not already loaded (allows test override)
if ! type validate_name >/dev/null 2>&1; then
	. /usr/lib/mergen/utils.sh
fi

# ── Rule Add ────────────────────────────────────────────

# Add a new routing rule to UCI config
# Usage: mergen_rule_add <name> <type> <targets> <via> [priority]
#   name    — unique rule name (alphanumeric + hyphen/underscore)
#   type    — "asn" or "ip"
#   targets — comma-separated list of ASN numbers or IP/CIDR blocks
#   via     — output interface name (e.g., wg0, eth1)
#   priority — optional, defaults to UCI global default_table
# Returns 0 on success, 1 on validation/duplicate error
mergen_rule_add() {
	local name="$1"
	local type="$2"
	local targets="$3"
	local via="$4"
	local priority="$5"

	# Validate name
	if ! validate_name "$name"; then
		mergen_log "error" "Engine" "$MERGEN_VALIDATE_ERR"
		return 1
	fi

	# Check name uniqueness
	if mergen_find_rule_by_name "$name"; then
		mergen_log "error" "Engine" "[!] Hata: '$name' adında bir kural zaten mevcut."
		return 1
	fi

	# Validate type
	case "$type" in
		asn|ip) ;;
		*)
			mergen_log "error" "Engine" "[!] Hata: Geçersiz kural tipi: '$type'. Geçerli: asn, ip"
			return 1
			;;
	esac

	# Validate targets
	if [ -z "$targets" ]; then
		mergen_log "error" "Engine" "[!] Hata: Hedef listesi boş olamaz."
		return 1
	fi

	local target_item
	local IFS_OLD="$IFS"
	IFS=','
	for target_item in $targets; do
		IFS="$IFS_OLD"
		# Trim whitespace
		target_item="$(echo "$target_item" | tr -d ' ')"
		[ -z "$target_item" ] && continue

		if [ "$type" = "asn" ]; then
			if ! validate_asn "$target_item"; then
				mergen_log "error" "Engine" "$MERGEN_VALIDATE_ERR"
				return 1
			fi
		elif [ "$type" = "ip" ]; then
			if ! validate_ip_cidr "$target_item"; then
				mergen_log "error" "Engine" "$MERGEN_VALIDATE_ERR"
				return 1
			fi
		fi
	done
	IFS="$IFS_OLD"

	# Validate interface (via)
	if [ -z "$via" ]; then
		mergen_log "error" "Engine" "[!] Hata: Çıkış arayüzü (via) belirtilmeli."
		return 1
	fi
	if ! validate_name "$via"; then
		mergen_log "error" "Engine" "$MERGEN_VALIDATE_ERR"
		return 1
	fi

	# Get default priority from UCI if not specified
	if [ -z "$priority" ]; then
		mergen_uci_get "global" "default_table" "100"
		priority="$MERGEN_UCI_RESULT"
	else
		if ! validate_priority "$priority"; then
			mergen_log "error" "Engine" "$MERGEN_VALIDATE_ERR"
			return 1
		fi
	fi

	# Add rule to UCI
	mergen_uci_add "rule"
	local section_id="$MERGEN_UCI_RESULT"

	if [ -z "$section_id" ]; then
		mergen_log "error" "Engine" "[!] Hata: UCI'ye kural eklenemedi."
		return 1
	fi

	mergen_uci_set "$section_id" "name" "$name"
	mergen_uci_set "$section_id" "via" "$via"
	mergen_uci_set "$section_id" "priority" "$priority"
	mergen_uci_set "$section_id" "enabled" "1"

	# Add targets — single value uses option, multiple values use list
	local target_count=0
	IFS=','
	for target_item in $targets; do
		IFS="$IFS_OLD"
		target_item="$(echo "$target_item" | tr -d ' ')"
		[ -z "$target_item" ] && continue
		# Strip AS prefix for ASN targets
		if [ "$type" = "asn" ]; then
			case "$target_item" in
				AS*|as*) target_item="${target_item#[Aa][Ss]}" ;;
			esac
		fi
		target_count=$((target_count + 1))
	done
	IFS="$IFS_OLD"

	if [ "$target_count" -eq 1 ]; then
		# Single target: use option
		local single_target
		IFS=','
		for target_item in $targets; do
			IFS="$IFS_OLD"
			single_target="$(echo "$target_item" | tr -d ' ')"
			if [ "$type" = "asn" ]; then
				case "$single_target" in
					AS*|as*) single_target="${single_target#[Aa][Ss]}" ;;
				esac
			fi
			break
		done
		IFS="$IFS_OLD"
		mergen_uci_set "$section_id" "$type" "$single_target"
	else
		# Multiple targets: use list
		IFS=','
		for target_item in $targets; do
			IFS="$IFS_OLD"
			target_item="$(echo "$target_item" | tr -d ' ')"
			[ -z "$target_item" ] && continue
			if [ "$type" = "asn" ]; then
				case "$target_item" in
					AS*|as*) target_item="${target_item#[Aa][Ss]}" ;;
				esac
			fi
			mergen_uci_add_list "$section_id" "$type" "$target_item"
		done
		IFS="$IFS_OLD"
	fi

	mergen_uci_commit

	mergen_log "info" "Engine" "Kural eklendi: ${name} (${type}: ${targets} -> ${via})"
	return 0
}

# ── Rule Remove ─────────────────────────────────────────

# Remove a rule by name
# Returns 0 on success, 1 if rule not found
mergen_rule_remove() {
	local name="$1"

	if [ -z "$name" ]; then
		mergen_log "error" "Engine" "[!] Hata: Kural adı belirtilmeli."
		return 1
	fi

	if ! mergen_find_rule_by_name "$name"; then
		mergen_log "error" "Engine" "[!] Hata: '$name' adında bir kural bulunamadı."
		return 1
	fi

	local section_id="$MERGEN_UCI_RESULT"
	mergen_uci_delete "$section_id"
	mergen_uci_commit

	mergen_log "info" "Engine" "Kural silindi: ${name}"
	return 0
}

# ── Rule Get ────────────────────────────────────────────

# Get details of a single rule by name
# Returns 0 if found, 1 if not
# Sets MERGEN_RULE_* variables with rule details
MERGEN_RULE_NAME=""
MERGEN_RULE_VIA=""
MERGEN_RULE_PRIORITY=""
MERGEN_RULE_ENABLED=""
MERGEN_RULE_TYPE=""
MERGEN_RULE_TARGETS=""
MERGEN_RULE_SECTION=""

mergen_rule_get() {
	local name="$1"

	MERGEN_RULE_NAME=""
	MERGEN_RULE_VIA=""
	MERGEN_RULE_PRIORITY=""
	MERGEN_RULE_ENABLED=""
	MERGEN_RULE_TYPE=""
	MERGEN_RULE_TARGETS=""
	MERGEN_RULE_SECTION=""

	if [ -z "$name" ]; then
		mergen_log "error" "Engine" "[!] Hata: Kural adı belirtilmeli."
		return 1
	fi

	if ! mergen_find_rule_by_name "$name"; then
		mergen_log "error" "Engine" "[!] Hata: '$name' adında bir kural bulunamadı."
		return 1
	fi

	local section_id="$MERGEN_UCI_RESULT"
	MERGEN_RULE_SECTION="$section_id"

	config_load "$MERGEN_CONF"
	config_get MERGEN_RULE_NAME "$section_id" "name" ""
	config_get MERGEN_RULE_VIA "$section_id" "via" ""
	config_get MERGEN_RULE_PRIORITY "$section_id" "priority" "100"
	config_get MERGEN_RULE_ENABLED "$section_id" "enabled" "1"

	# Determine type and targets
	# Try option asn first, then list asn, then option ip, then list ip
	local asn_val ip_val
	config_get asn_val "$section_id" "asn" ""
	config_get ip_val "$section_id" "ip" ""

	if [ -n "$asn_val" ]; then
		MERGEN_RULE_TYPE="asn"
		MERGEN_RULE_TARGETS="$asn_val"
	elif [ -n "$ip_val" ]; then
		MERGEN_RULE_TYPE="ip"
		MERGEN_RULE_TARGETS="$ip_val"
	else
		MERGEN_RULE_TYPE="unknown"
		MERGEN_RULE_TARGETS=""
	fi

	return 0
}

# ── Rule List ───────────────────────────────────────────

# List all rules in formatted table
# Output format per PRD Section 7.3:
# ID  NAME         TYPE  TARGET              VIA   PRI  STATUS
mergen_rule_list() {
	local count=0
	local has_rules=0

	# Print header
	printf "%-4s %-16s %-5s %-20s %-6s %-5s %s\n" \
		"ID" "NAME" "TYPE" "TARGET" "VIA" "PRI" "STATUS"

	_rule_list_cb() {
		local section="$1"
		local name via priority enabled asn_val ip_val
		local type target status

		config_get name "$section" "name" ""
		config_get via "$section" "via" ""
		config_get priority "$section" "priority" "100"
		config_get enabled "$section" "enabled" "1"
		config_get asn_val "$section" "asn" ""
		config_get ip_val "$section" "ip" ""

		# Determine type and target display
		if [ -n "$asn_val" ]; then
			type="ASN"
			# Format: AS13335 or AS15169,AS36040
			local formatted=""
			local item
			local IFS_OLD="$IFS"
			IFS=' '
			for item in $asn_val; do
				if [ -n "$formatted" ]; then
					formatted="${formatted},AS${item}"
				else
					formatted="AS${item}"
				fi
			done
			IFS="$IFS_OLD"
			target="$formatted"
		elif [ -n "$ip_val" ]; then
			type="IP"
			# Format: first CIDR or count
			local first_ip ip_count=0
			local item
			local IFS_OLD="$IFS"
			IFS=' '
			for item in $ip_val; do
				ip_count=$((ip_count + 1))
				[ "$ip_count" -eq 1 ] && first_ip="$item"
			done
			IFS="$IFS_OLD"
			if [ "$ip_count" -gt 1 ]; then
				target="${first_ip} (+$((ip_count - 1)))"
			else
				target="$first_ip"
			fi
		else
			type="?"
			target="-"
		fi

		# Status
		if [ "$enabled" = "1" ]; then
			status="active"
		else
			status="disabled"
		fi

		# Truncate long target strings
		if [ "${#target}" -gt 20 ]; then
			target="$(printf '%.17s...' "$target")"
		fi

		count=$((count + 1))
		has_rules=1
		printf "%-4s %-16s %-5s %-20s %-6s %-5s %s\n" \
			"$count" "$name" "$type" "$target" "$via" "$priority" "$status"
	}

	mergen_list_rules _rule_list_cb

	if [ "$has_rules" -eq 0 ]; then
		echo "(kayıtlı kural yok)"
	fi
}

# ── Rule Toggle ─────────────────────────────────────────

# Enable or disable a rule by name
# Usage: mergen_rule_toggle <name> <0|1>
# Returns 0 on success, 1 on failure
mergen_rule_toggle() {
	local name="$1"
	local enabled="$2"

	if [ -z "$name" ]; then
		mergen_log "error" "Engine" "[!] Hata: Kural adı belirtilmeli."
		return 1
	fi

	case "$enabled" in
		0|1) ;;
		*)
			mergen_log "error" "Engine" "[!] Hata: Geçersiz durum: '$enabled'. Geçerli: 0 (devre dışı), 1 (aktif)"
			return 1
			;;
	esac

	if ! mergen_find_rule_by_name "$name"; then
		mergen_log "error" "Engine" "[!] Hata: '$name' adında bir kural bulunamadı."
		return 1
	fi

	local section_id="$MERGEN_UCI_RESULT"
	mergen_uci_set "$section_id" "enabled" "$enabled"
	mergen_uci_commit

	local state_str
	if [ "$enabled" = "1" ]; then
		state_str="aktif"
	else
		state_str="devre dışı"
	fi
	mergen_log "info" "Engine" "Kural '${name}' durumu: ${state_str}"
	return 0
}

# ── Rule Update ─────────────────────────────────────────

# Update an existing rule's fields
# Usage: mergen_rule_update <name> <field> <value>
#   field: "via", "priority", "enabled"
# Returns 0 on success, 1 on failure
mergen_rule_update() {
	local name="$1"
	local field="$2"
	local value="$3"

	if [ -z "$name" ]; then
		mergen_log "error" "Engine" "[!] Hata: Kural adı belirtilmeli."
		return 1
	fi

	if ! mergen_find_rule_by_name "$name"; then
		mergen_log "error" "Engine" "[!] Hata: '$name' adında bir kural bulunamadı."
		return 1
	fi

	local section_id="$MERGEN_UCI_RESULT"

	case "$field" in
		via)
			if ! validate_name "$value"; then
				mergen_log "error" "Engine" "$MERGEN_VALIDATE_ERR"
				return 1
			fi
			;;
		priority)
			if ! validate_priority "$value"; then
				mergen_log "error" "Engine" "$MERGEN_VALIDATE_ERR"
				return 1
			fi
			;;
		enabled)
			case "$value" in
				0|1) ;;
				*)
					mergen_log "error" "Engine" "[!] Hata: Geçersiz enabled değeri: '$value'"
					return 1
					;;
			esac
			;;
		*)
			mergen_log "error" "Engine" "[!] Hata: Güncellenebilir alanlar: via, priority, enabled"
			return 1
			;;
	esac

	mergen_uci_set "$section_id" "$field" "$value"
	mergen_uci_commit

	mergen_log "info" "Engine" "Kural '${name}' güncellendi: ${field}=${value}"
	return 0
}

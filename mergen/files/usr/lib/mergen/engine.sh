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
		asn|ip|domain|country) ;;
		*)
			mergen_log "error" "Engine" "[!] Hata: Geçersiz kural tipi: '$type'. Geçerli: asn, ip, domain, country"
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
		elif [ "$type" = "domain" ]; then
			if ! validate_domain "$target_item"; then
				mergen_log "error" "Engine" "$MERGEN_VALIDATE_ERR"
				return 1
			fi
		elif [ "$type" = "country" ]; then
			if ! validate_country_code "$target_item"; then
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
	MERGEN_RULE_TAGS=""
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
	# Try: asn, ip, domain, country
	local asn_val ip_val domain_val country_val
	config_get asn_val "$section_id" "asn" ""
	config_get ip_val "$section_id" "ip" ""
	config_get domain_val "$section_id" "domain" ""
	config_get country_val "$section_id" "country" ""

	if [ -n "$asn_val" ]; then
		MERGEN_RULE_TYPE="asn"
		MERGEN_RULE_TARGETS="$asn_val"
	elif [ -n "$ip_val" ]; then
		MERGEN_RULE_TYPE="ip"
		MERGEN_RULE_TARGETS="$ip_val"
	elif [ -n "$domain_val" ]; then
		MERGEN_RULE_TYPE="domain"
		MERGEN_RULE_TARGETS="$domain_val"
	elif [ -n "$country_val" ]; then
		MERGEN_RULE_TYPE="country"
		MERGEN_RULE_TARGETS="$country_val"
	else
		MERGEN_RULE_TYPE="unknown"
		MERGEN_RULE_TARGETS=""
	fi

	# Get tags
	config_get MERGEN_RULE_TAGS "$section_id" "tag" ""

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
		local name via priority enabled asn_val ip_val domain_val country_val
		local type target status

		config_get name "$section" "name" ""
		config_get via "$section" "via" ""
		config_get priority "$section" "priority" "100"
		config_get enabled "$section" "enabled" "1"
		config_get asn_val "$section" "asn" ""
		config_get ip_val "$section" "ip" ""
		config_get domain_val "$section" "domain" ""
		config_get country_val "$section" "country" ""

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
		elif [ -n "$domain_val" ]; then
			type="DNS"
			# Format: first domain or count
			local first_dom dom_count=0
			local item
			local IFS_OLD="$IFS"
			IFS=' '
			for item in $domain_val; do
				dom_count=$((dom_count + 1))
				[ "$dom_count" -eq 1 ] && first_dom="$item"
			done
			IFS="$IFS_OLD"
			if [ "$dom_count" -gt 1 ]; then
				target="${first_dom} (+$((dom_count - 1)))"
			else
				target="$first_dom"
			fi
		elif [ -n "$country_val" ]; then
			type="CC"
			target="$country_val"
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

# ── IPv4 CIDR Utilities ────────────────────────────────────

# Convert dotted IPv4 address to 32-bit integer
# Usage: _mergen_ip_to_int "10.0.0.0"
# Sets MERGEN_IP_INT on success
MERGEN_IP_INT=0

_mergen_ip_to_int() {
	local ip="$1"
	local a b c d
	IFS='.' read -r a b c d <<IPEOF
$ip
IPEOF
	MERGEN_IP_INT=$(( (a << 24) + (b << 16) + (c << 8) + d ))
}

# Convert 32-bit integer to dotted IPv4 address
# Usage: _mergen_int_to_ip 167772160
# Sets MERGEN_IP_STR on success
MERGEN_IP_STR=""

_mergen_int_to_ip() {
	local n="$1"
	MERGEN_IP_STR="$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

# Get the network address (start) and broadcast address (end) of a CIDR block
# Usage: _mergen_cidr_range "10.0.0.0/8"
# Sets MERGEN_CIDR_START and MERGEN_CIDR_END as integers
MERGEN_CIDR_START=0
MERGEN_CIDR_END=0

_mergen_cidr_range() {
	local cidr="$1"
	local addr="${cidr%/*}"
	local prefix="${cidr#*/}"

	_mergen_ip_to_int "$addr"
	local ip_int="$MERGEN_IP_INT"

	# Mask: all 1s in the prefix bits, 0s in host bits
	local mask=0
	if [ "$prefix" -gt 0 ]; then
		mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
	fi

	MERGEN_CIDR_START=$(( ip_int & mask ))
	# End = network OR (inverse mask)
	local hostmask=$(( mask ^ 0xFFFFFFFF ))
	MERGEN_CIDR_END=$(( MERGEN_CIDR_START | hostmask ))
}

# Check if two CIDR blocks overlap
# Usage: _mergen_cidr_overlaps "10.0.0.0/8" "10.1.0.0/16"
# Returns 0 if overlapping, 1 if disjoint
_mergen_cidr_overlaps() {
	local cidr_a="$1"
	local cidr_b="$2"

	_mergen_cidr_range "$cidr_a"
	local a_start="$MERGEN_CIDR_START"
	local a_end="$MERGEN_CIDR_END"

	_mergen_cidr_range "$cidr_b"
	local b_start="$MERGEN_CIDR_START"
	local b_end="$MERGEN_CIDR_END"

	# Two ranges overlap if: a_start <= b_end AND b_start <= a_end
	if [ "$a_start" -le "$b_end" ] && [ "$b_start" -le "$a_end" ]; then
		return 0
	fi
	return 1
}

# ── Conflict Detection ─────────────────────────────────────

# Check for prefix conflicts across all active rules
# A conflict is when the same or overlapping prefix is routed via different interfaces
# Usage: mergen_check_conflicts
# Sets MERGEN_CONFLICT_COUNT and prints conflict details
# Returns 0 if no conflicts, 1 if conflicts found
MERGEN_CONFLICT_COUNT=0
MERGEN_CONFLICT_REPORT=""

mergen_check_conflicts() {
	MERGEN_CONFLICT_COUNT=0
	MERGEN_CONFLICT_REPORT=""

	# Collect all rule prefixes with their rule name and interface
	# Format: "prefix|rule_name|via" per line
	local all_prefixes=""

	_collect_prefixes_cb() {
		local section="$1"
		local name via enabled asn_val ip_val
		config_get name "$section" "name" ""
		config_get via "$section" "via" ""
		config_get enabled "$section" "enabled" "1"

		[ "$enabled" != "1" ] && return
		[ -z "$name" ] && return

		config_get asn_val "$section" "asn" ""
		config_get ip_val "$section" "ip" ""

		local targets=""
		if [ -n "$ip_val" ]; then
			targets="$ip_val"
		fi
		# ASN rules are resolved at apply time — skip for static conflict check
		# Only IP-based rules can be checked statically

		local item
		for item in $targets; do
			# Only check IPv4 CIDRs for overlap (contains '/' and no ':')
			case "$item" in
				*:*) continue ;; # Skip IPv6
				*/*) ;;
				*) continue ;; # Skip non-CIDR
			esac
			all_prefixes="${all_prefixes}
${item}|${name}|${via}"
		done
	}

	config_load "$MERGEN_CONF"
	config_foreach _collect_prefixes_cb "rule"

	all_prefixes="$(echo "$all_prefixes" | sed '/^$/d')"
	[ -z "$all_prefixes" ] && return 0

	# Write to temp file for double-loop comparison
	local tmpfile="${MERGEN_TMP:-/tmp/mergen}/conflict_check.tmp"
	[ -d "${MERGEN_TMP:-/tmp/mergen}" ] || mkdir -p "${MERGEN_TMP:-/tmp/mergen}"
	echo "$all_prefixes" > "$tmpfile"

	# Compare each pair (O(n^2) but n is small for routing rules)
	local line_a line_b
	local prefix_a name_a via_a
	local prefix_b name_b via_b
	local line_num_a=0

	while IFS='|' read -r prefix_a name_a via_a; do
		line_num_a=$((line_num_a + 1))
		local line_num_b=0

		while IFS='|' read -r prefix_b name_b via_b; do
			line_num_b=$((line_num_b + 1))
			# Skip same line and already-compared pairs
			[ "$line_num_b" -le "$line_num_a" ] && continue
			# Skip same rule
			[ "$name_a" = "$name_b" ] && continue
			# Skip same interface (not a conflict if same destination)
			[ "$via_a" = "$via_b" ] && continue

			if _mergen_cidr_overlaps "$prefix_a" "$prefix_b"; then
				MERGEN_CONFLICT_COUNT=$((MERGEN_CONFLICT_COUNT + 1))
				local detail="Çakışma: '${name_a}' (${prefix_a} -> ${via_a}) <-> '${name_b}' (${prefix_b} -> ${via_b})"
				MERGEN_CONFLICT_REPORT="${MERGEN_CONFLICT_REPORT}
${detail}"
				mergen_log "warning" "Engine" "$detail"
			fi
		done < "$tmpfile"
	done < "$tmpfile"

	rm -f "$tmpfile"

	MERGEN_CONFLICT_REPORT="$(echo "$MERGEN_CONFLICT_REPORT" | sed '/^$/d')"

	if [ "$MERGEN_CONFLICT_COUNT" -gt 0 ]; then
		mergen_log "warning" "Engine" "${MERGEN_CONFLICT_COUNT} prefix çakışması tespit edildi."
		return 1
	fi

	mergen_log "info" "Engine" "Prefix çakışması bulunamadı."
	return 0
}

# ── CIDR Aggregation ───────────────────────────────────────

# Aggregate a list of IPv4 CIDR prefixes by merging adjacent blocks
# Usage: mergen_aggregate_prefixes <prefix_list>
#   prefix_list: newline-separated CIDR prefixes
# Prints aggregated list to stdout
# Returns 0 on success
mergen_aggregate_prefixes() {
	local prefix_list="$1"

	if [ -z "$prefix_list" ]; then
		return 0
	fi

	local tmpdir="${MERGEN_TMP:-/tmp/mergen}"
	[ -d "$tmpdir" ] || mkdir -p "$tmpdir"
	local infile="${tmpdir}/agg_in.tmp"
	local outfile="${tmpdir}/agg_out.tmp"

	# Filter only valid IPv4 CIDRs, sort, deduplicate
	echo "$prefix_list" | sed '/^$/d' | while IFS= read -r line; do
		case "$line" in
			*:*) continue ;; # Skip IPv6
			*/*) echo "$line" ;;
		esac
	done | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | uniq > "$infile"

	local changed=1

	# Iterate until no more merges are possible
	while [ "$changed" -eq 1 ]; do
		changed=0
		> "$outfile"

		local prev_prefix="" prev_start=0 prev_end=0 prev_len=0
		local skip_next=0

		while IFS= read -r cidr; do
			[ -z "$cidr" ] && continue

			if [ "$skip_next" -eq 1 ]; then
				skip_next=0
				continue
			fi

			local addr="${cidr%/*}"
			local prefix_len="${cidr#*/}"

			_mergen_cidr_range "$cidr"
			local cur_start="$MERGEN_CIDR_START"
			local cur_end="$MERGEN_CIDR_END"

			if [ -n "$prev_prefix" ] && [ "$prefix_len" = "$prev_len" ]; then
				# Check if prev and current are adjacent and can merge
				# Adjacent: prev_end + 1 == cur_start
				local next_after_prev=$((prev_end + 1))

				if [ "$next_after_prev" -eq "$cur_start" ]; then
					# Check if merged block aligns to the parent prefix
					local parent_len=$((prev_len - 1))
					if [ "$parent_len" -ge 0 ]; then
						local parent_mask=0
						if [ "$parent_len" -gt 0 ]; then
							parent_mask=$(( (0xFFFFFFFF << (32 - parent_len)) & 0xFFFFFFFF ))
						fi
						local parent_net=$(( prev_start & parent_mask ))

						if [ "$parent_net" -eq "$prev_start" ]; then
							# Merge: emit parent CIDR instead of both
							_mergen_int_to_ip "$parent_net"
							echo "${MERGEN_IP_STR}/${parent_len}" >> "$outfile"
							changed=1
							prev_prefix=""
							prev_start=0
							prev_end=0
							prev_len=0
							continue
						fi
					fi
				fi
			fi

			# Emit previous (it couldn't be merged)
			if [ -n "$prev_prefix" ]; then
				echo "$prev_prefix" >> "$outfile"
			fi

			prev_prefix="$cidr"
			prev_start="$cur_start"
			prev_end="$cur_end"
			prev_len="$prefix_len"
		done < "$infile"

		# Emit last prefix
		if [ -n "$prev_prefix" ]; then
			echo "$prev_prefix" >> "$outfile"
		fi

		# Swap files for next iteration
		cp "$outfile" "$infile"
	done

	cat "$infile"
	rm -f "$infile" "$outfile"
	return 0
}

# ── Rule Tags ──────────────────────────────────────────────

# Add a tag to a rule
# Usage: mergen_rule_tag_add <rule_name> <tag>
# Returns 0 on success, 1 on failure
mergen_rule_tag_add() {
	local name="$1"
	local tag="$2"

	if [ -z "$name" ] || [ -z "$tag" ]; then
		mergen_log "error" "Engine" "[!] Hata: Kural adı ve etiket belirtilmeli."
		return 1
	fi

	if ! validate_name "$tag"; then
		mergen_log "error" "Engine" "$MERGEN_VALIDATE_ERR"
		return 1
	fi

	if ! mergen_find_rule_by_name "$name"; then
		mergen_log "error" "Engine" "[!] Hata: '$name' adında bir kural bulunamadı."
		return 1
	fi

	local section_id="$MERGEN_UCI_RESULT"

	# Check if tag already exists on this rule
	config_load "$MERGEN_CONF"
	local existing_tags
	config_get existing_tags "$section_id" "tag" ""

	local item
	for item in $existing_tags; do
		if [ "$item" = "$tag" ]; then
			mergen_log "warning" "Engine" "Etiket zaten mevcut: '${tag}' -> '${name}'"
			return 0
		fi
	done

	mergen_uci_add_list "$section_id" "tag" "$tag"
	mergen_uci_commit

	mergen_log "info" "Engine" "Etiket eklendi: '${tag}' -> '${name}'"
	return 0
}

# Remove a tag from a rule
# Usage: mergen_rule_tag_remove <rule_name> <tag>
# Returns 0 on success, 1 on failure
mergen_rule_tag_remove() {
	local name="$1"
	local tag="$2"

	if [ -z "$name" ] || [ -z "$tag" ]; then
		mergen_log "error" "Engine" "[!] Hata: Kural adı ve etiket belirtilmeli."
		return 1
	fi

	if ! mergen_find_rule_by_name "$name"; then
		mergen_log "error" "Engine" "[!] Hata: '$name' adında bir kural bulunamadı."
		return 1
	fi

	local section_id="$MERGEN_UCI_RESULT"

	mergen_uci_del_list "$section_id" "tag" "$tag"
	mergen_uci_commit

	mergen_log "info" "Engine" "Etiket kaldırıldı: '${tag}' <- '${name}'"
	return 0
}

# Get tags for a rule
# Usage: mergen_rule_tags_get <rule_name>
# Sets MERGEN_RULE_TAGS (space-separated list)
MERGEN_RULE_TAGS=""

mergen_rule_tags_get() {
	local name="$1"
	MERGEN_RULE_TAGS=""

	if ! mergen_find_rule_by_name "$name"; then
		return 1
	fi

	local section_id="$MERGEN_UCI_RESULT"
	config_load "$MERGEN_CONF"
	config_get MERGEN_RULE_TAGS "$section_id" "tag" ""
	return 0
}

# Check if a rule has a specific tag
# Usage: mergen_rule_has_tag <rule_name> <tag>
# Returns 0 if rule has tag, 1 otherwise
mergen_rule_has_tag() {
	local name="$1"
	local tag="$2"

	mergen_rule_tags_get "$name" || return 1

	local item
	for item in $MERGEN_RULE_TAGS; do
		if [ "$item" = "$tag" ]; then
			return 0
		fi
	done
	return 1
}

# List rules filtered by tag
# Usage: mergen_rule_list_by_tag <tag>
# Prints formatted table of matching rules
mergen_rule_list_by_tag() {
	local filter_tag="$1"
	local count=0
	local has_rules=0

	if [ -z "$filter_tag" ]; then
		mergen_log "error" "Engine" "[!] Hata: Etiket belirtilmeli."
		return 1
	fi

	printf "%-4s %-16s %-5s %-20s %-6s %-5s %-8s %s\n" \
		"ID" "NAME" "TYPE" "TARGET" "VIA" "PRI" "STATUS" "TAGS"

	_tag_list_cb() {
		local section="$1"
		local name via priority enabled asn_val ip_val tags
		local type target status

		config_get name "$section" "name" ""
		config_get tags "$section" "tag" ""

		# Check if rule has the filter tag
		local has_tag=0 item
		for item in $tags; do
			if [ "$item" = "$filter_tag" ]; then
				has_tag=1
				break
			fi
		done
		[ "$has_tag" -eq 0 ] && return

		config_get via "$section" "via" ""
		config_get priority "$section" "priority" "100"
		config_get enabled "$section" "enabled" "1"
		config_get asn_val "$section" "asn" ""
		config_get ip_val "$section" "ip" ""

		if [ -n "$asn_val" ]; then
			type="ASN"
			local formatted="" i
			for i in $asn_val; do
				if [ -n "$formatted" ]; then
					formatted="${formatted},AS${i}"
				else
					formatted="AS${i}"
				fi
			done
			target="$formatted"
		elif [ -n "$ip_val" ]; then
			type="IP"
			local first_ip="" ip_count=0 i
			for i in $ip_val; do
				ip_count=$((ip_count + 1))
				[ "$ip_count" -eq 1 ] && first_ip="$i"
			done
			if [ "$ip_count" -gt 1 ]; then
				target="${first_ip} (+$((ip_count - 1)))"
			else
				target="$first_ip"
			fi
		else
			type="?"
			target="-"
		fi

		if [ "$enabled" = "1" ]; then
			status="active"
		else
			status="disabled"
		fi

		if [ "${#target}" -gt 20 ]; then
			target="$(printf '%.17s...' "$target")"
		fi

		count=$((count + 1))
		has_rules=1
		printf "%-4s %-16s %-5s %-20s %-6s %-5s %-8s %s\n" \
			"$count" "$name" "$type" "$target" "$via" "$priority" "$status" "$tags"
	}

	mergen_list_rules _tag_list_cb

	if [ "$has_rules" -eq 0 ]; then
		printf "(etiket '%s' ile eşleşen kural yok)\n" "$filter_tag"
	fi
}

# Batch enable/disable rules by tag
# Usage: mergen_rule_toggle_by_tag <tag> <0|1>
# Returns 0 on success, 1 if no rules matched
MERGEN_TAG_TOGGLE_COUNT=0

mergen_rule_toggle_by_tag() {
	local filter_tag="$1"
	local enabled="$2"
	MERGEN_TAG_TOGGLE_COUNT=0

	if [ -z "$filter_tag" ]; then
		mergen_log "error" "Engine" "[!] Hata: Etiket belirtilmeli."
		return 1
	fi

	case "$enabled" in
		0|1) ;;
		*)
			mergen_log "error" "Engine" "[!] Hata: Geçersiz durum: '$enabled'"
			return 1
			;;
	esac

	_toggle_by_tag_cb() {
		local section="$1"
		local name tags

		config_get name "$section" "name" ""
		config_get tags "$section" "tag" ""

		local has_tag=0 item
		for item in $tags; do
			if [ "$item" = "$filter_tag" ]; then
				has_tag=1
				break
			fi
		done

		if [ "$has_tag" -eq 1 ] && [ -n "$name" ]; then
			mergen_rule_toggle "$name" "$enabled"
			MERGEN_TAG_TOGGLE_COUNT=$((MERGEN_TAG_TOGGLE_COUNT + 1))
		fi
	}

	config_load "$MERGEN_CONF"
	config_foreach _toggle_by_tag_cb "rule"

	if [ "$MERGEN_TAG_TOGGLE_COUNT" -eq 0 ]; then
		mergen_log "warning" "Engine" "Etiket '${filter_tag}' ile eşleşen kural bulunamadı."
		return 1
	fi

	local action_str
	if [ "$enabled" = "1" ]; then
		action_str="etkinlestirildi"
	else
		action_str="devre disi birakildi"
	fi

	mergen_log "info" "Engine" "${MERGEN_TAG_TOGGLE_COUNT} kural ${action_str} (etiket: ${filter_tag})"
	return 0
}

# ── JSON Export ────────────────────────────────────────────

# Export all rules as JSON to stdout
# Output format matches PRD Section 4.3 schema
mergen_rule_export_json() {
	local first=1

	printf '{\n  "rules": ['

	_export_json_cb() {
		local section="$1"
		local name via priority enabled asn_val ip_val tags

		config_get name "$section" "name" ""
		[ -z "$name" ] && return

		config_get via "$section" "via" ""
		config_get priority "$section" "priority" "100"
		config_get enabled "$section" "enabled" "1"
		config_get asn_val "$section" "asn" ""
		config_get ip_val "$section" "ip" ""
		config_get tags "$section" "tag" ""

		if [ "$first" -eq 1 ]; then
			first=0
		else
			printf ','
		fi

		printf '\n    {\n'
		printf '      "name": "%s",\n' "$name"

		# Export targets
		if [ -n "$asn_val" ]; then
			local item_count=0 item
			for item in $asn_val; do
				item_count=$((item_count + 1))
			done

			if [ "$item_count" -eq 1 ]; then
				printf '      "asn": %s,\n' "$asn_val"
			else
				printf '      "asn": ['
				local item_first=1
				for item in $asn_val; do
					if [ "$item_first" -eq 1 ]; then
						item_first=0
					else
						printf ', '
					fi
					printf '%s' "$item"
				done
				printf '],\n'
			fi
		elif [ -n "$ip_val" ]; then
			local item_count=0 item
			for item in $ip_val; do
				item_count=$((item_count + 1))
			done

			if [ "$item_count" -eq 1 ]; then
				printf '      "ip": "%s",\n' "$ip_val"
			else
				printf '      "ip": ['
				local item_first=1
				for item in $ip_val; do
					if [ "$item_first" -eq 1 ]; then
						item_first=0
					else
						printf ', '
					fi
					printf '"%s"' "$item"
				done
				printf '],\n'
			fi
		fi

		printf '      "via": "%s",\n' "$via"
		printf '      "priority": %s,\n' "$priority"
		printf '      "enabled": %s' "$enabled"

		# Tags (optional)
		if [ -n "$tags" ]; then
			printf ',\n      "tags": ['
			local tag_first=1 t
			for t in $tags; do
				if [ "$tag_first" -eq 1 ]; then
					tag_first=0
				else
					printf ', '
				fi
				printf '"%s"' "$t"
			done
			printf ']'
		fi

		printf '\n    }'
	}

	mergen_list_rules _export_json_cb

	printf '\n  ]\n}\n'
}

# ── JSON Import ────────────────────────────────────────────

# Import rules from a JSON file
# Usage: mergen_rule_import_json <file> [replace]
#   file    — path to JSON file
#   replace — if "1", delete existing rules before import
# Returns 0 on success, 1 on error
# Sets MERGEN_IMPORT_COUNT with number of imported rules
MERGEN_IMPORT_COUNT=0
MERGEN_IMPORT_SKIP=0
MERGEN_IMPORT_ERROR=0

mergen_rule_import_json() {
	local file="$1"
	local replace="${2:-0}"
	MERGEN_IMPORT_COUNT=0
	MERGEN_IMPORT_SKIP=0
	MERGEN_IMPORT_ERROR=0

	if [ -z "$file" ]; then
		mergen_log "error" "Engine" "[!] Hata: JSON dosya yolu belirtilmeli."
		return 1
	fi

	if [ ! -f "$file" ]; then
		mergen_log "error" "Engine" "[!] Hata: Dosya bulunamadı: $file"
		return 1
	fi

	# Validate JSON structure — check that rules array exists
	if ! jsonfilter -i "$file" -e '@.rules' >/dev/null 2>&1; then
		mergen_log "error" "Engine" "[!] Hata: Geçersiz JSON formatı veya 'rules' dizisi bulunamadı: $file"
		return 1
	fi

	# Get rule count
	local rule_count
	rule_count="$(jsonfilter -i "$file" -e '@.rules.length' 2>/dev/null)"
	if [ -z "$rule_count" ] || [ "$rule_count" -eq 0 ] 2>/dev/null; then
		mergen_log "warning" "Engine" "JSON dosyasında kural bulunamadı: $file"
		return 0
	fi

	# Delete existing rules if --replace
	if [ "$replace" = "1" ]; then
		_import_delete_cb() {
			local section="$1"
			local name
			config_get name "$section" "name" ""
			if [ -n "$name" ]; then
				mergen_rule_remove "$name"
			fi
		}
		mergen_list_rules _import_delete_cb
		mergen_log "info" "Engine" "Mevcut kurallar silindi (--replace)"
	fi

	# Import each rule
	local idx=0
	while [ "$idx" -lt "$rule_count" ]; do
		local name via priority asn_val ip_val type targets

		name="$(jsonfilter -i "$file" -e "@.rules[$idx].name" 2>/dev/null)"
		via="$(jsonfilter -i "$file" -e "@.rules[$idx].via" 2>/dev/null)"
		priority="$(jsonfilter -i "$file" -e "@.rules[$idx].priority" 2>/dev/null)"

		if [ -z "$name" ] || [ -z "$via" ]; then
			mergen_log "error" "Engine" "[!] Hata: Kural $idx: name veya via alanı eksik."
			MERGEN_IMPORT_ERROR=$((MERGEN_IMPORT_ERROR + 1))
			idx=$((idx + 1))
			continue
		fi

		# Determine type: check asn first, then ip
		asn_val="$(jsonfilter -i "$file" -e "@.rules[$idx].asn" 2>/dev/null)"
		ip_val="$(jsonfilter -i "$file" -e "@.rules[$idx].ip" 2>/dev/null)"

		if [ -n "$asn_val" ]; then
			type="asn"
			# jsonfilter returns array as space-separated or single value
			# Convert spaces to commas for mergen_rule_add
			targets="$(echo "$asn_val" | tr ' ' ',')"
		elif [ -n "$ip_val" ]; then
			type="ip"
			targets="$(echo "$ip_val" | tr ' ' ',')"
		else
			mergen_log "error" "Engine" "[!] Hata: Kural '$name': asn veya ip alanı eksik."
			MERGEN_IMPORT_ERROR=$((MERGEN_IMPORT_ERROR + 1))
			idx=$((idx + 1))
			continue
		fi

		# Check if rule already exists (skip unless replace mode)
		if mergen_find_rule_by_name "$name"; then
			mergen_log "warning" "Engine" "Kural zaten mevcut, atlanıyor: '$name'"
			MERGEN_IMPORT_SKIP=$((MERGEN_IMPORT_SKIP + 1))
			idx=$((idx + 1))
			continue
		fi

		# Default priority
		[ -z "$priority" ] && priority=""

		if mergen_rule_add "$name" "$type" "$targets" "$via" "$priority"; then
			MERGEN_IMPORT_COUNT=$((MERGEN_IMPORT_COUNT + 1))

			# Import tags if present
			local tags_val
			tags_val="$(jsonfilter -i "$file" -e "@.rules[$idx].tags" 2>/dev/null)"
			if [ -n "$tags_val" ]; then
				local tag_item
				for tag_item in $tags_val; do
					mergen_rule_tag_add "$name" "$tag_item"
				done
			fi
		else
			MERGEN_IMPORT_ERROR=$((MERGEN_IMPORT_ERROR + 1))
		fi

		idx=$((idx + 1))
	done

	mergen_log "info" "Engine" "İçe aktarma: $MERGEN_IMPORT_COUNT eklendi, $MERGEN_IMPORT_SKIP atlandı, $MERGEN_IMPORT_ERROR hata"
	return 0
}

# Load all JSON files from rules.d directory
# Usage: mergen_load_rules_dir [directory]
# Default directory: /etc/mergen/rules.d
mergen_load_rules_dir() {
	local dir="${1:-/etc/mergen/rules.d}"

	if [ ! -d "$dir" ]; then
		return 0
	fi

	local total_imported=0
	local file

	for file in "$dir"/*.json; do
		[ -f "$file" ] || continue

		mergen_log "info" "Engine" "Kural dosyası yükleniyor: $file"
		if mergen_rule_import_json "$file"; then
			total_imported=$((total_imported + MERGEN_IMPORT_COUNT))
		else
			mergen_log "error" "Engine" "[!] Hata: Dosya yüklenemedi: $file"
		fi
	done

	if [ "$total_imported" -gt 0 ]; then
		mergen_log "info" "Engine" "rules.d/: $total_imported kural yüklendi"
	fi

	return 0
}

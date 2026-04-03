#!/bin/sh
# Mergen Route Manager
# Policy routing (ip rule/route), nftables/ipset set management, snapshots
# Implemented in T008 (Policy Routing), T014 (Rollback), T017 (nftables)

# Source core.sh if not already loaded (allows test override)
if ! type mergen_log >/dev/null 2>&1; then
	. /usr/lib/mergen/core.sh
fi

# Source engine.sh if not already loaded
if ! type mergen_rule_get >/dev/null 2>&1; then
	. /usr/lib/mergen/engine.sh
fi

# Source resolver.sh if not already loaded
if ! type mergen_resolve_asn >/dev/null 2>&1; then
	. /usr/lib/mergen/resolver.sh
fi

# ── State Variables ─────────────────────────────────────

MERGEN_ROUTE_TABLE_BASE=100
MERGEN_ROUTE_APPLIED_COUNT=0
MERGEN_ROUTE_FAILED_COUNT=0

# ── Gateway Detection ───────────────────────────────────

# Detect the gateway address for a given interface
# Usage: mergen_detect_gateway <interface>
# Sets MERGEN_GATEWAY_ADDR on success, returns 1 if not found
MERGEN_GATEWAY_ADDR=""

mergen_detect_gateway() {
	local interface="$1"
	MERGEN_GATEWAY_ADDR=""

	# Try to find the default gateway for this interface
	local gw
	gw="$(ip route show dev "$interface" 2>/dev/null | \
		sed -n 's/^default via \([^ ]*\).*/\1/p' | head -1)"

	if [ -n "$gw" ]; then
		MERGEN_GATEWAY_ADDR="$gw"
		return 0
	fi

	# Fallback: check global default route that uses this interface
	gw="$(ip route show default 2>/dev/null | \
		grep "dev $interface" | \
		sed -n 's/^default via \([^ ]*\).*/\1/p' | head -1)"

	if [ -n "$gw" ]; then
		MERGEN_GATEWAY_ADDR="$gw"
		return 0
	fi

	mergen_log "error" "Route" "[!] Hata: '${interface}' arayüzü için gateway bulunamadı."
	return 1
}

# ── Table Number Management ─────────────────────────────

# Get the routing table number for a rule
# Table number = base + rule_index (0-based)
# Usage: _mergen_get_table_num <rule_name>
# Sets MERGEN_TABLE_NUM on success
MERGEN_TABLE_NUM=0

_mergen_get_table_num() {
	local target_name="$1"
	local index=0

	mergen_uci_get "global" "default_table" "100"
	MERGEN_ROUTE_TABLE_BASE="$MERGEN_UCI_RESULT"

	_table_num_cb() {
		local section="$1"
		local name
		config_get name "$section" "name" ""
		if [ "$name" = "$target_name" ]; then
			MERGEN_TABLE_NUM=$((MERGEN_ROUTE_TABLE_BASE + index))
		fi
		index=$((index + 1))
	}

	config_load "$MERGEN_CONF"
	config_foreach _table_num_cb "rule"

	[ "$MERGEN_TABLE_NUM" -gt 0 ] && return 0
	return 1
}

# ── Route Apply ─────────────────────────────────────────

# Apply routes for a single rule
# Creates ip rules and ip routes for all prefixes
# Returns 0 on success, 1 on failure
mergen_route_apply() {
	local rule_name="$1"
	local prefix_list=""

	if [ -z "$rule_name" ]; then
		mergen_log "error" "Route" "[!] Hata: Kural adı belirtilmeli."
		return 1
	fi

	# Get rule details
	if ! mergen_rule_get "$rule_name"; then
		return 1
	fi

	# Check if rule is enabled
	if [ "$MERGEN_RULE_ENABLED" != "1" ]; then
		mergen_log "warning" "Route" "Kural '${rule_name}' devre dışı, atlanıyor."
		return 0
	fi

	local via="$MERGEN_RULE_VIA"
	local priority="$MERGEN_RULE_PRIORITY"
	local type="$MERGEN_RULE_TYPE"
	local targets="$MERGEN_RULE_TARGETS"

	# Detect gateway for the interface
	if ! mergen_detect_gateway "$via"; then
		return 1
	fi
	local gateway="$MERGEN_GATEWAY_ADDR"

	# Get table number
	if ! _mergen_get_table_num "$rule_name"; then
		mergen_log "error" "Route" "[!] Hata: '${rule_name}' için tablo numarası belirlenemedi."
		return 1
	fi
	local table_num="$MERGEN_TABLE_NUM"

	mergen_log "info" "Route" "Kural '${rule_name}' uygulanıyor (tablo: ${table_num}, arayüz: ${via})"

	# Build prefix list based on rule type
	if [ "$type" = "ip" ]; then
		# IP-based rule: targets are CIDR prefixes directly
		prefix_list="$(echo "$targets" | tr ' ' '\n')"
	elif [ "$type" = "asn" ]; then
		# ASN-based rule: resolve each ASN to get prefixes
		local asn_item
		for asn_item in $targets; do
			if mergen_resolve_asn "$asn_item"; then
				if [ -n "$MERGEN_RESOLVE_RESULT_V4" ]; then
					prefix_list="${prefix_list}
${MERGEN_RESOLVE_RESULT_V4}"
				fi
			else
				mergen_log "warning" "Route" "ASN ${asn_item} çözümlenemedi, atlanıyor."
			fi
		done
	else
		mergen_log "error" "Route" "[!] Hata: Bilinmeyen kural tipi: ${type}"
		return 1
	fi

	# Clean empty lines
	prefix_list="$(echo "$prefix_list" | sed '/^$/d')"

	if [ -z "$prefix_list" ]; then
		mergen_log "warning" "Route" "Kural '${rule_name}' için prefix bulunamadı."
		return 0
	fi

	# Count prefixes
	local prefix_count
	prefix_count="$(echo "$prefix_list" | wc -l | tr -d ' ')"
	mergen_log "info" "Route" "${prefix_count} prefix uygulanıyor..."

	# Apply routes for each prefix
	# NOTE: Here-document used instead of pipe to avoid subshell variable loss
	local line errors=0
	while IFS= read -r line; do
		[ -z "$line" ] && continue

		# Add ip route: route the prefix via the specified gateway and interface
		if ! ip route add "$line" via "$gateway" dev "$via" table "$table_num" 2>/dev/null; then
			# Route might already exist, try replace
			if ! ip route replace "$line" via "$gateway" dev "$via" table "$table_num" 2>/dev/null; then
				mergen_log "warning" "Route" "Rota eklenemedi: ${line} -> ${via}"
				errors=$((errors + 1))
			fi
		fi

		# Add ip rule: direct traffic to this prefix through the custom table
		ip rule add to "$line" lookup "$table_num" priority "$priority" 2>/dev/null
	done <<EOF
$prefix_list
EOF

	mergen_log "info" "Route" "Kural '${rule_name}' uygulandı (tablo: ${table_num}, prefix: ${prefix_count})"
	return 0
}

# ── Route Remove ────────────────────────────────────────

# Remove all routes and ip rules for a given rule
# Returns 0 on success, 1 on failure
mergen_route_remove() {
	local rule_name="$1"

	if [ -z "$rule_name" ]; then
		mergen_log "error" "Route" "[!] Hata: Kural adı belirtilmeli."
		return 1
	fi

	# Get table number
	if ! _mergen_get_table_num "$rule_name"; then
		mergen_log "error" "Route" "[!] Hata: '${rule_name}' için tablo numarası belirlenemedi."
		return 1
	fi
	local table_num="$MERGEN_TABLE_NUM"

	mergen_log "info" "Route" "Kural '${rule_name}' kaldırılıyor (tablo: ${table_num})"

	# Remove all ip rules pointing to this table
	# Loop until no more rules exist for this table
	local max_attempts=1000
	local attempts=0
	while ip rule del lookup "$table_num" 2>/dev/null; do
		attempts=$((attempts + 1))
		[ "$attempts" -ge "$max_attempts" ] && break
	done

	# Flush the routing table
	ip route flush table "$table_num" 2>/dev/null

	mergen_log "info" "Route" "Kural '${rule_name}' kaldırıldı (tablo: ${table_num})"
	return 0
}

# ── Apply All ───────────────────────────────────────────

# Apply routes for all enabled rules
# Returns 0 if at least one rule applied, 1 if all failed
mergen_route_apply_all() {
	MERGEN_ROUTE_APPLIED_COUNT=0
	MERGEN_ROUTE_FAILED_COUNT=0

	mergen_log "info" "Route" "Tüm kurallar uygulanıyor..."

	_apply_all_cb() {
		local section="$1"
		local name enabled
		config_get name "$section" "name" ""
		config_get enabled "$section" "enabled" "1"

		if [ "$enabled" != "1" ]; then
			mergen_log "debug" "Route" "Kural '${name}' devre dışı, atlanıyor."
			return 0
		fi

		if mergen_route_apply "$name"; then
			MERGEN_ROUTE_APPLIED_COUNT=$((MERGEN_ROUTE_APPLIED_COUNT + 1))
		else
			MERGEN_ROUTE_FAILED_COUNT=$((MERGEN_ROUTE_FAILED_COUNT + 1))
			mergen_log "error" "Route" "Kural '${name}' uygulanamadı."
		fi
	}

	mergen_list_rules _apply_all_cb

	mergen_log "info" "Route" "Sonuç: ${MERGEN_ROUTE_APPLIED_COUNT} başarılı, ${MERGEN_ROUTE_FAILED_COUNT} başarısız"

	[ "$MERGEN_ROUTE_APPLIED_COUNT" -gt 0 ] && return 0
	[ "$MERGEN_ROUTE_FAILED_COUNT" -eq 0 ] && return 0
	return 1
}

# ── Remove All ──────────────────────────────────────────

# Remove routes for all rules
mergen_route_remove_all() {
	mergen_log "info" "Route" "Tüm kurallar kaldırılıyor..."

	_remove_all_cb() {
		local section="$1"
		local name
		config_get name "$section" "name" ""
		mergen_route_remove "$name"
	}

	mergen_list_rules _remove_all_cb

	mergen_log "info" "Route" "Tüm kurallar kaldırıldı."
	return 0
}

# ── Route Status ────────────────────────────────────────

# Show routing status for a rule
# Returns 0 if routes exist, 1 if no routes
mergen_route_status() {
	local rule_name="$1"

	if [ -z "$rule_name" ]; then
		mergen_log "error" "Route" "[!] Hata: Kural adı belirtilmeli."
		return 1
	fi

	if ! _mergen_get_table_num "$rule_name"; then
		mergen_log "error" "Route" "[!] Hata: '${rule_name}' için tablo numarası belirlenemedi."
		return 1
	fi

	local table_num="$MERGEN_TABLE_NUM"
	local route_count

	route_count="$(ip route show table "$table_num" 2>/dev/null | wc -l | tr -d ' ')"

	if [ "$route_count" -gt 0 ]; then
		printf "Kural: %-16s Tablo: %-6s Rotalar: %s\n" "$rule_name" "$table_num" "$route_count"
		return 0
	else
		printf "Kural: %-16s Tablo: %-6s Rotalar: yok\n" "$rule_name" "$table_num"
		return 1
	fi
}

#!/bin/sh
# Mergen Route Manager
# Policy routing (ip rule/route), nftables set management, snapshots
# Implemented in T008 (Policy Routing), T014 (Rollback), T015 (Atomic), T017 (nftables)

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
MERGEN_SNAPSHOT_DIR="${MERGEN_TMP:-/tmp/mergen}/snapshot"

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

# ── IPv6 Gateway Detection ─────────────────────────────

# Detect the IPv6 gateway address for a given interface
# Usage: mergen_detect_gateway_v6 <interface>
# Sets MERGEN_GATEWAY_V6_ADDR on success, returns 1 if not found
MERGEN_GATEWAY_V6_ADDR=""

mergen_detect_gateway_v6() {
	local interface="$1"
	MERGEN_GATEWAY_V6_ADDR=""

	local gw
	gw="$(ip -6 route show dev "$interface" 2>/dev/null | \
		sed -n 's/^default via \([^ ]*\).*/\1/p' | head -1)"

	if [ -n "$gw" ]; then
		MERGEN_GATEWAY_V6_ADDR="$gw"
		return 0
	fi

	gw="$(ip -6 route show default 2>/dev/null | \
		grep "dev $interface" | \
		sed -n 's/^default via \([^ ]*\).*/\1/p' | head -1)"

	if [ -n "$gw" ]; then
		MERGEN_GATEWAY_V6_ADDR="$gw"
		return 0
	fi

	mergen_log "warning" "Route" "IPv6 gateway bulunamadi: ${interface}"
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

	# Check if IPv6 is enabled
	mergen_uci_get "global" "ipv6_enabled" "1"
	local ipv6_enabled="$MERGEN_UCI_RESULT"

	# Build prefix lists (v4 and v6)
	local prefix_list_v6=""

	if [ "$type" = "ip" ]; then
		# IP-based rule: separate v4/v6 CIDR prefixes
		local _item
		for _item in $targets; do
			case "$_item" in
				*:*)
					if [ "$ipv6_enabled" = "1" ]; then
						prefix_list_v6="${prefix_list_v6}
${_item}"
					fi
					;;
				*)
					prefix_list="${prefix_list}
${_item}"
					;;
			esac
		done
	elif [ "$type" = "asn" ]; then
		# ASN-based rule: resolve each ASN to get prefixes
		local asn_item
		for asn_item in $targets; do
			if mergen_resolve_asn "$asn_item"; then
				if [ -n "$MERGEN_RESOLVE_RESULT_V4" ]; then
					prefix_list="${prefix_list}
${MERGEN_RESOLVE_RESULT_V4}"
				fi
				if [ "$ipv6_enabled" = "1" ] && [ -n "$MERGEN_RESOLVE_RESULT_V6" ]; then
					prefix_list_v6="${prefix_list_v6}
${MERGEN_RESOLVE_RESULT_V6}"
				fi
			else
				mergen_log "warning" "Route" "ASN ${asn_item} çözümlenemedi, atlanıyor."
			fi
		done
	elif [ "$type" = "domain" ]; then
		# Domain-based rule: configure dnsmasq to populate nft/ipset sets
		mergen_dnsmasq_apply "$rule_name" "$targets" "$table_num" "$via" "$priority"
		return $?
	else
		mergen_log "error" "Route" "[!] Hata: Bilinmeyen kural tipi: ${type}"
		return 1
	fi

	# Clean empty lines
	prefix_list="$(echo "$prefix_list" | sed '/^$/d')"
	prefix_list_v6="$(echo "$prefix_list_v6" | sed '/^$/d')"

	if [ -z "$prefix_list" ] && [ -z "$prefix_list_v6" ]; then
		mergen_log "warning" "Route" "Kural '${rule_name}' için prefix bulunamadı."
		return 0
	fi

	# Count prefixes (v4 + v6 combined for limit checks)
	local prefix_count prefix_count_v6=0
	prefix_count="$(echo "$prefix_list" | grep -c '.' 2>/dev/null || echo 0)"
	[ -z "$prefix_list" ] && prefix_count=0
	if [ -n "$prefix_list_v6" ]; then
		prefix_count_v6="$(echo "$prefix_list_v6" | wc -l | tr -d ' ')"
	fi
	local total_prefix_count=$((prefix_count + prefix_count_v6))

	# Check prefix limits (unless --force is active)
	if [ "${MERGEN_FORCE_APPLY:-0}" != "1" ]; then
		if ! mergen_check_prefix_limit "$rule_name" "$total_prefix_count"; then
			mergen_log "error" "Route" "$MERGEN_PREFIX_LIMIT_ERR"
			return 1
		fi
		if ! mergen_check_prefix_total "$total_prefix_count"; then
			mergen_log "error" "Route" "$MERGEN_PREFIX_LIMIT_ERR"
			return 1
		fi
	fi

	mergen_log "info" "Route" "${prefix_count} IPv4 + ${prefix_count_v6} IPv6 prefix uygulanıyor..."

	# ── Apply IPv4 Routes ──────────────────────────────────
	local line errors=0
	if [ -n "$prefix_list" ]; then
		while IFS= read -r line; do
			[ -z "$line" ] && continue
			if ! ip route add "$line" via "$gateway" dev "$via" table "$table_num" 2>/dev/null; then
				if ! ip route replace "$line" via "$gateway" dev "$via" table "$table_num" 2>/dev/null; then
					mergen_log "warning" "Route" "Rota eklenemedi: ${line} -> ${via}"
					errors=$((errors + 1))
				fi
			fi
		done <<EOF
$prefix_list
EOF
	fi

	# ── Apply IPv6 Routes ──────────────────────────────────
	if [ -n "$prefix_list_v6" ]; then
		local gateway_v6=""
		if mergen_detect_gateway_v6 "$via"; then
			gateway_v6="$MERGEN_GATEWAY_V6_ADDR"
		fi

		while IFS= read -r line; do
			[ -z "$line" ] && continue
			if [ -n "$gateway_v6" ]; then
				if ! ip -6 route add "$line" via "$gateway_v6" dev "$via" table "$table_num" 2>/dev/null; then
					ip -6 route replace "$line" via "$gateway_v6" dev "$via" table "$table_num" 2>/dev/null
				fi
			else
				# Link-local: route without explicit gateway
				if ! ip -6 route add "$line" dev "$via" table "$table_num" 2>/dev/null; then
					ip -6 route replace "$line" dev "$via" table "$table_num" 2>/dev/null
				fi
			fi
		done <<V6ROUTEEOF
$prefix_list_v6
V6ROUTEEOF
	fi

	# ── Set-Based Routing ──────────────────────────────────
	mergen_engine_detect
	if [ "$MERGEN_ENGINE_ACTIVE" != "none" ]; then
		# IPv4 set
		if [ -n "$prefix_list" ]; then
			if mergen_set_create "$rule_name"; then
				if mergen_set_add "$rule_name" "$prefix_list"; then
					mergen_set_mark_rule "$rule_name" "$table_num"
					ip rule add fwmark "$table_num" lookup "$table_num" priority "$priority" 2>/dev/null
				fi
			fi
		fi
		# IPv6 set
		if [ -n "$prefix_list_v6" ]; then
			if mergen_set_create_v6 "$rule_name"; then
				if mergen_set_add_v6 "$rule_name" "$prefix_list_v6"; then
					mergen_set_mark_rule_v6 "$rule_name" "$table_num"
					ip -6 rule add fwmark "$table_num" lookup "$table_num" priority "$priority" 2>/dev/null
				fi
			fi
		fi
	else
		# Fallback: individual ip rules per prefix (no set engine available)
		if [ -n "$prefix_list" ]; then
			while IFS= read -r line; do
				[ -z "$line" ] && continue
				ip rule add to "$line" lookup "$table_num" priority "$priority" 2>/dev/null
			done <<IPRULEEOF
$prefix_list
IPRULEEOF
		fi
		if [ -n "$prefix_list_v6" ]; then
			while IFS= read -r line; do
				[ -z "$line" ] && continue
				ip -6 rule add to "$line" lookup "$table_num" priority "$priority" 2>/dev/null
			done <<IP6RULEEOF
$prefix_list_v6
IP6RULEEOF
		fi
	fi

	mergen_log "info" "Route" "Kural '${rule_name}' uygulandı (tablo: ${table_num}, v4: ${prefix_count}, v6: ${prefix_count_v6})"
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

	# Remove dnsmasq config for domain rules (idempotent)
	mergen_dnsmasq_remove "$rule_name"

	# Remove set and fwmark/MARK rule via common interface (v4 + v6)
	mergen_set_destroy "$rule_name"
	mergen_set_destroy_v6 "$rule_name"

	# Remove all ip rules pointing to this table (including fwmark rules)
	# Loop until no more rules exist for this table
	local max_attempts=1000
	local attempts=0
	while ip rule del lookup "$table_num" 2>/dev/null; do
		attempts=$((attempts + 1))
		[ "$attempts" -ge "$max_attempts" ] && break
	done

	# Remove all ip -6 rules pointing to this table
	attempts=0
	while ip -6 rule del lookup "$table_num" 2>/dev/null; do
		attempts=$((attempts + 1))
		[ "$attempts" -ge "$max_attempts" ] && break
	done

	# Flush the routing table (v4 + v6)
	ip route flush table "$table_num" 2>/dev/null
	ip -6 route flush table "$table_num" 2>/dev/null

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

# ── Atomic Apply ──────────────────────────────────────────

# Atomic apply: all rules succeed or none are applied
# Takes snapshot, applies rules one by one, rolls back on any failure
# Returns 0 on full success, 1 on failure (with rollback)
MERGEN_ATOMIC_FAILED_RULE=""

mergen_apply_atomic() {
	MERGEN_ROUTE_APPLIED_COUNT=0
	MERGEN_ROUTE_FAILED_COUNT=0
	MERGEN_ATOMIC_FAILED_RULE=""

	# Collect enabled rules in priority order
	local rule_names=""

	_collect_rules_cb() {
		local section="$1"
		local name enabled
		config_get name "$section" "name" ""
		config_get enabled "$section" "enabled" "1"

		if [ "$enabled" = "1" ] && [ -n "$name" ]; then
			rule_names="${rule_names} ${name}"
		fi
	}

	mergen_list_rules _collect_rules_cb

	# Nothing to apply
	if [ -z "$(echo "$rule_names" | tr -d ' ')" ]; then
		mergen_log "info" "Route" "Uygulanacak aktif kural yok."
		return 0
	fi

	mergen_log "info" "Route" "Atomik uygulama baslatiliyor..."

	# Track which rules were successfully applied (for partial rollback)
	local applied_rules=""

	# Apply rules one by one
	local name
	for name in $rule_names; do
		if mergen_route_apply "$name"; then
			MERGEN_ROUTE_APPLIED_COUNT=$((MERGEN_ROUTE_APPLIED_COUNT + 1))
			applied_rules="${applied_rules} ${name}"
		else
			MERGEN_ROUTE_FAILED_COUNT=$((MERGEN_ROUTE_FAILED_COUNT + 1))
			MERGEN_ATOMIC_FAILED_RULE="$name"
			mergen_log "error" "Route" "Kural '${name}' basarisiz. Geri alma baslatiliyor..."

			# Rollback: remove all rules applied so far
			local rollback_name
			for rollback_name in $applied_rules; do
				mergen_route_remove "$rollback_name" 2>/dev/null
			done

			# Restore from snapshot
			if mergen_snapshot_exists; then
				mergen_snapshot_restore
				mergen_log "info" "Route" "Snapshot'tan geri yukleme tamamlandi."
			fi

			mergen_log "error" "Route" "Atomik uygulama basarisiz: '${name}' kuralinda hata."
			return 1
		fi
	done

	mergen_log "info" "Route" "Atomik uygulama basarili: ${MERGEN_ROUTE_APPLIED_COUNT} kural uygulandi."
	return 0
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

	# Clean up entire set engine resources (catches any orphaned sets)
	mergen_set_cleanup

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

# ── Snapshot / Rollback ────────────────────────────────────

# Create a snapshot of current routing state before apply
# Saves ip rules, ip routes, and UCI config backup
# Returns 0 on success, 1 on failure
mergen_snapshot_create() {
	[ -d "$MERGEN_SNAPSHOT_DIR" ] || mkdir -p "$MERGEN_SNAPSHOT_DIR"

	mergen_log "info" "Snapshot" "Routing durumu kaydediliyor..."

	# Save ip rules
	ip rule save > "${MERGEN_SNAPSHOT_DIR}/rules.save" 2>/dev/null
	if [ $? -ne 0 ]; then
		# Fallback: save text format
		ip rule show > "${MERGEN_SNAPSHOT_DIR}/rules.save" 2>/dev/null
	fi

	# Save all routes from mergen-managed tables
	local table_start table_end
	mergen_uci_get "global" "default_table" "100"
	table_start="$MERGEN_UCI_RESULT"
	table_end=$((table_start + 999))

	# Save routes for each table that has entries
	local tbl routes_saved=0
	> "${MERGEN_SNAPSHOT_DIR}/routes.save"
	tbl="$table_start"
	while [ "$tbl" -le "$table_end" ]; do
		local routes
		routes="$(ip route show table "$tbl" 2>/dev/null)"
		if [ -n "$routes" ]; then
			echo "# table=$tbl" >> "${MERGEN_SNAPSHOT_DIR}/routes.save"
			echo "$routes" >> "${MERGEN_SNAPSHOT_DIR}/routes.save"
			routes_saved=$((routes_saved + 1))
		fi
		tbl=$((tbl + 1))
		# Stop early after 50 empty tables in a row
		if [ "$routes_saved" -eq 0 ] && [ "$tbl" -gt $((table_start + 50)) ]; then
			break
		fi
	done

	# Save UCI config backup
	if [ -f /etc/config/mergen ]; then
		cp /etc/config/mergen "${MERGEN_SNAPSHOT_DIR}/uci.backup" 2>/dev/null
	fi

	# Save set engine state (nftables or ipset)
	mergen_set_snapshot_save

	# Write snapshot metadata
	cat > "${MERGEN_SNAPSHOT_DIR}/meta" <<METAEOF
timestamp=$(date +%s)
tables_saved=${routes_saved}
METAEOF

	mergen_log "info" "Snapshot" "Snapshot kaydedildi: ${MERGEN_SNAPSHOT_DIR}"
	return 0
}

# Restore routing state from a snapshot
# Removes all mergen-managed routes/rules and re-applies from snapshot
# Returns 0 on success, 1 on failure
mergen_snapshot_restore() {
	if [ ! -d "$MERGEN_SNAPSHOT_DIR" ] || [ ! -f "${MERGEN_SNAPSHOT_DIR}/meta" ]; then
		mergen_log "error" "Snapshot" "[!] Hata: Geri yukleme icin snapshot bulunamadi."
		return 1
	fi

	mergen_log "info" "Snapshot" "Routing durumu geri yukleniyor..."

	# Step 1: Remove all current mergen-managed routes and rules
	mergen_route_remove_all

	# Step 2: Restore routes from snapshot
	if [ -f "${MERGEN_SNAPSHOT_DIR}/routes.save" ]; then
		local current_table=""
		while IFS= read -r line; do
			case "$line" in
				"# table="*)
					current_table="${line#\# table=}"
					;;
				"")
					continue
					;;
				*)
					if [ -n "$current_table" ]; then
						ip route add $line table "$current_table" 2>/dev/null
					fi
					;;
			esac
		done < "${MERGEN_SNAPSHOT_DIR}/routes.save"
	fi

	# Step 3: Restore ip rules from snapshot
	if [ -f "${MERGEN_SNAPSHOT_DIR}/rules.save" ]; then
		ip rule restore < "${MERGEN_SNAPSHOT_DIR}/rules.save" 2>/dev/null || {
			# Fallback: parse text format and re-add rules
			# Only restore mergen-managed rules (lookup tables >= default_table)
			mergen_uci_get "global" "default_table" "100"
			local base_table="$MERGEN_UCI_RESULT"

			while IFS= read -r line; do
				local tbl
				tbl="$(echo "$line" | sed -n 's/.*lookup \([0-9]*\).*/\1/p')"
				[ -z "$tbl" ] && continue
				[ "$tbl" -lt "$base_table" ] && continue

				local prefix priority
				prefix="$(echo "$line" | sed -n 's/.*to \([^ ]*\).*/\1/p')"
				priority="$(echo "$line" | sed -n 's/^\([0-9]*\):.*/\1/p')"

				if [ -n "$prefix" ] && [ -n "$tbl" ]; then
					ip rule add to "$prefix" lookup "$tbl" ${priority:+priority "$priority"} 2>/dev/null
				fi
			done < "${MERGEN_SNAPSHOT_DIR}/rules.save"
		}
	fi

	# Step 4: Restore set engine state (nftables or ipset)
	mergen_set_snapshot_restore

	mergen_log "info" "Snapshot" "Routing durumu geri yuklendi."
	return 0
}

# Check if a snapshot exists
# Returns 0 if snapshot exists, 1 otherwise
mergen_snapshot_exists() {
	[ -d "$MERGEN_SNAPSHOT_DIR" ] && [ -f "${MERGEN_SNAPSHOT_DIR}/meta" ]
}

# Get snapshot info
# Prints timestamp and table count
mergen_snapshot_info() {
	if ! mergen_snapshot_exists; then
		echo "Snapshot bulunamadi."
		return 1
	fi

	local timestamp tables_saved
	timestamp="$(sed -n 's/^timestamp=//p' "${MERGEN_SNAPSHOT_DIR}/meta")"
	tables_saved="$(sed -n 's/^tables_saved=//p' "${MERGEN_SNAPSHOT_DIR}/meta")"

	# Format timestamp
	local date_str
	date_str="$(date -d "@${timestamp}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || \
		date -r "$timestamp" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || \
		echo "$timestamp")"

	printf "Snapshot: %s (%s tablo)\n" "$date_str" "${tables_saved:-0}"
	return 0
}

# Delete the current snapshot
mergen_snapshot_delete() {
	if [ -d "$MERGEN_SNAPSHOT_DIR" ]; then
		rm -rf "$MERGEN_SNAPSHOT_DIR"
		mergen_log "info" "Snapshot" "Snapshot silindi."
	fi
}

# ── Safe Mode ──────────────────────────────────────────────

MERGEN_PENDING_FILE="${MERGEN_TMP:-/tmp/mergen}/pending_confirm"

# Perform connectivity test (ping)
# Returns 0 if target is reachable, 1 otherwise
mergen_safe_mode_ping() {
	local target="$1"
	[ -z "$target" ] && target="8.8.8.8"

	# Use 3 pings with 2 second timeout
	if ping -c 3 -W 2 "$target" > /dev/null 2>&1; then
		return 0
	fi
	return 1
}

# Create pending confirmation file
# Watchdog will check this and auto-rollback if not confirmed in time
mergen_safe_mode_start() {
	local timeout="$1"
	[ -z "$timeout" ] && timeout=60

	cat > "$MERGEN_PENDING_FILE" <<PENDEOF
timestamp=$(date +%s)
timeout=${timeout}
PENDEOF

	mergen_log "info" "SafeMode" "Onay bekleniyor (zaman asimi: ${timeout}s)"
}

# Confirm safe mode — remove pending file
mergen_safe_mode_confirm() {
	if [ -f "$MERGEN_PENDING_FILE" ]; then
		rm -f "$MERGEN_PENDING_FILE"
		mergen_log "info" "SafeMode" "Degisiklikler onaylandi."
		return 0
	else
		mergen_log "warning" "SafeMode" "Bekleyen onay bulunamadi."
		return 1
	fi
}

# Check if safe mode confirmation is pending
mergen_safe_mode_pending() {
	[ -f "$MERGEN_PENDING_FILE" ]
}

# Check if safe mode timer has expired
# Returns 0 if expired, 1 if still within timeout
mergen_safe_mode_expired() {
	if ! mergen_safe_mode_pending; then
		return 1
	fi

	local timestamp timeout now elapsed
	timestamp="$(sed -n 's/^timestamp=//p' "$MERGEN_PENDING_FILE")"
	timeout="$(sed -n 's/^timeout=//p' "$MERGEN_PENDING_FILE")"
	now="$(date +%s)"
	elapsed=$((now - timestamp))

	[ "$elapsed" -ge "$timeout" ]
}

# ── nftables Set Management ──────────────────────────────────

MERGEN_NFT_TABLE="mergen"
MERGEN_NFT_CHAIN="prerouting"
MERGEN_NFT_AVAILABLE=""

# Check if nftables (nft) command is available
# Caches result in MERGEN_NFT_AVAILABLE
# Returns 0 if available, 1 otherwise
mergen_nft_available() {
	if [ -z "$MERGEN_NFT_AVAILABLE" ]; then
		if command -v nft >/dev/null 2>&1; then
			MERGEN_NFT_AVAILABLE="1"
		else
			MERGEN_NFT_AVAILABLE="0"
		fi
	fi
	[ "$MERGEN_NFT_AVAILABLE" = "1" ]
}

# Initialize the mergen nftables table and prerouting chain
# Creates if not already present
# Returns 0 on success, 1 on failure
mergen_nft_init() {
	if ! mergen_nft_available; then
		mergen_log "error" "NFT" "[!] Hata: nftables (nft) komutu bulunamadı."
		return 1
	fi

	# Create table (idempotent — no error if exists)
	nft add table inet "$MERGEN_NFT_TABLE" 2>/dev/null

	# Create prerouting chain with priority -150 (before conntrack)
	# Using 'add' — if chain exists, nft silently succeeds
	nft add chain inet "$MERGEN_NFT_TABLE" "$MERGEN_NFT_CHAIN" \
		'{ type filter hook prerouting priority -150 ; }' 2>/dev/null

	if ! nft list table inet "$MERGEN_NFT_TABLE" >/dev/null 2>&1; then
		mergen_log "error" "NFT" "[!] Hata: nftables tablosu oluşturulamadı."
		return 1
	fi

	mergen_log "debug" "NFT" "nftables tablosu hazır: inet ${MERGEN_NFT_TABLE}"
	return 0
}

# Create an nftables set for a rule
# Usage: mergen_nft_set_create <rule_name>
# Returns 0 on success, 1 on failure
mergen_nft_set_create() {
	local rule_name="$1"
	local set_name="mergen_${rule_name}"

	if [ -z "$rule_name" ]; then
		mergen_log "error" "NFT" "[!] Hata: Kural adı belirtilmeli."
		return 1
	fi

	if ! mergen_nft_available; then
		mergen_log "error" "NFT" "[!] Hata: nftables (nft) komutu bulunamadı."
		return 1
	fi

	# Ensure table exists
	mergen_nft_init || return 1

	# Create IPv4 set with interval flag (for CIDR ranges)
	if ! nft add set inet "$MERGEN_NFT_TABLE" "$set_name" \
		'{ type ipv4_addr ; flags interval ; }' 2>/dev/null; then
		# Set might already exist — check
		if nft list set inet "$MERGEN_NFT_TABLE" "$set_name" >/dev/null 2>&1; then
			mergen_log "debug" "NFT" "Set zaten mevcut: ${set_name}"
			return 0
		fi
		mergen_log "error" "NFT" "[!] Hata: nftables set oluşturulamadı: ${set_name}"
		return 1
	fi

	mergen_log "debug" "NFT" "Set oluşturuldu: ${set_name}"
	return 0
}

# Add prefixes to an nftables set (bulk via batch file)
# Usage: mergen_nft_set_add <rule_name> <prefix_list>
#   prefix_list: newline-separated CIDR prefixes
# Returns 0 on success, 1 on failure
mergen_nft_set_add() {
	local rule_name="$1"
	local prefix_list="$2"
	local set_name="mergen_${rule_name}"

	if [ -z "$rule_name" ] || [ -z "$prefix_list" ]; then
		mergen_log "error" "NFT" "[!] Hata: Kural adı ve prefix listesi gerekli."
		return 1
	fi

	# Build batch file for nft -f (much faster than individual add commands)
	local batch_file="${MERGEN_TMP:-/tmp/mergen}/nft_batch_${rule_name}.nft"
	local elements_file="${MERGEN_TMP:-/tmp/mergen}/nft_elements_${rule_name}.tmp"
	[ -d "${MERGEN_TMP:-/tmp/mergen}" ] || mkdir -p "${MERGEN_TMP:-/tmp/mergen}"

	# Start batch with flush
	printf 'flush set inet %s %s\n' "$MERGEN_NFT_TABLE" "$set_name" > "$batch_file"

	# Write clean prefix list to temp file to avoid subshell variable loss
	echo "$prefix_list" | sed '/^$/d' > "$elements_file"

	# Chunk prefixes into groups of 200 per add element command
	local chunk="" chunk_count=0
	while IFS= read -r prefix; do
		if [ -z "$chunk" ]; then
			chunk="$prefix"
		else
			chunk="${chunk}, ${prefix}"
		fi
		chunk_count=$((chunk_count + 1))

		if [ "$chunk_count" -ge 200 ]; then
			printf 'add element inet %s %s { %s }\n' \
				"$MERGEN_NFT_TABLE" "$set_name" "$chunk" >> "$batch_file"
			chunk=""
			chunk_count=0
		fi
	done < "$elements_file"

	# Remaining chunk
	if [ -n "$chunk" ]; then
		printf 'add element inet %s %s { %s }\n' \
			"$MERGEN_NFT_TABLE" "$set_name" "$chunk" >> "$batch_file"
	fi

	rm -f "$elements_file"

	# Execute batch
	if ! nft -f "$batch_file" 2>/dev/null; then
		mergen_log "error" "NFT" "[!] Hata: Prefix'ler set'e eklenemedi: ${set_name}"
		rm -f "$batch_file"
		return 1
	fi

	rm -f "$batch_file"

	local count
	count="$(echo "$prefix_list" | sed '/^$/d' | wc -l | tr -d ' ')"
	mergen_log "info" "NFT" "Set '${set_name}' güncellendi: ${count} prefix"
	return 0
}

# Flush (clear) all elements from an nftables set
# Usage: mergen_nft_set_flush <rule_name>
# Returns 0 on success, 1 on failure
mergen_nft_set_flush() {
	local rule_name="$1"
	local set_name="mergen_${rule_name}"

	if ! mergen_nft_available; then
		return 1
	fi

	nft flush set inet "$MERGEN_NFT_TABLE" "$set_name" 2>/dev/null
	return $?
}

# Destroy an nftables set and its associated fwmark rule
# Usage: mergen_nft_set_destroy <rule_name>
# Returns 0 on success, 1 on failure
mergen_nft_set_destroy() {
	local rule_name="$1"
	local set_name="mergen_${rule_name}"

	if ! mergen_nft_available; then
		return 0
	fi

	# First remove the fwmark rule referencing this set
	# Find the rule handle by grepping for @set_name
	local handle
	handle="$(nft -a list chain inet "$MERGEN_NFT_TABLE" "$MERGEN_NFT_CHAIN" 2>/dev/null | \
		grep "@${set_name}" | sed -n 's/.*# handle \([0-9]*\)/\1/p')"

	if [ -n "$handle" ]; then
		local h
		for h in $handle; do
			nft delete rule inet "$MERGEN_NFT_TABLE" "$MERGEN_NFT_CHAIN" handle "$h" 2>/dev/null
		done
	fi

	# Delete the set
	nft delete set inet "$MERGEN_NFT_TABLE" "$set_name" 2>/dev/null

	mergen_log "debug" "NFT" "Set kaldırıldı: ${set_name}"
	return 0
}

# Add a fwmark rule for a set
# Usage: mergen_nft_rule_add <rule_name> <fwmark>
# Creates: ip daddr @mergen_{rule_name} meta mark set {fwmark}
# Returns 0 on success, 1 on failure
mergen_nft_rule_add() {
	local rule_name="$1"
	local fwmark="$2"
	local set_name="mergen_${rule_name}"

	if [ -z "$rule_name" ] || [ -z "$fwmark" ]; then
		mergen_log "error" "NFT" "[!] Hata: Kural adı ve fwmark değeri gerekli."
		return 1
	fi

	if ! mergen_nft_available; then
		mergen_log "error" "NFT" "[!] Hata: nftables (nft) komutu bulunamadı."
		return 1
	fi

	# Check if a rule for this set already exists — avoid duplicates
	if nft -a list chain inet "$MERGEN_NFT_TABLE" "$MERGEN_NFT_CHAIN" 2>/dev/null | \
		grep -q "@${set_name}"; then
		mergen_log "debug" "NFT" "fwmark kuralı zaten mevcut: ${set_name}"
		return 0
	fi

	if ! nft add rule inet "$MERGEN_NFT_TABLE" "$MERGEN_NFT_CHAIN" \
		ip daddr "@${set_name}" meta mark set "$fwmark" 2>/dev/null; then
		mergen_log "error" "NFT" "[!] Hata: fwmark kuralı eklenemedi: ${set_name} -> ${fwmark}"
		return 1
	fi

	mergen_log "debug" "NFT" "fwmark kuralı eklendi: @${set_name} -> mark ${fwmark}"
	return 0
}

# Clean up all mergen nftables resources (table, chains, sets)
# Used during full remove or rollback
# Returns 0 always
mergen_nft_cleanup() {
	if ! mergen_nft_available; then
		return 0
	fi

	nft delete table inet "$MERGEN_NFT_TABLE" 2>/dev/null
	mergen_log "debug" "NFT" "nftables tablosu temizlendi: inet ${MERGEN_NFT_TABLE}"
	return 0
}

# Get the nftables set element count for a rule
# Usage: mergen_nft_set_count <rule_name>
# Prints the count, returns 0 if set exists, 1 otherwise
mergen_nft_set_count() {
	local rule_name="$1"
	local set_name="mergen_${rule_name}"

	if ! mergen_nft_available; then
		echo "0"
		return 1
	fi

	local output
	output="$(nft list set inet "$MERGEN_NFT_TABLE" "$set_name" 2>/dev/null)"
	if [ -z "$output" ]; then
		echo "0"
		return 1
	fi

	# Count elements: each prefix is a separate entry
	local count
	count="$(echo "$output" | grep -c '[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+')"
	echo "${count:-0}"
	return 0
}

# Save nftables state to snapshot directory
# Called by mergen_snapshot_create
mergen_nft_snapshot_save() {
	if ! mergen_nft_available; then
		return 0
	fi

	if nft list table inet "$MERGEN_NFT_TABLE" >/dev/null 2>&1; then
		nft list table inet "$MERGEN_NFT_TABLE" > "${MERGEN_SNAPSHOT_DIR}/nftsets.save" 2>/dev/null
		mergen_log "debug" "NFT" "nftables durumu snapshot'a kaydedildi."
	fi
	return 0
}

# Restore nftables state from snapshot
# Called by mergen_snapshot_restore
mergen_nft_snapshot_restore() {
	if ! mergen_nft_available; then
		return 0
	fi

	if [ -f "${MERGEN_SNAPSHOT_DIR}/nftsets.save" ]; then
		# Delete existing table first
		nft delete table inet "$MERGEN_NFT_TABLE" 2>/dev/null
		# Restore from snapshot (nft list table output is valid nft input)
		nft -f "${MERGEN_SNAPSHOT_DIR}/nftsets.save" 2>/dev/null
		mergen_log "debug" "NFT" "nftables durumu snapshot'tan geri yüklendi."
	fi
	return 0
}

# ── nftables IPv6 Set Management ─────────────────────────────

# Create an nftables set for IPv6 addresses
# Usage: mergen_nft_set_create_v6 <rule_name>
mergen_nft_set_create_v6() {
	local rule_name="$1"
	local set_name="mergen_${rule_name}_v6"

	if [ -z "$rule_name" ]; then
		mergen_log "error" "NFT" "[!] Hata: Kural adı belirtilmeli."
		return 1
	fi

	if ! mergen_nft_available; then
		mergen_log "error" "NFT" "[!] Hata: nftables (nft) komutu bulunamadı."
		return 1
	fi

	mergen_nft_init || return 1

	if ! nft add set inet "$MERGEN_NFT_TABLE" "$set_name" \
		'{ type ipv6_addr ; flags interval ; }' 2>/dev/null; then
		if nft list set inet "$MERGEN_NFT_TABLE" "$set_name" >/dev/null 2>&1; then
			mergen_log "debug" "NFT" "IPv6 set zaten mevcut: ${set_name}"
			return 0
		fi
		mergen_log "error" "NFT" "[!] Hata: IPv6 nftables set oluşturulamadı: ${set_name}"
		return 1
	fi

	mergen_log "debug" "NFT" "IPv6 set oluşturuldu: ${set_name}"
	return 0
}

# Add IPv6 prefixes to an nftables set (bulk via batch file)
# Usage: mergen_nft_set_add_v6 <rule_name> <prefix_list>
mergen_nft_set_add_v6() {
	local rule_name="$1"
	local prefix_list="$2"
	local set_name="mergen_${rule_name}_v6"

	if [ -z "$rule_name" ] || [ -z "$prefix_list" ]; then
		mergen_log "error" "NFT" "[!] Hata: Kural adı ve prefix listesi gerekli."
		return 1
	fi

	local batch_file="${MERGEN_TMP:-/tmp/mergen}/nft_batch_${rule_name}_v6.nft"
	local elements_file="${MERGEN_TMP:-/tmp/mergen}/nft_elements_${rule_name}_v6.tmp"
	[ -d "${MERGEN_TMP:-/tmp/mergen}" ] || mkdir -p "${MERGEN_TMP:-/tmp/mergen}"

	printf 'flush set inet %s %s\n' "$MERGEN_NFT_TABLE" "$set_name" > "$batch_file"
	echo "$prefix_list" | sed '/^$/d' > "$elements_file"

	local chunk="" chunk_count=0
	while IFS= read -r prefix; do
		if [ -z "$chunk" ]; then
			chunk="$prefix"
		else
			chunk="${chunk}, ${prefix}"
		fi
		chunk_count=$((chunk_count + 1))

		if [ "$chunk_count" -ge 200 ]; then
			printf 'add element inet %s %s { %s }\n' \
				"$MERGEN_NFT_TABLE" "$set_name" "$chunk" >> "$batch_file"
			chunk=""
			chunk_count=0
		fi
	done < "$elements_file"

	if [ -n "$chunk" ]; then
		printf 'add element inet %s %s { %s }\n' \
			"$MERGEN_NFT_TABLE" "$set_name" "$chunk" >> "$batch_file"
	fi

	rm -f "$elements_file"

	if ! nft -f "$batch_file" 2>/dev/null; then
		mergen_log "error" "NFT" "[!] Hata: IPv6 prefix'ler set'e eklenemedi: ${set_name}"
		rm -f "$batch_file"
		return 1
	fi

	rm -f "$batch_file"

	local count
	count="$(echo "$prefix_list" | sed '/^$/d' | wc -l | tr -d ' ')"
	mergen_log "info" "NFT" "IPv6 set '${set_name}' güncellendi: ${count} prefix"
	return 0
}

# Destroy an IPv6 nftables set and its associated fwmark rule
# Usage: mergen_nft_set_destroy_v6 <rule_name>
mergen_nft_set_destroy_v6() {
	local rule_name="$1"
	local set_name="mergen_${rule_name}_v6"

	if ! mergen_nft_available; then
		return 0
	fi

	local handle
	handle="$(nft -a list chain inet "$MERGEN_NFT_TABLE" "$MERGEN_NFT_CHAIN" 2>/dev/null | \
		grep "@${set_name}" | sed -n 's/.*# handle \([0-9]*\)/\1/p')"

	if [ -n "$handle" ]; then
		local h
		for h in $handle; do
			nft delete rule inet "$MERGEN_NFT_TABLE" "$MERGEN_NFT_CHAIN" handle "$h" 2>/dev/null
		done
	fi

	nft delete set inet "$MERGEN_NFT_TABLE" "$set_name" 2>/dev/null

	mergen_log "debug" "NFT" "IPv6 set kaldırıldı: ${set_name}"
	return 0
}

# Add an IPv6 fwmark rule for a set
# Usage: mergen_nft_rule_add_v6 <rule_name> <fwmark>
# Creates: ip6 daddr @mergen_{rule_name}_v6 meta mark set {fwmark}
mergen_nft_rule_add_v6() {
	local rule_name="$1"
	local fwmark="$2"
	local set_name="mergen_${rule_name}_v6"

	if [ -z "$rule_name" ] || [ -z "$fwmark" ]; then
		mergen_log "error" "NFT" "[!] Hata: Kural adı ve fwmark değeri gerekli."
		return 1
	fi

	if ! mergen_nft_available; then
		mergen_log "error" "NFT" "[!] Hata: nftables (nft) komutu bulunamadı."
		return 1
	fi

	if nft -a list chain inet "$MERGEN_NFT_TABLE" "$MERGEN_NFT_CHAIN" 2>/dev/null | \
		grep -q "@${set_name}"; then
		mergen_log "debug" "NFT" "IPv6 fwmark kuralı zaten mevcut: ${set_name}"
		return 0
	fi

	if ! nft add rule inet "$MERGEN_NFT_TABLE" "$MERGEN_NFT_CHAIN" \
		ip6 daddr "@${set_name}" meta mark set "$fwmark" 2>/dev/null; then
		mergen_log "error" "NFT" "[!] Hata: IPv6 fwmark kuralı eklenemedi: ${set_name} -> ${fwmark}"
		return 1
	fi

	mergen_log "debug" "NFT" "IPv6 fwmark kuralı eklendi: @${set_name} -> mark ${fwmark}"
	return 0
}

# ── ipset Fallback ───────────────────────────────────────────

MERGEN_IPSET_AVAILABLE=""

# Check if ipset command is available
mergen_ipset_available() {
	if [ -z "$MERGEN_IPSET_AVAILABLE" ]; then
		if command -v ipset >/dev/null 2>&1; then
			MERGEN_IPSET_AVAILABLE="1"
		else
			MERGEN_IPSET_AVAILABLE="0"
		fi
	fi
	[ "$MERGEN_IPSET_AVAILABLE" = "1" ]
}

# Create an ipset for a rule
# Usage: mergen_ipset_create <rule_name>
mergen_ipset_create() {
	local rule_name="$1"
	local set_name="mergen_${rule_name}"

	if [ -z "$rule_name" ]; then
		mergen_log "error" "IPSET" "[!] Hata: Kural adı belirtilmeli."
		return 1
	fi

	if ! mergen_ipset_available; then
		mergen_log "error" "IPSET" "[!] Hata: ipset komutu bulunamadı."
		return 1
	fi

	# Create hash:net set (idempotent with -exist)
	if ! ipset create "$set_name" hash:net -exist 2>/dev/null; then
		mergen_log "error" "IPSET" "[!] Hata: ipset oluşturulamadı: ${set_name}"
		return 1
	fi

	mergen_log "debug" "IPSET" "Set oluşturuldu: ${set_name}"
	return 0
}

# Add prefixes to an ipset (bulk via ipset restore)
# Usage: mergen_ipset_add <rule_name> <prefix_list>
mergen_ipset_add() {
	local rule_name="$1"
	local prefix_list="$2"
	local set_name="mergen_${rule_name}"

	if [ -z "$rule_name" ] || [ -z "$prefix_list" ]; then
		mergen_log "error" "IPSET" "[!] Hata: Kural adı ve prefix listesi gerekli."
		return 1
	fi

	# Build restore file for bulk loading
	local restore_file="${MERGEN_TMP:-/tmp/mergen}/ipset_restore_${rule_name}.txt"
	[ -d "${MERGEN_TMP:-/tmp/mergen}" ] || mkdir -p "${MERGEN_TMP:-/tmp/mergen}"

	{
		# Flush existing entries first
		printf 'flush %s\n' "$set_name"
		# Add each prefix
		echo "$prefix_list" | sed '/^$/d' | while IFS= read -r prefix; do
			printf 'add %s %s\n' "$set_name" "$prefix"
		done
	} > "$restore_file"

	if ! ipset restore -exist < "$restore_file" 2>/dev/null; then
		mergen_log "error" "IPSET" "[!] Hata: Prefix'ler set'e eklenemedi: ${set_name}"
		rm -f "$restore_file"
		return 1
	fi

	rm -f "$restore_file"

	local count
	count="$(echo "$prefix_list" | sed '/^$/d' | wc -l | tr -d ' ')"
	mergen_log "info" "IPSET" "Set '${set_name}' güncellendi: ${count} prefix"
	return 0
}

# Flush all elements from an ipset
# Usage: mergen_ipset_flush <rule_name>
mergen_ipset_flush() {
	local rule_name="$1"
	local set_name="mergen_${rule_name}"

	if ! mergen_ipset_available; then
		return 1
	fi

	ipset flush "$set_name" 2>/dev/null
	return $?
}

# Destroy an ipset and its associated iptables MARK rule
# Usage: mergen_ipset_destroy <rule_name>
mergen_ipset_destroy() {
	local rule_name="$1"
	local set_name="mergen_${rule_name}"

	if ! mergen_ipset_available; then
		return 0
	fi

	# Remove iptables MARK rules referencing this set
	# Loop to remove all matching rules (there might be duplicates)
	local max=100 i=0
	while iptables -t mangle -D PREROUTING \
		-m set --match-set "$set_name" dst -j MARK --set-mark 0/0 2>/dev/null || \
		iptables -t mangle -D PREROUTING \
		-m set --match-set "$set_name" dst -j MARK 2>/dev/null; do
		i=$((i + 1))
		[ "$i" -ge "$max" ] && break
	done

	# Destroy the set
	ipset destroy "$set_name" 2>/dev/null

	mergen_log "debug" "IPSET" "Set kaldırıldı: ${set_name}"
	return 0
}

# Add an iptables MARK rule for an ipset
# Usage: mergen_ipset_mark_add <rule_name> <fwmark>
mergen_ipset_mark_add() {
	local rule_name="$1"
	local fwmark="$2"
	local set_name="mergen_${rule_name}"

	if [ -z "$rule_name" ] || [ -z "$fwmark" ]; then
		mergen_log "error" "IPSET" "[!] Hata: Kural adı ve fwmark değeri gerekli."
		return 1
	fi

	if ! mergen_ipset_available; then
		mergen_log "error" "IPSET" "[!] Hata: ipset komutu bulunamadı."
		return 1
	fi

	# Check if rule already exists
	if iptables -t mangle -C PREROUTING \
		-m set --match-set "$set_name" dst -j MARK --set-mark "$fwmark" 2>/dev/null; then
		mergen_log "debug" "IPSET" "MARK kuralı zaten mevcut: ${set_name}"
		return 0
	fi

	if ! iptables -t mangle -A PREROUTING \
		-m set --match-set "$set_name" dst -j MARK --set-mark "$fwmark" 2>/dev/null; then
		mergen_log "error" "IPSET" "[!] Hata: MARK kuralı eklenemedi: ${set_name} -> ${fwmark}"
		return 1
	fi

	mergen_log "debug" "IPSET" "MARK kuralı eklendi: ${set_name} -> mark ${fwmark}"
	return 0
}

# Clean up all mergen ipset resources
mergen_ipset_cleanup() {
	if ! mergen_ipset_available; then
		return 0
	fi

	# Remove all iptables MARK rules referencing mergen_ sets
	# List all mergen ipsets and remove associated rules
	local set_name
	ipset list -n 2>/dev/null | grep '^mergen_' | while IFS= read -r set_name; do
		local max=100 i=0
		while iptables -t mangle -D PREROUTING \
			-m set --match-set "$set_name" dst -j MARK 2>/dev/null; do
			i=$((i + 1))
			[ "$i" -ge "$max" ] && break
		done
		ipset destroy "$set_name" 2>/dev/null
	done

	mergen_log "debug" "IPSET" "Tüm ipset kaynakları temizlendi."
	return 0
}

# Save ipset state to snapshot directory
mergen_ipset_snapshot_save() {
	if ! mergen_ipset_available; then
		return 0
	fi

	ipset save 2>/dev/null | grep 'mergen_' > "${MERGEN_SNAPSHOT_DIR}/ipsets.save" 2>/dev/null
	if [ -s "${MERGEN_SNAPSHOT_DIR}/ipsets.save" ]; then
		mergen_log "debug" "IPSET" "ipset durumu snapshot'a kaydedildi."
	fi
	return 0
}

# Restore ipset state from snapshot
mergen_ipset_snapshot_restore() {
	if ! mergen_ipset_available; then
		return 0
	fi

	if [ -f "${MERGEN_SNAPSHOT_DIR}/ipsets.save" ]; then
		# Destroy existing mergen sets first
		ipset list -n 2>/dev/null | grep '^mergen_' | while IFS= read -r set_name; do
			ipset destroy "$set_name" 2>/dev/null
		done
		# Restore from snapshot
		ipset restore -exist < "${MERGEN_SNAPSHOT_DIR}/ipsets.save" 2>/dev/null
		mergen_log "debug" "IPSET" "ipset durumu snapshot'tan geri yüklendi."
	fi
	return 0
}

# ── ipset IPv6 Fallback ──────────────────────────────────────

# Create an ipset for IPv6 addresses
# Usage: mergen_ipset_create_v6 <rule_name>
mergen_ipset_create_v6() {
	local rule_name="$1"
	local set_name="mergen_${rule_name}_v6"

	if [ -z "$rule_name" ]; then
		mergen_log "error" "IPSET" "[!] Hata: Kural adı belirtilmeli."
		return 1
	fi

	if ! mergen_ipset_available; then
		mergen_log "error" "IPSET" "[!] Hata: ipset komutu bulunamadı."
		return 1
	fi

	if ! ipset create "$set_name" hash:net family inet6 -exist 2>/dev/null; then
		mergen_log "error" "IPSET" "[!] Hata: IPv6 ipset oluşturulamadı: ${set_name}"
		return 1
	fi

	mergen_log "debug" "IPSET" "IPv6 set oluşturuldu: ${set_name}"
	return 0
}

# Add IPv6 prefixes to an ipset (bulk via ipset restore)
# Usage: mergen_ipset_add_v6 <rule_name> <prefix_list>
mergen_ipset_add_v6() {
	local rule_name="$1"
	local prefix_list="$2"
	local set_name="mergen_${rule_name}_v6"

	if [ -z "$rule_name" ] || [ -z "$prefix_list" ]; then
		mergen_log "error" "IPSET" "[!] Hata: Kural adı ve prefix listesi gerekli."
		return 1
	fi

	local restore_file="${MERGEN_TMP:-/tmp/mergen}/ipset_restore_${rule_name}_v6.txt"
	[ -d "${MERGEN_TMP:-/tmp/mergen}" ] || mkdir -p "${MERGEN_TMP:-/tmp/mergen}"

	{
		printf 'flush %s\n' "$set_name"
		echo "$prefix_list" | sed '/^$/d' | while IFS= read -r prefix; do
			printf 'add %s %s\n' "$set_name" "$prefix"
		done
	} > "$restore_file"

	if ! ipset restore -exist < "$restore_file" 2>/dev/null; then
		mergen_log "error" "IPSET" "[!] Hata: IPv6 prefix'ler set'e eklenemedi: ${set_name}"
		rm -f "$restore_file"
		return 1
	fi

	rm -f "$restore_file"

	local count
	count="$(echo "$prefix_list" | sed '/^$/d' | wc -l | tr -d ' ')"
	mergen_log "info" "IPSET" "IPv6 set '${set_name}' güncellendi: ${count} prefix"
	return 0
}

# Destroy an IPv6 ipset and its associated ip6tables MARK rule
# Usage: mergen_ipset_destroy_v6 <rule_name>
mergen_ipset_destroy_v6() {
	local rule_name="$1"
	local set_name="mergen_${rule_name}_v6"

	if ! mergen_ipset_available; then
		return 0
	fi

	local max=100 i=0
	while ip6tables -t mangle -D PREROUTING \
		-m set --match-set "$set_name" dst -j MARK --set-mark 0/0 2>/dev/null || \
		ip6tables -t mangle -D PREROUTING \
		-m set --match-set "$set_name" dst -j MARK 2>/dev/null; do
		i=$((i + 1))
		[ "$i" -ge "$max" ] && break
	done

	ipset destroy "$set_name" 2>/dev/null

	mergen_log "debug" "IPSET" "IPv6 set kaldırıldı: ${set_name}"
	return 0
}

# Add an ip6tables MARK rule for an IPv6 ipset
# Usage: mergen_ipset_mark_add_v6 <rule_name> <fwmark>
mergen_ipset_mark_add_v6() {
	local rule_name="$1"
	local fwmark="$2"
	local set_name="mergen_${rule_name}_v6"

	if [ -z "$rule_name" ] || [ -z "$fwmark" ]; then
		mergen_log "error" "IPSET" "[!] Hata: Kural adı ve fwmark değeri gerekli."
		return 1
	fi

	if ! mergen_ipset_available; then
		mergen_log "error" "IPSET" "[!] Hata: ipset komutu bulunamadı."
		return 1
	fi

	if ip6tables -t mangle -C PREROUTING \
		-m set --match-set "$set_name" dst -j MARK --set-mark "$fwmark" 2>/dev/null; then
		mergen_log "debug" "IPSET" "IPv6 MARK kuralı zaten mevcut: ${set_name}"
		return 0
	fi

	if ! ip6tables -t mangle -A PREROUTING \
		-m set --match-set "$set_name" dst -j MARK --set-mark "$fwmark" 2>/dev/null; then
		mergen_log "error" "IPSET" "[!] Hata: IPv6 MARK kuralı eklenemedi: ${set_name} -> ${fwmark}"
		return 1
	fi

	mergen_log "debug" "IPSET" "IPv6 MARK kuralı eklendi: ${set_name} -> mark ${fwmark}"
	return 0
}

# ── Packet Engine Abstraction ────────────────────────────────

# Engine detection: auto → nftables → ipset → none
# UCI setting: mergen.global.packet_engine (auto/nftables/ipset)
MERGEN_ENGINE_ACTIVE=""

# Detect and set the active packet engine
# Caches result in MERGEN_ENGINE_ACTIVE
mergen_engine_detect() {
	if [ -n "$MERGEN_ENGINE_ACTIVE" ]; then
		return 0
	fi

	# Read UCI preference
	mergen_uci_get "global" "packet_engine" "auto"
	local preference="$MERGEN_UCI_RESULT"

	case "$preference" in
		nftables)
			if mergen_nft_available; then
				MERGEN_ENGINE_ACTIVE="nftables"
			else
				mergen_log "error" "Engine" "[!] Hata: nftables seçildi ama nft komutu bulunamadı."
				MERGEN_ENGINE_ACTIVE="none"
			fi
			;;
		ipset)
			if mergen_ipset_available; then
				MERGEN_ENGINE_ACTIVE="ipset"
			else
				mergen_log "error" "Engine" "[!] Hata: ipset seçildi ama ipset komutu bulunamadı."
				MERGEN_ENGINE_ACTIVE="none"
			fi
			;;
		auto|*)
			if mergen_nft_available; then
				MERGEN_ENGINE_ACTIVE="nftables"
			elif mergen_ipset_available; then
				MERGEN_ENGINE_ACTIVE="ipset"
			else
				MERGEN_ENGINE_ACTIVE="none"
			fi
			;;
	esac

	mergen_log "info" "Engine" "Paket motoru: ${MERGEN_ENGINE_ACTIVE}"
	return 0
}

# Get the active engine name (for status/diag commands)
mergen_engine_info() {
	mergen_engine_detect
	echo "$MERGEN_ENGINE_ACTIVE"
}

# ── Common Interface (dispatches to nftables or ipset) ───────

mergen_set_create() {
	mergen_engine_detect
	case "$MERGEN_ENGINE_ACTIVE" in
		nftables) mergen_nft_set_create "$@" ;;
		ipset)    mergen_ipset_create "$@" ;;
		*)        return 1 ;;
	esac
}

mergen_set_add() {
	mergen_engine_detect
	case "$MERGEN_ENGINE_ACTIVE" in
		nftables) mergen_nft_set_add "$@" ;;
		ipset)    mergen_ipset_add "$@" ;;
		*)        return 1 ;;
	esac
}

mergen_set_flush() {
	mergen_engine_detect
	case "$MERGEN_ENGINE_ACTIVE" in
		nftables) mergen_nft_set_flush "$@" ;;
		ipset)    mergen_ipset_flush "$@" ;;
		*)        return 1 ;;
	esac
}

mergen_set_destroy() {
	mergen_engine_detect
	case "$MERGEN_ENGINE_ACTIVE" in
		nftables) mergen_nft_set_destroy "$@" ;;
		ipset)    mergen_ipset_destroy "$@" ;;
		*)        return 0 ;;
	esac
}

mergen_set_mark_rule() {
	mergen_engine_detect
	case "$MERGEN_ENGINE_ACTIVE" in
		nftables) mergen_nft_rule_add "$@" ;;
		ipset)    mergen_ipset_mark_add "$@" ;;
		*)        return 1 ;;
	esac
}

mergen_set_cleanup() {
	mergen_engine_detect
	case "$MERGEN_ENGINE_ACTIVE" in
		nftables) mergen_nft_cleanup ;;
		ipset)    mergen_ipset_cleanup ;;
		*)        return 0 ;;
	esac
}

mergen_set_snapshot_save() {
	mergen_engine_detect
	case "$MERGEN_ENGINE_ACTIVE" in
		nftables) mergen_nft_snapshot_save ;;
		ipset)    mergen_ipset_snapshot_save ;;
	esac
	return 0
}

mergen_set_snapshot_restore() {
	mergen_engine_detect
	case "$MERGEN_ENGINE_ACTIVE" in
		nftables) mergen_nft_snapshot_restore ;;
		ipset)    mergen_ipset_snapshot_restore ;;
	esac
	return 0
}

# ── Common Interface IPv6 (dispatches to nftables or ipset) ────

mergen_set_create_v6() {
	mergen_engine_detect
	case "$MERGEN_ENGINE_ACTIVE" in
		nftables) mergen_nft_set_create_v6 "$@" ;;
		ipset)    mergen_ipset_create_v6 "$@" ;;
		*)        return 1 ;;
	esac
}

mergen_set_add_v6() {
	mergen_engine_detect
	case "$MERGEN_ENGINE_ACTIVE" in
		nftables) mergen_nft_set_add_v6 "$@" ;;
		ipset)    mergen_ipset_add_v6 "$@" ;;
		*)        return 1 ;;
	esac
}

mergen_set_destroy_v6() {
	mergen_engine_detect
	case "$MERGEN_ENGINE_ACTIVE" in
		nftables) mergen_nft_set_destroy_v6 "$@" ;;
		ipset)    mergen_ipset_destroy_v6 "$@" ;;
		*)        return 0 ;;
	esac
}

mergen_set_mark_rule_v6() {
	mergen_engine_detect
	case "$MERGEN_ENGINE_ACTIVE" in
		nftables) mergen_nft_rule_add_v6 "$@" ;;
		ipset)    mergen_ipset_mark_add_v6 "$@" ;;
		*)        return 1 ;;
	esac
}

# ── DNS-Based Routing (dnsmasq integration) ───────────────

MERGEN_DNSMASQ_DIR="/tmp/dnsmasq.d"
MERGEN_DNSMASQ_CONF_PREFIX="mergen-dns-"

# Apply domain-based routing rule via dnsmasq nftset/ipset integration
# Creates nft/ipset sets, writes dnsmasq drop-in config, restarts dnsmasq
# Usage: mergen_dnsmasq_apply <rule_name> <domains> <table_num> <via> <priority>
mergen_dnsmasq_apply() {
	local rule_name="$1"
	local domains="$2"
	local table_num="$3"
	local via="$4"
	local priority="$5"

	if [ -z "$rule_name" ] || [ -z "$domains" ]; then
		mergen_log "error" "DNS" "[!] Hata: Kural adı ve domain listesi gerekli."
		return 1
	fi

	mergen_log "info" "DNS" "Domain kuralı '${rule_name}' uygulanıyor..."

	# Detect gateway for the interface
	if ! mergen_detect_gateway "$via"; then
		return 1
	fi
	local gateway="$MERGEN_GATEWAY_ADDR"

	# Add default route via gateway to the routing table
	ip route add default via "$gateway" dev "$via" table "$table_num" 2>/dev/null || \
		ip route replace default via "$gateway" dev "$via" table "$table_num" 2>/dev/null

	# Detect set engine
	mergen_engine_detect
	local set_name="mergen_${rule_name}"

	# Create the set and fwmark rule
	if [ "$MERGEN_ENGINE_ACTIVE" = "nftables" ]; then
		# Create nft set (IPv4)
		if mergen_set_create "$rule_name"; then
			mergen_set_mark_rule "$rule_name" "$table_num"
			ip rule add fwmark "$table_num" lookup "$table_num" priority "$priority" 2>/dev/null
		fi

		# Create nft set (IPv6) if enabled
		mergen_uci_get "global" "ipv6_enabled" "0"
		local ipv6_enabled="$MERGEN_UCI_RESULT"
		if [ "$ipv6_enabled" = "1" ]; then
			if mergen_set_create_v6 "$rule_name"; then
				mergen_set_mark_rule_v6 "$rule_name" "$table_num"
				ip -6 rule add fwmark "$table_num" lookup "$table_num" priority "$priority" 2>/dev/null
			fi
		fi
	elif [ "$MERGEN_ENGINE_ACTIVE" = "ipset" ]; then
		# Create ipset
		if mergen_set_create "$rule_name"; then
			mergen_set_mark_rule "$rule_name" "$table_num"
			ip rule add fwmark "$table_num" lookup "$table_num" priority "$priority" 2>/dev/null
		fi
	else
		mergen_log "error" "DNS" "[!] Hata: Domain kuralları için nftables veya ipset gerekli."
		return 1
	fi

	# Build dnsmasq config
	local conf_file="${MERGEN_DNSMASQ_DIR}/${MERGEN_DNSMASQ_CONF_PREFIX}${rule_name}.conf"
	mkdir -p "$MERGEN_DNSMASQ_DIR"

	# Generate dnsmasq entries for each domain
	local domain_item
	local nft_table="${MERGEN_NFT_TABLE:-mergen}"
	local dnsmasq_lines=""

	local IFS_SAVE="$IFS"
	IFS=' '
	for domain_item in $domains; do
		[ -z "$domain_item" ] && continue

		# Strip wildcard prefix — dnsmasq treats bare domain as wildcard
		case "$domain_item" in
			\*.) continue ;;
			\*.*) domain_item="${domain_item#\*.}" ;;
		esac

		if [ "$MERGEN_ENGINE_ACTIVE" = "nftables" ]; then
			# nftset directive: nftset=/<domain>/4#inet#<table>#<set>[,6#inet#<table>#<set_v6>]
			local nft_entry="nftset=/${domain_item}/4#inet#${nft_table}#${set_name}"
			if [ "$ipv6_enabled" = "1" ]; then
				nft_entry="${nft_entry},6#inet#${nft_table}#${set_name}_v6"
			fi
			dnsmasq_lines="${dnsmasq_lines}${nft_entry}
"
		elif [ "$MERGEN_ENGINE_ACTIVE" = "ipset" ]; then
			# ipset directive: ipset=/<domain>/<set_name>
			dnsmasq_lines="${dnsmasq_lines}ipset=/${domain_item}/${set_name}
"
		fi
	done
	IFS="$IFS_SAVE"

	if [ -z "$dnsmasq_lines" ]; then
		mergen_log "warning" "DNS" "Domain kuralı '${rule_name}' için dnsmasq girişi oluşturulamadı."
		return 1
	fi

	# Write dnsmasq config file
	cat > "$conf_file" <<DNSMASQEOF
# Mergen DNS-based routing: ${rule_name}
# Auto-generated — do not edit manually
${dnsmasq_lines}DNSMASQEOF

	mergen_log "info" "DNS" "dnsmasq yapılandırması yazıldı: ${conf_file}"

	# Restart dnsmasq to pick up the new config
	_mergen_dnsmasq_restart

	mergen_log "info" "DNS" "Domain kuralı '${rule_name}' uygulandı (${MERGEN_ENGINE_ACTIVE})"
	return 0
}

# Remove dnsmasq configuration for a domain rule
# Usage: mergen_dnsmasq_remove <rule_name>
mergen_dnsmasq_remove() {
	local rule_name="$1"
	local conf_file="${MERGEN_DNSMASQ_DIR}/${MERGEN_DNSMASQ_CONF_PREFIX}${rule_name}.conf"

	if [ -f "$conf_file" ]; then
		rm -f "$conf_file"
		mergen_log "info" "DNS" "dnsmasq yapılandırması silindi: ${conf_file}"
		_mergen_dnsmasq_restart
	fi
}

# Restart dnsmasq service (idempotent)
_mergen_dnsmasq_restart() {
	if [ -x /etc/init.d/dnsmasq ]; then
		/etc/init.d/dnsmasq restart >/dev/null 2>&1
		mergen_log "debug" "DNS" "dnsmasq yeniden başlatıldı."
	else
		mergen_log "warning" "DNS" "dnsmasq servisi bulunamadı."
	fi
}

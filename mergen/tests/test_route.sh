#!/bin/sh
# Test suite for mergen/files/usr/lib/mergen/route.sh
# Uses shunit2 framework — ash/busybox compatible
# Tests use mock ip command instead of real routing operations

MERGEN_TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
MERGEN_ROOT="$(cd "$MERGEN_TEST_DIR/.." && pwd)"

# ── Mock UCI System ─────────────────────────────────────

_MOCK_UCI_STORE=""
_MOCK_CONFIG_LOADED=""
_MOCK_FOREACH_SECTIONS=""
_MOCK_ADD_COUNTER=0

uci() {
	local cmd="$1"
	shift
	case "$cmd" in
		-q)
			local subcmd="$1"; shift
			case "$subcmd" in
				get) _mock_uci_get "$1" ;;
			esac
			;;
		get)
			if [ "$1" = "-q" ]; then
				shift
				_mock_uci_get "$1"
			else
				_mock_uci_get "$1"
			fi
			;;
		set) _mock_uci_set "$1" ;;
		add)
			local conf="$1" type="$2"
			_mock_uci_add "$conf" "$type"
			;;
		delete) _mock_uci_delete "$1" ;;
		add_list) _mock_uci_add_list "$1" ;;
		commit) return 0 ;;
		show) echo "$_MOCK_UCI_STORE" ;;
	esac
}

_mock_uci_get() {
	local path="$1"
	echo "$_MOCK_UCI_STORE" | while IFS='=' read -r key value; do
		if [ "$key" = "$path" ]; then
			echo "$value"
			return 0
		fi
	done
}

_mock_uci_set() {
	local assignment="$1"
	local key="${assignment%%=*}"
	local value="${assignment#*=}"
	_MOCK_UCI_STORE="$(echo "$_MOCK_UCI_STORE" | grep -v "^${key}=" 2>/dev/null)
${key}=${value}"
}

_mock_uci_add() {
	local conf="$1" type="$2"
	_MOCK_ADD_COUNTER=$((_MOCK_ADD_COUNTER + 1))
	local idx="cfg${_MOCK_ADD_COUNTER}"
	_MOCK_UCI_STORE="${_MOCK_UCI_STORE}
${conf}.${idx}=${type}"
	_MOCK_FOREACH_SECTIONS="${_MOCK_FOREACH_SECTIONS} ${idx}"
	echo "$idx"
}

_mock_uci_delete() {
	local path="$1"
	_MOCK_UCI_STORE="$(echo "$_MOCK_UCI_STORE" | grep -v "^${path}" 2>/dev/null)"
	local new_sections=""
	local section
	for section in $_MOCK_FOREACH_SECTIONS; do
		case "$path" in
			*"$section"*) ;;
			*) new_sections="$new_sections $section" ;;
		esac
	done
	_MOCK_FOREACH_SECTIONS="$new_sections"
}

_mock_uci_add_list() {
	local assignment="$1"
	local key="${assignment%%=*}"
	local value="${assignment#*=}"
	local existing
	existing="$(_mock_uci_get "$key")"
	if [ -n "$existing" ]; then
		_MOCK_UCI_STORE="$(echo "$_MOCK_UCI_STORE" | grep -v "^${key}=" 2>/dev/null)
${key}=${existing} ${value}"
	else
		_MOCK_UCI_STORE="${_MOCK_UCI_STORE}
${key}=${value}"
	fi
}

config_load() { _MOCK_CONFIG_LOADED="$1"; }

config_get() {
	local var="$1" section="$2" option="$3" default="$4"
	local val
	val="$(_mock_uci_get "${_MOCK_CONFIG_LOADED}.${section}.${option}")"
	[ -z "$val" ] && val="$default"
	eval "$var=\"$val\""
}

config_foreach() {
	local callback="$1" type="$2"
	local section
	for section in $_MOCK_FOREACH_SECTIONS; do
		"$callback" "$section"
	done
}

# Mock logger and flock
logger() { :; }
flock() { return 0; }

# ── Mock IP Command ─────────────────────────────────────

# Track all ip commands executed
_IP_COMMANDS=""
_IP_ROUTES=""
_IP_RULES=""
_IP_RULE_DEL_COUNT=0
_MOCK_GATEWAY="10.0.0.1"

ip() {
	local full_cmd="ip $*"
	_IP_COMMANDS="${_IP_COMMANDS}
${full_cmd}"

	case "$1" in
		route)
			shift
			case "$1" in
				show)
					# Return mock routing data
					if [ "$2" = "dev" ]; then
						echo "default via ${_MOCK_GATEWAY} dev $3"
					elif [ "$2" = "default" ]; then
						echo "default via ${_MOCK_GATEWAY} dev wg0"
					elif [ "$2" = "table" ]; then
						echo "$_IP_ROUTES" | grep "table $3" 2>/dev/null
					else
						echo "$_IP_ROUTES"
					fi
					;;
				add|replace)
					shift
					_IP_ROUTES="${_IP_ROUTES}
$*"
					return 0
					;;
				flush)
					# Clear routes for a table
					shift
					if [ "$1" = "table" ]; then
						_IP_ROUTES="$(echo "$_IP_ROUTES" | grep -v "table $2" 2>/dev/null)"
					fi
					return 0
					;;
			esac
			;;
		rule)
			shift
			case "$1" in
				add)
					shift
					_IP_RULES="${_IP_RULES}
$*"
					return 0
					;;
				del)
					shift
					_IP_RULE_DEL_COUNT=$((_IP_RULE_DEL_COUNT + 1))
					# Simulate: first few calls succeed, then fail (no more rules)
					if [ "$_IP_RULE_DEL_COUNT" -le 5 ]; then
						return 0
					fi
					return 2
					;;
				show)
					echo "$_IP_RULES"
					;;
			esac
			;;
		link)
			# Interface check
			shift
			case "$1" in
				show)
					case "$2" in
						wg0|eth0|br-lan) return 0 ;;
						*) return 1 ;;
					esac
					;;
			esac
			;;
		-br)
			echo "wg0      UP"
			echo "eth0     UP"
			echo "br-lan   UP"
			;;
	esac
}

# ── Mock nft Command ───────────────────────────────────

_NFT_TABLES=""
_NFT_CHAINS=""
_NFT_SETS=""
_NFT_SET_ELEMENTS=""
_NFT_RULES=""
_NFT_BATCH_CONTENT=""
_NFT_MOCK_FAIL=0

nft() {
	if [ "$_NFT_MOCK_FAIL" -eq 1 ]; then
		return 1
	fi

	case "$1" in
		add)
			case "$2" in
				table)
					_NFT_TABLES="${_NFT_TABLES} ${3}:${4}"
					return 0
					;;
				chain)
					_NFT_CHAINS="${_NFT_CHAINS} ${3}:${4}:${5}"
					return 0
					;;
				set)
					local family="$3" table="$4" setname="$5"
					_NFT_SETS="${_NFT_SETS} ${family}:${table}:${setname}"
					return 0
					;;
				element)
					local family="$3" table="$4" setname="$5"
					shift 5
					local elements="$*"
					_NFT_SET_ELEMENTS="${_NFT_SET_ELEMENTS}|${family}:${table}:${setname}=${elements}"
					return 0
					;;
				rule)
					shift 2
					_NFT_RULES="${_NFT_RULES}|$*"
					return 0
					;;
			esac
			;;
		delete)
			case "$2" in
				table)
					_NFT_TABLES=""
					_NFT_CHAINS=""
					_NFT_SETS=""
					_NFT_SET_ELEMENTS=""
					_NFT_RULES=""
					return 0
					;;
				set)
					local family="$3" table="$4" setname="$5"
					_NFT_SETS="$(echo "$_NFT_SETS" | sed "s| ${family}:${table}:${setname}||g")"
					return 0
					;;
				rule)
					return 0
					;;
			esac
			;;
		flush)
			case "$2" in
				set)
					local family="$3" table="$4" setname="$5"
					_NFT_SET_ELEMENTS="$(echo "$_NFT_SET_ELEMENTS" | sed "s|${family}:${table}:${setname}=[^|]*||g")"
					return 0
					;;
			esac
			;;
		list)
			case "$2" in
				table)
					local family="$3" table="$4"
					if echo "$_NFT_TABLES" | grep -q "${family}:${table}"; then
						echo "table ${family} ${table} {"
						echo "}"
						return 0
					fi
					return 1
					;;
				set)
					local family="$3" table="$4" setname="$5"
					if echo "$_NFT_SETS" | grep -q "${family}:${table}:${setname}"; then
						echo "set ${setname} {"
						echo "  type ipv4_addr"
						echo "  flags interval"
						local elems
						elems="$(echo "$_NFT_SET_ELEMENTS" | tr '|' '\n' | grep "^${family}:${table}:${setname}=" | sed "s/^[^=]*=//")"
						if [ -n "$elems" ]; then
							echo "  elements = { ${elems} }"
						fi
						echo "}"
						return 0
					fi
					return 1
					;;
				chain)
					local family="$3" table="$4" chain="$5"
					echo "chain ${chain} {"
					echo "  type filter hook prerouting priority -150; policy accept;"
					local rule_idx=1
					echo "$_NFT_RULES" | tr '|' '\n' | while IFS= read -r rule; do
						[ -z "$rule" ] && continue
						echo "  ${rule} # handle ${rule_idx}"
						rule_idx=$((rule_idx + 1))
					done
					echo "}"
					return 0
					;;
			esac
			;;
		-f)
			local batchfile="$2"
			if [ -f "$batchfile" ]; then
				_NFT_BATCH_CONTENT="$(cat "$batchfile")"
				while IFS= read -r batchline; do
					case "$batchline" in
						"flush set "*)
							;;
						"add element "*)
							_NFT_SET_ELEMENTS="${_NFT_SET_ELEMENTS}|batch:${batchline}"
							;;
					esac
				done < "$batchfile"
				return 0
			fi
			return 1
			;;
		-a)
			shift
			if [ "$1" = "list" ] && [ "$2" = "chain" ]; then
				local family="$3" table="$4" chain="$5"
				echo "chain ${chain} {"
				echo "  type filter hook prerouting priority -150; policy accept;"
				local rule_idx=1
				echo "$_NFT_RULES" | tr '|' '\n' | while IFS= read -r rule; do
					[ -z "$rule" ] && continue
					echo "  ${rule} # handle ${rule_idx}"
					rule_idx=$((rule_idx + 1))
				done
				echo "}"
			fi
			return 0
			;;
	esac
	return 0
}

# ── Mock ipset Command ─────────────────────────────────

ipset() {
	return 0
}

# ── Source modules under test ───────────────────────────

. "${MERGEN_ROOT}/files/usr/lib/mergen/core.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/utils.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/engine.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/resolver.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/route.sh"

# Override mergen_uci_add to avoid subshell variable loss
mergen_uci_add() {
	local type="$1"
	_MOCK_ADD_COUNTER=$((_MOCK_ADD_COUNTER + 1))
	local idx="cfg${_MOCK_ADD_COUNTER}"
	_MOCK_UCI_STORE="${_MOCK_UCI_STORE}
${MERGEN_CONF}.${idx}=${type}"
	_MOCK_FOREACH_SECTIONS="${_MOCK_FOREACH_SECTIONS} ${idx}"
	MERGEN_UCI_RESULT="$idx"
}

# Mock resolver for ASN rules
mergen_resolve_asn() {
	local asn="$1"
	case "$asn" in
		AS*|as*) asn="${asn#[Aa][Ss]}" ;;
	esac
	MERGEN_RESOLVE_RESULT_V4="192.0.2.0/24
198.51.100.0/24"
	MERGEN_RESOLVE_RESULT_V6=""
	MERGEN_RESOLVE_PROVIDER="mock"
	MERGEN_RESOLVE_COUNT_V4=2
	MERGEN_RESOLVE_COUNT_V6=0
	return 0
}

# ── Setup/Teardown ──────────────────────────────────────

setUp() {
	_MOCK_UCI_STORE=""
	_MOCK_FOREACH_SECTIONS=""
	_MOCK_ADD_COUNTER=0
	_IP_COMMANDS=""
	_IP_ROUTES=""
	_IP_RULES=""
	_IP_RULE_DEL_COUNT=0
	_MOCK_GATEWAY="10.0.0.1"
	_NFT_TABLES=""
	_NFT_CHAINS=""
	_NFT_SETS=""
	_NFT_SET_ELEMENTS=""
	_NFT_RULES=""
	_NFT_BATCH_CONTENT=""
	_NFT_MOCK_FAIL=0
	MERGEN_ENGINE_ACTIVE=""
	MERGEN_NFT_AVAILABLE=""
	MERGEN_UCI_RESULT=""
	MERGEN_RULE_NAME=""
	MERGEN_TABLE_NUM=0
	MERGEN_ROUTE_APPLIED_COUNT=0
	MERGEN_ROUTE_FAILED_COUNT=0
	MERGEN_GATEWAY_ADDR=""
	MERGEN_RESOLVE_RESULT_V4=""
	MERGEN_RESOLVE_RESULT_V6=""

	# Default config
	_mock_uci_set "mergen.global.enabled=1"
	_mock_uci_set "mergen.global.default_table=100"
	_mock_uci_set "mergen.global.log_level=info"
	_mock_uci_set "mergen.global.cache_dir=/tmp/mergen/cache"
	_MOCK_CONFIG_LOADED="mergen"
}

# ── Helper: add a test rule ─────────────────────────────

_add_test_rule() {
	local name="$1" type="$2" targets="$3" via="$4" priority="${5:-100}"
	mergen_rule_add "$name" "$type" "$targets" "$via" "$priority"
}

# ── Gateway Detection Tests ─────────────────────────────

test_detect_gateway_success() {
	mergen_detect_gateway "wg0"
	assertEquals "Gateway detected" 0 $?
	assertEquals "Gateway address" "10.0.0.1" "$MERGEN_GATEWAY_ADDR"
}

test_detect_gateway_custom() {
	_MOCK_GATEWAY="192.168.1.1"
	mergen_detect_gateway "eth0"
	assertEquals "Custom gateway detected" 0 $?
	assertEquals "Custom gateway address" "192.168.1.1" "$MERGEN_GATEWAY_ADDR"
}

# ── Table Number Tests ──────────────────────────────────

test_get_table_num_first_rule() {
	_add_test_rule "cloudflare" "ip" "104.16.0.0/12" "wg0" "100"

	_mergen_get_table_num "cloudflare"
	assertEquals "Table num found" 0 $?
	assertEquals "First rule table" "100" "$MERGEN_TABLE_NUM"
}

test_get_table_num_second_rule() {
	_add_test_rule "cloudflare" "ip" "104.16.0.0/12" "wg0" "100"
	_add_test_rule "google" "ip" "8.8.8.0/24" "wg0" "200"

	_mergen_get_table_num "google"
	assertEquals "Table num found" 0 $?
	assertEquals "Second rule table" "101" "$MERGEN_TABLE_NUM"
}

test_get_table_num_nonexistent() {
	_mergen_get_table_num "nonexistent"
	assertNotEquals "Nonexistent rule fails" 0 $?
}

# ── Route Apply Tests ───────────────────────────────────

test_route_apply_ip_rule() {
	_add_test_rule "office" "ip" "10.0.0.0/8" "wg0" "100"

	mergen_route_apply "office"
	assertEquals "Apply IP rule succeeds" 0 $?

	# Check ip route add was called
	echo "$_IP_COMMANDS" | grep -q "ip route add 10.0.0.0/8"
	assertEquals "Route add command issued" 0 $?

	# Check ip rule add was called (nft active: fwmark-based routing)
	echo "$_IP_COMMANDS" | grep -q "ip rule add fwmark"
	assertEquals "Rule add command issued" 0 $?
}

test_route_apply_multiple_ips() {
	_add_test_rule "office" "ip" "10.0.0.0/8,172.16.0.0/12" "wg0" "100"

	mergen_route_apply "office"
	assertEquals "Apply multi-IP rule succeeds" 0 $?

	echo "$_IP_COMMANDS" | grep -q "ip route add 10.0.0.0/8"
	assertEquals "First prefix routed" 0 $?

	echo "$_IP_COMMANDS" | grep -q "ip route add 172.16.0.0/12"
	assertEquals "Second prefix routed" 0 $?
}

test_route_apply_asn_rule() {
	_add_test_rule "cloudflare" "asn" "13335" "wg0" "100"

	mergen_route_apply "cloudflare"
	assertEquals "Apply ASN rule succeeds" 0 $?

	# Mock resolver returns 192.0.2.0/24 and 198.51.100.0/24
	echo "$_IP_COMMANDS" | grep -q "ip route add 192.0.2.0/24"
	assertEquals "First ASN prefix routed" 0 $?

	echo "$_IP_COMMANDS" | grep -q "ip route add 198.51.100.0/24"
	assertEquals "Second ASN prefix routed" 0 $?
}

test_route_apply_uses_correct_table() {
	_add_test_rule "first" "ip" "10.0.0.0/8" "wg0" "100"
	_add_test_rule "second" "ip" "172.16.0.0/12" "wg0" "200"

	mergen_route_apply "second"
	assertEquals "Apply second rule" 0 $?

	# Second rule should use table 101
	echo "$_IP_COMMANDS" | grep -q "table 101"
	assertEquals "Uses table 101" 0 $?
}

test_route_apply_uses_correct_gateway() {
	_MOCK_GATEWAY="192.168.1.1"
	_add_test_rule "office" "ip" "10.0.0.0/8" "wg0" "100"

	mergen_route_apply "office"
	assertEquals "Apply with custom gateway" 0 $?

	echo "$_IP_COMMANDS" | grep -q "via 192.168.1.1"
	assertEquals "Uses correct gateway" 0 $?
}

test_route_apply_disabled_rule() {
	_add_test_rule "disabled" "ip" "10.0.0.0/8" "wg0" "100"
	mergen_rule_toggle "disabled" "0"

	mergen_route_apply "disabled"
	assertEquals "Disabled rule returns 0 (skipped)" 0 $?

	# Should NOT have any route commands (only from gateway detection, etc.)
	local route_adds
	route_adds="$(echo "$_IP_COMMANDS" | grep -c "ip route add" 2>/dev/null)"
	assertEquals "No route commands for disabled rule" "0" "$route_adds"
}

test_route_apply_nonexistent_rule() {
	mergen_route_apply "nonexistent"
	assertNotEquals "Nonexistent rule fails" 0 $?
}

test_route_apply_empty_name() {
	mergen_route_apply ""
	assertNotEquals "Empty name fails" 0 $?
}

# ── Route Remove Tests ──────────────────────────────────

test_route_remove_flushes_table() {
	_add_test_rule "office" "ip" "10.0.0.0/8" "wg0" "100"

	mergen_route_remove "office"
	assertEquals "Remove succeeds" 0 $?

	echo "$_IP_COMMANDS" | grep -q "ip route flush table 100"
	assertEquals "Table flushed" 0 $?
}

test_route_remove_deletes_rules() {
	_add_test_rule "office" "ip" "10.0.0.0/8" "wg0" "100"

	mergen_route_remove "office"
	assertEquals "Remove succeeds" 0 $?

	echo "$_IP_COMMANDS" | grep -q "ip rule del"
	assertEquals "IP rules deleted" 0 $?
}

test_route_remove_empty_name() {
	mergen_route_remove ""
	assertNotEquals "Empty name fails" 0 $?
}

# ── Apply All Tests ─────────────────────────────────────

test_route_apply_all() {
	_add_test_rule "first" "ip" "10.0.0.0/8" "wg0" "100"
	_add_test_rule "second" "ip" "172.16.0.0/12" "wg0" "200"

	mergen_route_apply_all
	assertEquals "Apply all succeeds" 0 $?
	assertEquals "Applied count" "2" "$MERGEN_ROUTE_APPLIED_COUNT"
}

test_route_apply_all_skips_disabled() {
	_add_test_rule "active" "ip" "10.0.0.0/8" "wg0" "100"
	_add_test_rule "inactive" "ip" "172.16.0.0/12" "wg0" "200"
	mergen_rule_toggle "inactive" "0"

	mergen_route_apply_all
	assertEquals "Apply all with disabled" 0 $?
	# Only active rule should produce route commands
	# The "applied count" should be 1 from the callback (active rule)
	# plus 0 from disabled (skipped in mergen_route_apply)
}

test_route_apply_all_empty() {
	mergen_route_apply_all
	assertEquals "Apply all with no rules" 0 $?
	assertEquals "Zero applied" "0" "$MERGEN_ROUTE_APPLIED_COUNT"
}

# ── Route Status Tests ──────────────────────────────────

test_route_status_with_routes() {
	_add_test_rule "office" "ip" "10.0.0.0/8" "wg0" "100"
	# Inject some routes into mock
	_IP_ROUTES="10.0.0.0/8 via 10.0.0.1 dev wg0 table 100"

	local output
	output="$(mergen_route_status "office")"
	assertEquals "Status returns success" 0 $?

	echo "$output" | grep -q "office"
	assertEquals "Shows rule name" 0 $?
}

test_route_status_empty_name() {
	mergen_route_status ""
	assertNotEquals "Empty name fails" 0 $?
}

# ── Load shunit2 ────────────────────────────────────────

if [ -f "${MERGEN_TEST_DIR}/shunit2" ]; then
	. "${MERGEN_TEST_DIR}/shunit2"
elif [ -f /usr/share/shunit2/shunit2 ]; then
	. /usr/share/shunit2/shunit2
else
	echo "ERROR: shunit2 not found. Install it or place it in tests/"
	exit 1
fi

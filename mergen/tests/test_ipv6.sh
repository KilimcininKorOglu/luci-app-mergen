#!/bin/sh
# Test suite for IPv6 dual-stack routing (T027)
# Tests IPv6 gateway detection, route apply with v4+v6, set operations, remove cleanup
# Uses shunit2 framework — ash/busybox compatible

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

# ── Mock IP Command (dual-stack aware) ────────────────────

_IP_COMMANDS=""
_IP_ROUTES=""
_IP_RULES=""
_IP_RULE_DEL_COUNT=0
_MOCK_GATEWAY="10.0.0.1"

# IPv6 tracking
_IP6_COMMANDS=""
_IP6_ROUTES=""
_IP6_RULES=""
_IP6_RULE_DEL_COUNT=0
_MOCK_GATEWAY_V6="fd00::1"

ip() {
	local full_cmd="ip $*"

	# Handle -6 flag: IPv6 mode
	if [ "$1" = "-6" ]; then
		_IP6_COMMANDS="${_IP6_COMMANDS}
${full_cmd}"
		shift
		case "$1" in
			route)
				shift
				case "$1" in
					show)
						if [ "$2" = "dev" ]; then
							echo "default via ${_MOCK_GATEWAY_V6} dev $3"
						elif [ "$2" = "default" ]; then
							echo "default via ${_MOCK_GATEWAY_V6} dev wg0"
						elif [ "$2" = "table" ]; then
							echo "$_IP6_ROUTES" | grep "table $3" 2>/dev/null
						else
							echo "$_IP6_ROUTES"
						fi
						;;
					add|replace)
						shift
						_IP6_ROUTES="${_IP6_ROUTES}
$*"
						return 0
						;;
					flush)
						shift
						if [ "$1" = "table" ]; then
							_IP6_ROUTES="$(echo "$_IP6_ROUTES" | grep -v "table $2" 2>/dev/null)"
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
						_IP6_RULES="${_IP6_RULES}
$*"
						return 0
						;;
					del)
						shift
						_IP6_RULE_DEL_COUNT=$((_IP6_RULE_DEL_COUNT + 1))
						if [ "$_IP6_RULE_DEL_COUNT" -le 5 ]; then
							return 0
						fi
						return 2
						;;
					show)
						echo "$_IP6_RULES"
						;;
				esac
				;;
		esac
		return 0
	fi

	# IPv4 mode (default)
	_IP_COMMANDS="${_IP_COMMANDS}
${full_cmd}"

	case "$1" in
		route)
			shift
			case "$1" in
				show)
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
					if [ "$_IP_RULE_DEL_COUNT" -le 5 ]; then
						return 0
					fi
					return 2
					;;
				show)
					echo "$_IP_RULES"
					;;
				save)
					echo "$_IP_RULES"
					;;
			esac
			;;
		link)
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

# ── Mock nft Command (v4 + v6 sets) ──────────────────────

_NFT_TABLES=""
_NFT_CHAINS=""
_NFT_SETS=""
_NFT_SET_ELEMENTS=""
_NFT_RULES=""

nft() {
	# Handle batch mode: nft -f <file>
	if [ "$1" = "-f" ]; then
		local batch_file="$2"
		[ -f "$batch_file" ] || return 1
		while IFS= read -r line; do
			case "$line" in
				"flush set "*)
					local set_name
					set_name="$(echo "$line" | awk '{print $5}')"
					_NFT_SET_ELEMENTS="$(echo "$_NFT_SET_ELEMENTS" | sed "s/|[^|]*${set_name}=[^|]*//g")"
					;;
				"add element "*)
					local set_name elements
					set_name="$(echo "$line" | awk '{print $5}')"
					elements="$(echo "$line" | sed 's/.*{ //;s/ }//')"
					_NFT_SET_ELEMENTS="${_NFT_SET_ELEMENTS}|inet:mergen:${set_name}=${elements}"
					;;
			esac
		done < "$batch_file"
		return 0
	fi

	# Handle nft -a list chain
	if [ "$1" = "-a" ]; then
		shift
		if [ "$1" = "list" ] && [ "$2" = "chain" ]; then
			local family="$3" table="$4" chain="$5"
			local handle_num=1
			echo "table ${family} ${table} {"
			echo "  chain ${chain} {"
			echo "$_NFT_RULES" | tr '|' '\n' | while IFS= read -r rule; do
				[ -z "$rule" ] && continue
				echo "    ${rule} # handle ${handle_num}"
				handle_num=$((handle_num + 1))
			done
			echo "  }"
			echo "}"
			return 0
		fi
	fi

	case "$1" in
		add)
			shift
			case "$1" in
				table)
					_NFT_TABLES="${_NFT_TABLES} $2:$3"
					;;
				chain)
					_NFT_CHAINS="${_NFT_CHAINS} $2:$3:$4"
					;;
				set)
					_NFT_SETS="${_NFT_SETS} $2:$3:$4"
					;;
				element)
					local family="$2" table="$3" set_name="$4"
					shift 4
					local elements="$*"
					elements="$(echo "$elements" | sed 's/^{ //;s/ }$//')"
					_NFT_SET_ELEMENTS="${_NFT_SET_ELEMENTS}|${family}:${table}:${set_name}=${elements}"
					;;
				rule)
					local family="$2" table="$3" chain="$4"
					shift 4
					_NFT_RULES="${_NFT_RULES}|$*"
					;;
			esac
			;;
		delete)
			shift
			case "$1" in
				table)
					_NFT_TABLES=""
					_NFT_CHAINS=""
					_NFT_SETS=""
					_NFT_SET_ELEMENTS=""
					_NFT_RULES=""
					;;
				set)
					local target="$2:$3:$4"
					_NFT_SETS="$(echo "$_NFT_SETS" | sed "s/ *${target}//")"
					_NFT_SET_ELEMENTS="$(echo "$_NFT_SET_ELEMENTS" | sed "s/|[^|]*$4=[^|]*//g")"
					;;
				rule) return 0 ;;
			esac
			;;
		flush)
			shift
			case "$1" in
				set)
					local set_name="$4"
					_NFT_SET_ELEMENTS="$(echo "$_NFT_SET_ELEMENTS" | sed "s/|[^|]*${set_name}=[^|]*//g")"
					;;
			esac
			;;
		list)
			shift
			case "$1" in
				table)
					case "$_NFT_TABLES" in
						*"$2:$3"*) return 0 ;;
						*) return 1 ;;
					esac
					;;
				set)
					local set_name="$4"
					case "$_NFT_SETS" in
						*"$set_name"*)
							echo "table inet mergen {"
							echo "  set ${set_name} {"
							echo "    type ipv4_addr"
							echo "    flags interval"
							echo "    elements = {"
							echo "$_NFT_SET_ELEMENTS" | tr '|' '\n' | grep "${set_name}=" | while IFS= read -r entry; do
								local elems="${entry#*=}"
								echo "      ${elems},"
							done
							echo "    }"
							echo "  }"
							echo "}"
							return 0
							;;
						*) return 1 ;;
					esac
					;;
			esac
			;;
	esac
}

# ── Mock ipset Command ────────────────────────────────────

_IPSET_SETS=""
_IPSET_ELEMENTS=""

ipset() {
	case "$1" in
		create)
			local name="$2" type="$3"
			shift 3
			# Collect remaining args (family, -exist, etc.)
			local family=""
			while [ $# -gt 0 ]; do
				case "$1" in
					family) family="$2"; shift 2 ;;
					-exist) shift ;;
					*) shift ;;
				esac
			done
			_IPSET_SETS="${_IPSET_SETS} ${name}:${type}${family:+:${family}}"
			return 0
			;;
		add)
			_IPSET_ELEMENTS="${_IPSET_ELEMENTS}|$2=$3"
			return 0
			;;
		flush)
			local name="$2"
			_IPSET_ELEMENTS="$(echo "$_IPSET_ELEMENTS" | sed "s/|${name}=[^|]*//g")"
			return 0
			;;
		destroy)
			local name="$2"
			_IPSET_SETS="$(echo "$_IPSET_SETS" | sed "s/ *${name}:[^ ]*//")"
			_IPSET_ELEMENTS="$(echo "$_IPSET_ELEMENTS" | sed "s/|${name}=[^|]*//g")"
			return 0
			;;
		restore)
			# Read from stdin
			while IFS= read -r line; do
				case "$line" in
					"flush "*)
						local name="${line#flush }"
						_IPSET_ELEMENTS="$(echo "$_IPSET_ELEMENTS" | sed "s/|${name}=[^|]*//g")"
						;;
					"add "*)
						local rest="${line#add }"
						local name="${rest%% *}"
						local elem="${rest#* }"
						_IPSET_ELEMENTS="${_IPSET_ELEMENTS}|${name}=${elem}"
						;;
				esac
			done
			return 0
			;;
		list)
			if [ "$2" = "-n" ]; then
				echo "$_IPSET_SETS" | tr ' ' '\n' | sed 's/:.*//;/^$/d'
			fi
			;;
		save)
			echo "$_IPSET_SETS" | tr ' ' '\n' | while IFS= read -r entry; do
				[ -z "$entry" ] && continue
				local name="${entry%%:*}"
				case "$name" in
					mergen_*)
						echo "create ${entry}"
						;;
				esac
			done
			;;
	esac
}

# ── Mock iptables/ip6tables ──────────────────────────────

_IPTABLES_RULES=""
_IP6TABLES_RULES=""

iptables() {
	case "$2" in
		-A) _IPTABLES_RULES="${_IPTABLES_RULES}|$1:$*" ;;
		-D)
			local pattern="$1:$(echo "$*" | sed 's/-D/-A/')"
			case "$_IPTABLES_RULES" in
				*"$pattern"*) _IPTABLES_RULES="$(echo "$_IPTABLES_RULES" | sed "s/|[^|]*$(echo "$pattern" | sed 's/[.\/]/\\&/g')[^|]*//")" ;;
				*) return 1 ;;
			esac
			;;
		-C)
			local pattern="$1:$(echo "$*" | sed 's/-C/-A/')"
			case "$_IPTABLES_RULES" in
				*"$pattern"*) return 0 ;;
				*) return 1 ;;
			esac
			;;
	esac
}

ip6tables() {
	case "$2" in
		-A) _IP6TABLES_RULES="${_IP6TABLES_RULES}|$1:$*" ;;
		-D)
			local pattern="$1:$(echo "$*" | sed 's/-D/-A/')"
			case "$_IP6TABLES_RULES" in
				*"$pattern"*) _IP6TABLES_RULES="$(echo "$_IP6TABLES_RULES" | sed "s/|[^|]*$(echo "$pattern" | sed 's/[.\/]/\\&/g')[^|]*//")" ;;
				*) return 1 ;;
			esac
			;;
		-C)
			local pattern="$1:$(echo "$*" | sed 's/-C/-A/')"
			case "$_IP6TABLES_RULES" in
				*"$pattern"*) return 0 ;;
				*) return 1 ;;
			esac
			;;
	esac
}

# ── Mock ping ─────────────────────────────────────────────

ping() { return 0; }

# ── Source modules under test ─────────────────────────────

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

# Mock resolver for ASN rules — returns both v4 and v6
mergen_resolve_asn() {
	local asn="$1"
	case "$asn" in
		AS*|as*) asn="${asn#[Aa][Ss]}" ;;
	esac
	MERGEN_RESOLVE_RESULT_V4="192.0.2.0/24
198.51.100.0/24"
	MERGEN_RESOLVE_RESULT_V6="2001:db8::/32
2001:db8:1::/48"
	MERGEN_RESOLVE_PROVIDER="mock"
	MERGEN_RESOLVE_COUNT_V4=2
	MERGEN_RESOLVE_COUNT_V6=2
	return 0
}

# ── Setup/Teardown ────────────────────────────────────────

setUp() {
	_MOCK_UCI_STORE=""
	_MOCK_FOREACH_SECTIONS=""
	_MOCK_ADD_COUNTER=0
	_IP_COMMANDS=""
	_IP_ROUTES=""
	_IP_RULES=""
	_IP_RULE_DEL_COUNT=0
	_MOCK_GATEWAY="10.0.0.1"
	_IP6_COMMANDS=""
	_IP6_ROUTES=""
	_IP6_RULES=""
	_IP6_RULE_DEL_COUNT=0
	_MOCK_GATEWAY_V6="fd00::1"
	_NFT_TABLES=""
	_NFT_CHAINS=""
	_NFT_SETS=""
	_NFT_SET_ELEMENTS=""
	_NFT_RULES=""
	_IPSET_SETS=""
	_IPSET_ELEMENTS=""
	_IPTABLES_RULES=""
	_IP6TABLES_RULES=""
	MERGEN_UCI_RESULT=""
	MERGEN_RULE_NAME=""
	MERGEN_TABLE_NUM=0
	MERGEN_ROUTE_APPLIED_COUNT=0
	MERGEN_ROUTE_FAILED_COUNT=0
	MERGEN_GATEWAY_ADDR=""
	MERGEN_GATEWAY_V6_ADDR=""
	MERGEN_RESOLVE_RESULT_V4=""
	MERGEN_RESOLVE_RESULT_V6=""
	MERGEN_ENGINE_ACTIVE=""
	MERGEN_NFT_AVAILABLE=""

	# Default config
	_mock_uci_set "mergen.global.enabled=1"
	_mock_uci_set "mergen.global.default_table=100"
	_mock_uci_set "mergen.global.log_level=info"
	_mock_uci_set "mergen.global.cache_dir=/tmp/mergen/cache"
	_mock_uci_set "mergen.global.ipv6_enabled=1"
	_mock_uci_set "mergen.global.packet_engine=nftables"
	_MOCK_CONFIG_LOADED="mergen"

	# Force nft available for engine detection
	MERGEN_NFT_AVAILABLE="1"
}

# ── Helper ────────────────────────────────────────────────

_add_test_rule() {
	local name="$1" type="$2" targets="$3" via="$4" priority="${5:-100}"
	mergen_rule_add "$name" "$type" "$targets" "$via" "$priority"
}

# ── IPv6 Gateway Detection Tests ─────────────────────────

test_detect_gateway_v6_success() {
	mergen_detect_gateway_v6 "wg0"
	assertEquals "IPv6 gateway detected" 0 $?
	assertEquals "IPv6 gateway address" "fd00::1" "$MERGEN_GATEWAY_V6_ADDR"
}

test_detect_gateway_v6_custom() {
	_MOCK_GATEWAY_V6="2001:db8::1"
	mergen_detect_gateway_v6 "eth0"
	assertEquals "Custom IPv6 gateway detected" 0 $?
	assertEquals "Custom IPv6 gateway address" "2001:db8::1" "$MERGEN_GATEWAY_V6_ADDR"
}

# ── IPv6 Route Apply — IP-Based Rule ─────────────────────

test_route_apply_ipv6_ip_rule() {
	_add_test_rule "dualstack" "ip" "10.0.0.0/8,2001:db8::/32" "wg0" "100"

	mergen_route_apply "dualstack"
	assertEquals "Route apply succeeds" 0 $?

	# Check IPv4 routes added
	local v4_count
	v4_count="$(echo "$_IP_ROUTES" | grep -c '10.0.0.0/8' 2>/dev/null)"
	assertEquals "IPv4 route added" 1 "$v4_count"

	# Check IPv6 routes added
	local v6_count
	v6_count="$(echo "$_IP6_ROUTES" | grep -c '2001:db8::/32' 2>/dev/null)"
	assertEquals "IPv6 route added" 1 "$v6_count"
}

test_route_apply_ipv6_disabled_skips_v6() {
	_mock_uci_set "mergen.global.ipv6_enabled=0"
	_add_test_rule "v4only" "ip" "10.0.0.0/8,2001:db8::/32" "wg0" "100"

	mergen_route_apply "v4only"
	assertEquals "Route apply succeeds" 0 $?

	# IPv4 routes should exist
	local v4_count
	v4_count="$(echo "$_IP_ROUTES" | grep -c '10.0.0.0/8' 2>/dev/null)"
	assertEquals "IPv4 route present" 1 "$v4_count"

	# IPv6 routes should NOT exist
	local v6_count
	v6_count="$(echo "$_IP6_ROUTES" | grep -c '2001:db8::/32' 2>/dev/null)"
	assertEquals "IPv6 route skipped" 0 "$v6_count"
}

# ── IPv6 Route Apply — ASN-Based Rule ────────────────────

test_route_apply_ipv6_asn_rule() {
	_add_test_rule "cfasn" "asn" "13335" "wg0" "100"

	mergen_route_apply "cfasn"
	assertEquals "ASN route apply succeeds" 0 $?

	# Check IPv4 routes
	local v4_count
	v4_count="$(echo "$_IP_ROUTES" | grep -c '192.0.2.0/24' 2>/dev/null)"
	assertEquals "IPv4 ASN routes added" 1 "$v4_count"

	# Check IPv6 routes
	local v6_count
	v6_count="$(echo "$_IP6_ROUTES" | grep -c '2001:db8::/32' 2>/dev/null)"
	assertEquals "IPv6 ASN routes added" 1 "$v6_count"
}

test_route_apply_asn_v6_disabled() {
	_mock_uci_set "mergen.global.ipv6_enabled=0"
	_add_test_rule "cfasn" "asn" "13335" "wg0" "100"

	mergen_route_apply "cfasn"
	assertEquals "ASN route apply succeeds" 0 $?

	# IPv4 routes should exist
	local v4_count
	v4_count="$(echo "$_IP_ROUTES" | grep -c '192.0.2.0/24' 2>/dev/null)"
	assertEquals "IPv4 ASN routes present" 1 "$v4_count"

	# IPv6 routes should NOT exist
	local v6_count
	v6_count="$(echo "$_IP6_ROUTES" | grep -c '2001:db8' 2>/dev/null)"
	assertEquals "IPv6 ASN routes skipped" 0 "$v6_count"
}

# ── IPv6 nftables Set Operations ─────────────────────────

test_nft_set_create_v6() {
	MERGEN_ENGINE_ACTIVE=""
	mergen_nft_set_create_v6 "testrule"
	assertEquals "v6 set create succeeds" 0 $?

	# Check set was registered
	case "$_NFT_SETS" in
		*"mergen_testrule_v6"*)
			assertTrue "v6 set exists in tracking" true
			;;
		*)
			fail "v6 set not found in tracking: $_NFT_SETS"
			;;
	esac
}

test_nft_set_add_v6() {
	mergen_nft_set_create_v6 "testrule"

	local prefixes="2001:db8::/32
2001:db8:1::/48"

	mergen_nft_set_add_v6 "testrule" "$prefixes"
	assertEquals "v6 set add succeeds" 0 $?

	# Check elements tracked
	case "$_NFT_SET_ELEMENTS" in
		*"mergen_testrule_v6"*)
			assertTrue "v6 elements exist" true
			;;
		*)
			fail "v6 elements not found: $_NFT_SET_ELEMENTS"
			;;
	esac
}

test_nft_set_destroy_v6() {
	mergen_nft_set_create_v6 "testrule"
	mergen_nft_set_add_v6 "testrule" "2001:db8::/32"

	mergen_nft_set_destroy_v6 "testrule"
	assertEquals "v6 set destroy succeeds" 0 $?

	# Set should be gone
	case "$_NFT_SETS" in
		*"mergen_testrule_v6"*)
			fail "v6 set should be removed"
			;;
		*)
			assertTrue "v6 set removed" true
			;;
	esac
}

test_nft_rule_add_v6() {
	mergen_nft_set_create_v6 "testrule"

	mergen_nft_rule_add_v6 "testrule" "100"
	assertEquals "v6 fwmark rule add succeeds" 0 $?

	# Check rule tracked — should have ip6 daddr
	case "$_NFT_RULES" in
		*"ip6 daddr"*"@mergen_testrule_v6"*"mark set 100"*)
			assertTrue "v6 fwmark rule exists" true
			;;
		*)
			fail "v6 fwmark rule not found: $_NFT_RULES"
			;;
	esac
}

# ── IPv6 ipset Operations ────────────────────────────────

test_ipset_create_v6() {
	MERGEN_IPSET_AVAILABLE="1"
	mergen_ipset_create_v6 "testrule"
	assertEquals "v6 ipset create succeeds" 0 $?

	case "$_IPSET_SETS" in
		*"mergen_testrule_v6:hash:net:inet6"*)
			assertTrue "v6 ipset with inet6 family exists" true
			;;
		*)
			fail "v6 ipset not found: $_IPSET_SETS"
			;;
	esac
}

test_ipset_add_v6() {
	MERGEN_IPSET_AVAILABLE="1"
	mergen_ipset_create_v6 "testrule"

	local prefixes="2001:db8::/32
2001:db8:1::/48"

	mergen_ipset_add_v6 "testrule" "$prefixes"
	assertEquals "v6 ipset add succeeds" 0 $?

	case "$_IPSET_ELEMENTS" in
		*"mergen_testrule_v6=2001:db8::/32"*)
			assertTrue "v6 ipset elements exist" true
			;;
		*)
			fail "v6 ipset elements not found: $_IPSET_ELEMENTS"
			;;
	esac
}

test_ipset_destroy_v6() {
	MERGEN_IPSET_AVAILABLE="1"
	mergen_ipset_create_v6 "testrule"
	mergen_ipset_add_v6 "testrule" "2001:db8::/32"

	mergen_ipset_destroy_v6 "testrule"
	assertEquals "v6 ipset destroy succeeds" 0 $?

	case "$_IPSET_SETS" in
		*"mergen_testrule_v6"*)
			fail "v6 ipset should be removed"
			;;
		*)
			assertTrue "v6 ipset removed" true
			;;
	esac
}

# ── Common Interface v6 Dispatchers ──────────────────────

test_common_set_create_v6_nft() {
	MERGEN_ENGINE_ACTIVE=""
	_mock_uci_set "mergen.global.packet_engine=nftables"
	MERGEN_NFT_AVAILABLE="1"

	mergen_set_create_v6 "dispatch_test"
	assertEquals "Common v6 create via nft succeeds" 0 $?

	case "$_NFT_SETS" in
		*"mergen_dispatch_test_v6"*)
			assertTrue "Dispatched to nft v6 set create" true
			;;
		*)
			fail "nft v6 set not created via dispatcher"
			;;
	esac
}

test_common_set_create_v6_ipset() {
	MERGEN_ENGINE_ACTIVE=""
	_mock_uci_set "mergen.global.packet_engine=ipset"
	MERGEN_NFT_AVAILABLE="0"
	MERGEN_IPSET_AVAILABLE="1"

	mergen_set_create_v6 "dispatch_test"
	assertEquals "Common v6 create via ipset succeeds" 0 $?

	case "$_IPSET_SETS" in
		*"mergen_dispatch_test_v6"*)
			assertTrue "Dispatched to ipset v6 create" true
			;;
		*)
			fail "ipset v6 set not created via dispatcher"
			;;
	esac
}

# ── Route Remove with IPv6 Cleanup ───────────────────────

test_route_remove_cleans_v6() {
	_add_test_rule "cleanup_test" "ip" "10.0.0.0/8,2001:db8::/32" "wg0" "100"

	# Apply first to create routes and sets
	mergen_route_apply "cleanup_test"
	assertEquals "Apply succeeds" 0 $?

	# Verify v4 and v6 routes exist
	local v4_exists v6_exists
	v4_exists="$(echo "$_IP_ROUTES" | grep -c '10.0.0.0/8' 2>/dev/null)"
	v6_exists="$(echo "$_IP6_ROUTES" | grep -c '2001:db8::/32' 2>/dev/null)"
	assertEquals "v4 routes exist before remove" 1 "$v4_exists"
	assertEquals "v6 routes exist before remove" 1 "$v6_exists"

	# Now remove
	mergen_route_remove "cleanup_test"
	assertEquals "Remove succeeds" 0 $?

	# Check ip -6 rule del was called
	local v6_rule_del
	v6_rule_del="$(echo "$_IP6_COMMANDS" | grep -c 'rule del' 2>/dev/null)"
	assertTrue "ip -6 rule del was called" "[ $v6_rule_del -gt 0 ]"

	# Check ip -6 route flush was called
	local v6_flush
	v6_flush="$(echo "$_IP6_COMMANDS" | grep -c 'route flush' 2>/dev/null)"
	assertTrue "ip -6 route flush was called" "[ $v6_flush -gt 0 ]"
}

# ── IPv6 Set-Based Routing Full Flow ─────────────────────

test_full_dualstack_with_sets() {
	_add_test_rule "fulltest" "ip" "10.0.0.0/8,2001:db8::/32,2001:db8:1::/48" "wg0" "100"

	mergen_route_apply "fulltest"
	assertEquals "Full dual-stack apply succeeds" 0 $?

	# v4 set should be created
	case "$_NFT_SETS" in
		*"mergen_fulltest"*)
			assertTrue "IPv4 nft set created" true
			;;
		*)
			fail "IPv4 nft set not found: $_NFT_SETS"
			;;
	esac

	# v6 set should be created
	case "$_NFT_SETS" in
		*"mergen_fulltest_v6"*)
			assertTrue "IPv6 nft set created" true
			;;
		*)
			fail "IPv6 nft set not found: $_NFT_SETS"
			;;
	esac

	# fwmark rules should exist for both
	case "$_NFT_RULES" in
		*"ip daddr"*"@mergen_fulltest"*)
			assertTrue "IPv4 fwmark rule exists" true
			;;
		*)
			fail "IPv4 fwmark rule not found: $_NFT_RULES"
			;;
	esac

	case "$_NFT_RULES" in
		*"ip6 daddr"*"@mergen_fulltest_v6"*)
			assertTrue "IPv6 fwmark rule exists" true
			;;
		*)
			fail "IPv6 fwmark rule not found: $_NFT_RULES"
			;;
	esac

	# ip -6 rule add fwmark should be called
	case "$_IP6_RULES" in
		*"fwmark"*"lookup"*)
			assertTrue "IPv6 ip rule with fwmark exists" true
			;;
		*)
			fail "IPv6 ip rule not found: $_IP6_RULES"
			;;
	esac
}

test_full_dualstack_v6_disabled() {
	_mock_uci_set "mergen.global.ipv6_enabled=0"
	_add_test_rule "v4only_full" "ip" "10.0.0.0/8,2001:db8::/32" "wg0" "100"

	mergen_route_apply "v4only_full"
	assertEquals "v4-only apply succeeds" 0 $?

	# v4 set should be created
	case "$_NFT_SETS" in
		*"mergen_v4only_full"*)
			assertTrue "IPv4 nft set created" true
			;;
		*)
			fail "IPv4 nft set not found"
			;;
	esac

	# v6 set should NOT be created
	case "$_NFT_SETS" in
		*"mergen_v4only_full_v6"*)
			fail "IPv6 nft set should not be created when v6 disabled"
			;;
		*)
			assertTrue "IPv6 set correctly skipped" true
			;;
	esac
}

# ── IPv6 Only Rule ───────────────────────────────────────

test_route_apply_v6_only_targets() {
	_add_test_rule "v6only" "ip" "2001:db8::/32,2001:db8:1::/48" "wg0" "100"

	mergen_route_apply "v6only"
	assertEquals "v6-only apply succeeds" 0 $?

	# No IPv4 routes
	local v4_count
	v4_count="$(echo "$_IP_ROUTES" | sed '/^$/d' | wc -l | tr -d ' ')"
	assertEquals "No IPv4 routes" 0 "$v4_count"

	# IPv6 routes should exist
	local v6_count
	v6_count="$(echo "$_IP6_ROUTES" | grep -c '2001:db8' 2>/dev/null)"
	assertTrue "IPv6 routes exist" "[ $v6_count -ge 1 ]"
}

# ── Load shunit2 ─────────────────────────────────────────

SHUNIT2_PATH="${MERGEN_TEST_DIR}/shunit2"
if [ ! -f "$SHUNIT2_PATH" ]; then
	SHUNIT2_PATH="$(command -v shunit2 2>/dev/null)"
fi

if [ -z "$SHUNIT2_PATH" ] || [ ! -f "$SHUNIT2_PATH" ]; then
	echo "HATA: shunit2 bulunamadı. Testler çalıştırılamıyor."
	exit 1
fi

. "$SHUNIT2_PATH"

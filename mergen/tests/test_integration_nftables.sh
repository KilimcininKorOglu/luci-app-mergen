#!/bin/sh
# Integration Test: nftables set lifecycle
# Tests set creation → element addition → fwmark check → route apply → cleanup
# Exercises: route.sh nftables + engine abstraction with CLI

MERGEN_TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
MERGEN_ROOT="$(cd "$MERGEN_TEST_DIR/.." && pwd)"

# ── Test Temp Directory ─────────────────────────────────

_TEST_TMPDIR=""

# ── Mock UCI System ─────────────────────────────────────

_MOCK_UCI_STORE=""
_MOCK_CONFIG_LOADED=""
_MOCK_FOREACH_SECTIONS=""
_MOCK_SECTION_COUNTER=0

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
			local config="$1" type="$2"
			_MOCK_SECTION_COUNTER=$((_MOCK_SECTION_COUNTER + 1))
			local new_id="cfg$(printf '%03d' $_MOCK_SECTION_COUNTER)"
			if [ "$type" = "rule" ]; then
				_MOCK_FOREACH_SECTIONS="${_MOCK_FOREACH_SECTIONS} ${new_id}"
			fi
			echo "$new_id"
			;;
		add_list)
			local assignment="$1"
			local key="${assignment%%=*}"
			local value="${assignment#*=}"
			local existing
			existing="$(_mock_uci_get "$key")"
			if [ -n "$existing" ]; then
				_mock_uci_set "${key}=${existing} ${value}"
			else
				_mock_uci_set "${key}=${value}"
			fi
			;;
		delete)
			local path="$1"
			_MOCK_UCI_STORE="$(echo "$_MOCK_UCI_STORE" | grep -v "^${MERGEN_CONF:-mergen}\.${path}\." 2>/dev/null)"
			local section="${path##*.}"
			_MOCK_FOREACH_SECTIONS="$(echo "$_MOCK_FOREACH_SECTIONS" | sed "s/ *${section} */ /g" | sed 's/^ *//;s/ *$//')"
			;;
		commit) return 0 ;;
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

# Mock logger, flock
logger() { :; }
flock() { return 0; }

# ── Mock nft command with state tracking ───────────────

_NFT_TABLES=""
_NFT_SETS=""
_NFT_SET_ELEMENTS=""
_NFT_RULES=""
_NFT_BATCH_CONTENT=""

nft() {
	local subcmd="$1"
	shift

	case "$subcmd" in
		-v)
			echo "nftables v1.0.5"
			return 0
			;;
		-f)
			local batch_file="$1"
			if [ -f "$batch_file" ]; then
				_NFT_BATCH_CONTENT="${_NFT_BATCH_CONTENT}
$(cat "$batch_file")"
				# Parse elements from batch
				local line
				while IFS= read -r line; do
					case "$line" in
						"add element"*)
							_NFT_SET_ELEMENTS="${_NFT_SET_ELEMENTS}
${line}"
							;;
					esac
				done < "$batch_file"
			fi
			return 0
			;;
		add)
			case "$1" in
				table)
					_NFT_TABLES="${_NFT_TABLES} $3"
					return 0
					;;
				set)
					# nft add set inet <table> <set_name> ...
					_NFT_SETS="${_NFT_SETS} $4"
					return 0
					;;
				element)
					shift
					_NFT_SET_ELEMENTS="${_NFT_SET_ELEMENTS}
$*"
					return 0
					;;
				rule)
					shift
					_NFT_RULES="${_NFT_RULES}
$*"
					return 0
					;;
			esac
			;;
		delete)
			case "$1" in
				table)
					_NFT_TABLES="$(echo "$_NFT_TABLES" | sed "s/ $3//")"
					return 0
					;;
				set)
					# nft delete set inet <table> <set_name>
					local set_name="$4"
					_NFT_SETS="$(echo "$_NFT_SETS" | sed "s/ $set_name//")"
					_NFT_SET_ELEMENTS="$(echo "$_NFT_SET_ELEMENTS" | grep -v "$set_name" 2>/dev/null)"
					return 0
					;;
				rule)
					return 0
					;;
			esac
			;;
		flush)
			case "$1" in
				set)
					# nft flush set inet <table> <set_name>
					local set_name="$4"
					_NFT_SET_ELEMENTS="$(echo "$_NFT_SET_ELEMENTS" | grep -v "$set_name" 2>/dev/null)"
					return 0
					;;
				table)
					_NFT_RULES=""
					return 0
					;;
			esac
			;;
		list)
			case "$1" in
				sets)
					echo "$_NFT_SETS"
					return 0
					;;
				set)
					# nft list set inet <table> <set_name>
					local set_name="$4"
					echo "$_NFT_SET_ELEMENTS" | grep "$set_name" 2>/dev/null
					return 0
					;;
			esac
			;;
	esac
	return 0
}

# ── Mock ip command ────────────────────────────────────

_IP_ROUTES=""
_IP_RULES=""

ip() {
	case "$1" in
		route)
			case "$2" in
				add|replace)
					shift 2
					_IP_ROUTES="${_IP_ROUTES}
$*"
					return 0
					;;
				show)
					if echo "$*" | grep -q "dev wg0"; then
						echo "default via 10.0.0.1 dev wg0"
					elif echo "$*" | grep -q "table"; then
						local tbl
						tbl="$(echo "$*" | sed -n 's/.*table \([0-9]*\).*/\1/p')"
						echo "$_IP_ROUTES" | grep "table $tbl" 2>/dev/null
					fi
					return 0
					;;
				del|delete|flush)
					shift 2
					local tbl
					tbl="$(echo "$*" | sed -n 's/.*table \([0-9]*\).*/\1/p')"
					[ -n "$tbl" ] && _IP_ROUTES="$(echo "$_IP_ROUTES" | grep -v "table $tbl" 2>/dev/null)"
					return 0
					;;
			esac
			;;
		rule)
			case "$2" in
				add) shift 2; _IP_RULES="${_IP_RULES}
$*"; return 0 ;;
				del|delete) shift 2; return 0 ;;
				show|save) echo "$_IP_RULES"; return 0 ;;
				restore) return 0 ;;
			esac
			;;
		link)
			case "$3" in
				wg0|lan|eth0) echo "1: $3: <POINTOPOINT,NOARP,UP>" ;;
				*) return 1 ;;
			esac
			;;
	esac
}

# ── Source modules under test ───────────────────────────

. "${MERGEN_ROOT}/files/usr/lib/mergen/core.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/utils.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/engine.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/resolver.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/route.sh"

MERGEN_SOURCED=1
. "${MERGEN_ROOT}/files/usr/bin/mergen"

# ── Post-source Overrides ──────────────────────────────

mergen_uci_add() {
	local type="$1"
	_MOCK_SECTION_COUNTER=$((_MOCK_SECTION_COUNTER + 1))
	local new_id="cfg$(printf '%03d' $_MOCK_SECTION_COUNTER)"
	MERGEN_UCI_RESULT="$new_id"
	if [ "$type" = "rule" ]; then
		_MOCK_FOREACH_SECTIONS="${_MOCK_FOREACH_SECTIONS} ${new_id}"
	fi
}

mergen_lock_acquire() { return 0; }
mergen_lock_release() { return 0; }

# ── One-Time Setup/Teardown ─────────────────────────────
# Temp directory created once for the entire file, not per test

oneTimeSetUp() {
	_TEST_TMPDIR="$(mktemp -d)"
	mkdir -p "${_TEST_TMPDIR}/providers"
	mkdir -p "${_TEST_TMPDIR}/cache"
	mkdir -p "${_TEST_TMPDIR}/snapshot"
}

oneTimeTearDown() {
	[ -n "$_TEST_TMPDIR" ] && [ -d "$_TEST_TMPDIR" ] && rm -rf "$_TEST_TMPDIR"
	return 0
}

# ── Per-Test Setup/Teardown ─────────────────────────────

setUp() {
	_MOCK_UCI_STORE=""
	_MOCK_FOREACH_SECTIONS=""
	_MOCK_SECTION_COUNTER=0
	_IP_ROUTES=""
	_IP_RULES=""
	_NFT_TABLES=""
	_NFT_SETS=""
	_NFT_SET_ELEMENTS=""
	_NFT_RULES=""
	_NFT_BATCH_CONTENT=""
	MERGEN_UCI_RESULT=""
	MERGEN_FORCE_APPLY=0

	# Force nftables engine
	MERGEN_NFT_AVAILABLE="1"
	MERGEN_IPSET_AVAILABLE="0"
	MERGEN_ENGINE_ACTIVE=""

	# Clean all temp contents between tests, recreate structure
	rm -rf "${_TEST_TMPDIR:?}/"*
	mkdir -p "${_TEST_TMPDIR}/providers" "${_TEST_TMPDIR}/cache" "${_TEST_TMPDIR}/snapshot"

	MERGEN_PROVIDERS_DIR="${_TEST_TMPDIR}/providers"
	MERGEN_CACHE_DIR="${_TEST_TMPDIR}/cache"
	MERGEN_TMP="${_TEST_TMPDIR}"
	MERGEN_SNAPSHOT_DIR="${_TEST_TMPDIR}/snapshot"

	_mock_uci_set "mergen.global.enabled=1"
	_mock_uci_set "mergen.global.log_level=info"
	_mock_uci_set "mergen.global.cache_dir=${_TEST_TMPDIR}/cache"
	_mock_uci_set "mergen.global.default_table=100"
	_mock_uci_set "mergen.global.packet_engine=auto"
	_mock_uci_set "mergen.global.max_prefix_per_rule=10000"
	_mock_uci_set "mergen.global.max_prefix_total=50000"
	_MOCK_CONFIG_LOADED="mergen"

	MERGEN_LOG_LEVEL=""
	MERGEN_LOG_LEVEL_NUM=""
}

tearDown() {
	:
}

# ── Integration Tests ──────────────────────────────────

test_apply_creates_nft_set() {
	cmd_add --name nft-test --ip 10.0.0.0/8 --via wg0 2>/dev/null
	cmd_apply 2>/dev/null
	assertEquals "Apply succeeds" 0 $?

	# Verify nft set was created
	echo "$_NFT_SETS" | grep -q "mergen_nft-test"
	assertEquals "nft set created for rule" 0 $?
}

test_apply_adds_elements_to_set() {
	cmd_add --name elem-test --ip "10.0.0.0/8,172.16.0.0/12" --via wg0 2>/dev/null
	cmd_apply 2>/dev/null

	# Check batch file was used (elements added)
	echo "$_NFT_SET_ELEMENTS" | grep -q "10.0.0.0/8"
	assertEquals "First prefix in set elements" 0 $?
}

test_apply_creates_fwmark_rule() {
	cmd_add --name fwmark-test --ip 10.0.0.0/8 --via wg0 2>/dev/null
	cmd_apply 2>/dev/null

	# Check nft fwmark rule created
	echo "$_NFT_RULES" | grep -q "mark"
	assertEquals "fwmark rule created" 0 $?

	# Check ip rule for fwmark
	echo "$_IP_RULES" | grep -q "fwmark"
	assertEquals "ip fwmark rule created" 0 $?
}

test_remove_cleans_nft_set() {
	cmd_add --name clean-test --ip 10.0.0.0/8 --via wg0 2>/dev/null
	cmd_apply 2>/dev/null

	# Verify set exists
	echo "$_NFT_SETS" | grep -q "mergen_clean-test"
	assertEquals "Set exists after apply" 0 $?

	# Remove rule (should clean up set)
	cmd_remove clean-test 2>/dev/null

	# Set should be gone
	echo "$_NFT_SETS" | grep -q "mergen_clean-test"
	assertNotEquals "Set removed after rule removal" 0 $?
}

test_flush_removes_all_sets() {
	cmd_add --name flush-a --ip 10.0.0.0/8 --via wg0 2>/dev/null
	cmd_add --name flush-b --ip 172.16.0.0/12 --via wg0 2>/dev/null
	cmd_apply 2>/dev/null

	cmd_flush --confirm 2>/dev/null
	assertEquals "Flush succeeds" 0 $?
}

test_engine_info_shows_nftables() {
	MERGEN_ENGINE_ACTIVE=""
	local engine
	engine="$(mergen_engine_info)"
	assertEquals "Engine is nftables" "nftables" "$engine"
}

test_apply_creates_ip_routes_and_rules() {
	cmd_add --name route-check --ip 10.0.0.0/8 --via wg0 2>/dev/null
	cmd_apply 2>/dev/null

	# Verify ip routes created
	echo "$_IP_ROUTES" | grep -q "10.0.0.0/8"
	assertEquals "IP route created" 0 $?
}

test_multi_rule_apply_creates_separate_sets() {
	cmd_add --name set-a --ip 10.0.0.0/8 --via wg0 2>/dev/null
	cmd_add --name set-b --ip 172.16.0.0/12 --via wg0 2>/dev/null
	cmd_apply 2>/dev/null

	echo "$_NFT_SETS" | grep -q "mergen_set-a"
	assertEquals "First set created" 0 $?

	echo "$_NFT_SETS" | grep -q "mergen_set-b"
	assertEquals "Second set created" 0 $?
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

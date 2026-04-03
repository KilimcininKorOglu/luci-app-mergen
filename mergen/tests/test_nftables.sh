#!/bin/sh
# Test suite for nftables set management (T017) in route.sh
# Uses shunit2 framework — ash/busybox compatible

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

# Mock logger and flock
logger() { :; }
flock() { return 0; }

# ── Mock nft Command ───────────────────────────────────

# Track nft operations for verification
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
					# nft add table inet mergen
					_NFT_TABLES="${_NFT_TABLES} ${3}:${4}"
					return 0
					;;
				chain)
					# nft add chain inet mergen prerouting { ... }
					_NFT_CHAINS="${_NFT_CHAINS} ${3}:${4}:${5}"
					return 0
					;;
				set)
					# nft add set inet mergen setname { type ipv4_addr ; flags interval ; }
					local family="$3" table="$4" setname="$5"
					_NFT_SETS="${_NFT_SETS} ${family}:${table}:${setname}"
					return 0
					;;
				element)
					# nft add element inet mergen setname { prefixes }
					local family="$3" table="$4" setname="$5"
					shift 5
					local elements="$*"
					_NFT_SET_ELEMENTS="${_NFT_SET_ELEMENTS}|${family}:${table}:${setname}=${elements}"
					return 0
					;;
				rule)
					# nft add rule inet mergen prerouting ip daddr @setname meta mark set N
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
					# nft delete rule inet mergen prerouting handle N
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
						# Extract elements for this set
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
					# List rules with fake handles
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
			# nft -f batchfile — read and execute the batch
			local batchfile="$2"
			if [ -f "$batchfile" ]; then
				_NFT_BATCH_CONTENT="$(cat "$batchfile")"
				# Parse batch commands
				while IFS= read -r batchline; do
					case "$batchline" in
						"flush set "*)
							# Silently handle flush
							;;
						"add element "*)
							# Track elements
							_NFT_SET_ELEMENTS="${_NFT_SET_ELEMENTS}|batch:${batchline}"
							;;
					esac
				done < "$batchfile"
				return 0
			fi
			return 1
			;;
		-a)
			# nft -a list chain ... (with handles)
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

# ── Mock ip Command ─────────────────────────────────────

_IP_RULES=""
_IP_ROUTES=""

ip() {
	case "$1" in
		rule)
			case "$2" in
				add)
					shift 2
					_IP_RULES="${_IP_RULES}|$*"
					return 0
					;;
				del)
					shift 2
					# Remove first matching rule
					local old="$_IP_RULES"
					_IP_RULES="$(echo "$_IP_RULES" | sed "s|[^|]*||" | sed 's/^|//')"
					[ "$old" != "$_IP_RULES" ] && return 0
					return 2
					;;
				save) return 0 ;;
				show) return 0 ;;
				restore) return 0 ;;
			esac
			;;
		route)
			case "$2" in
				add|replace)
					shift 2
					_IP_ROUTES="${_IP_ROUTES}|$*"
					return 0
					;;
				flush) return 0 ;;
				show)
					shift 2
					# Gateway detection support
					local dev=""
					while [ $# -gt 0 ]; do
						case "$1" in
							dev) dev="$2"; shift 2 ;;
							*) shift ;;
						esac
					done
					if [ -n "$dev" ]; then
						echo "default via 10.0.0.1 dev ${dev}"
					fi
					return 0
					;;
			esac
			;;
	esac
}

# Mock ping
ping() { return 0; }

# ── Source Modules Under Test ───────────────────────────

. "${MERGEN_ROOT}/files/usr/lib/mergen/core.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/utils.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/engine.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/resolver.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/route.sh"

# ── Post-source Overrides ──────────────────────────────

mergen_lock_acquire() { return 0; }
mergen_lock_release() { return 0; }

# ── Setup/Teardown ──────────────────────────────────────

setUp() {
	_MOCK_UCI_STORE=""
	_MOCK_FOREACH_SECTIONS=""
	_MOCK_SECTION_COUNTER=0
	MERGEN_ROUTE_APPLIED_COUNT=0
	MERGEN_ROUTE_FAILED_COUNT=0
	MERGEN_NFT_AVAILABLE=""
	MERGEN_IPSET_AVAILABLE=""
	MERGEN_ENGINE_ACTIVE=""

	_NFT_TABLES=""
	_NFT_CHAINS=""
	_NFT_SETS=""
	_NFT_SET_ELEMENTS=""
	_NFT_RULES=""
	_NFT_BATCH_CONTENT=""
	_NFT_MOCK_FAIL=0

	_IP_RULES=""
	_IP_ROUTES=""

	_TEST_TMPDIR="$(mktemp -d)"
	mkdir -p "${_TEST_TMPDIR}/providers"
	mkdir -p "${_TEST_TMPDIR}/cache"

	MERGEN_PROVIDERS_DIR="${_TEST_TMPDIR}/providers"
	MERGEN_CACHE_DIR="${_TEST_TMPDIR}/cache"
	MERGEN_TMP="${_TEST_TMPDIR}"
	MERGEN_SNAPSHOT_DIR="${_TEST_TMPDIR}/snapshot"

	_mock_uci_set "mergen.global.enabled=1"
	_mock_uci_set "mergen.global.log_level=info"
	_mock_uci_set "mergen.global.default_table=100"
	_MOCK_CONFIG_LOADED="mergen"
}

tearDown() {
	if [ -n "$_TEST_TMPDIR" ] && [ -d "$_TEST_TMPDIR" ]; then
		rm -rf "$_TEST_TMPDIR"
	fi
}

# ── nft Availability Tests ─────────────────────────────

test_nft_available_detected() {
	# nft mock is defined, so it should be "available"
	MERGEN_NFT_AVAILABLE=""
	mergen_nft_available
	assertEquals "nft detected as available" 0 $?
	assertEquals "Cache set to 1" "1" "$MERGEN_NFT_AVAILABLE"
}

test_nft_available_cached() {
	MERGEN_NFT_AVAILABLE="1"
	mergen_nft_available
	assertEquals "Cached availability returns true" 0 $?
}

test_nft_unavailable_cached() {
	MERGEN_NFT_AVAILABLE="0"
	mergen_nft_available
	assertEquals "Cached unavailability returns false" 1 $?
}

# ── nft Init Tests ─────────────────────────────────────

test_nft_init_creates_table() {
	mergen_nft_init
	assertEquals "Init succeeds" 0 $?
	echo "$_NFT_TABLES" | grep -q "inet:mergen"
	assertEquals "Table created" 0 $?
}

test_nft_init_creates_chain() {
	mergen_nft_init
	echo "$_NFT_CHAINS" | grep -q "inet:mergen:prerouting"
	assertEquals "Chain created" 0 $?
}

test_nft_init_fails_when_unavailable() {
	MERGEN_NFT_AVAILABLE="0"
	mergen_nft_init
	assertEquals "Init fails when nft unavailable" 1 $?
}

# ── Set Create Tests ───────────────────────────────────

test_set_create_success() {
	mergen_nft_set_create "cloudflare"
	assertEquals "Set create succeeds" 0 $?
	echo "$_NFT_SETS" | grep -q "inet:mergen:mergen_cloudflare"
	assertEquals "Set registered" 0 $?
}

test_set_create_empty_name_fails() {
	mergen_nft_set_create ""
	assertEquals "Empty name fails" 1 $?
}

test_set_create_idempotent() {
	mergen_nft_set_create "testset"
	mergen_nft_set_create "testset"
	assertEquals "Second create succeeds" 0 $?
}

# ── Set Add (Bulk) Tests ───────────────────────────────

test_set_add_single_prefix() {
	mergen_nft_set_create "test1"
	mergen_nft_set_add "test1" "1.0.0.0/24"
	assertEquals "Single prefix add succeeds" 0 $?
}

test_set_add_multiple_prefixes() {
	mergen_nft_set_create "test2"
	local prefixes="1.0.0.0/24
1.1.1.0/24
2.0.0.0/16"
	mergen_nft_set_add "test2" "$prefixes"
	assertEquals "Multiple prefix add succeeds" 0 $?
}

test_set_add_creates_batch_file() {
	mergen_nft_set_create "batchtest"
	mergen_nft_set_add "batchtest" "10.0.0.0/8"
	# Batch file should be cleaned up after execution
	assertFalse "Batch file cleaned up" "[ -f '${MERGEN_TMP}/nft_batch_batchtest.nft' ]"
}

test_set_add_empty_list_fails() {
	mergen_nft_set_create "emptytest"
	mergen_nft_set_add "emptytest" ""
	assertEquals "Empty list fails" 1 $?
}

test_set_add_batch_content() {
	mergen_nft_set_create "contenttest"
	mergen_nft_set_add "contenttest" "10.0.0.0/8
172.16.0.0/12"
	# Verify batch content was processed
	echo "$_NFT_BATCH_CONTENT" | grep -q "flush set"
	assertEquals "Batch has flush command" 0 $?
	echo "$_NFT_BATCH_CONTENT" | grep -q "add element"
	assertEquals "Batch has add element command" 0 $?
}

# ── Set Flush Tests ────────────────────────────────────

test_set_flush_success() {
	mergen_nft_set_create "flushtest"
	mergen_nft_set_add "flushtest" "10.0.0.0/8"
	mergen_nft_set_flush "flushtest"
	assertEquals "Flush succeeds" 0 $?
}

# ── Set Destroy Tests ──────────────────────────────────

test_set_destroy_removes_set() {
	mergen_nft_set_create "destroytest"
	echo "$_NFT_SETS" | grep -q "mergen_destroytest"
	assertEquals "Set exists before destroy" 0 $?

	mergen_nft_set_destroy "destroytest"
	echo "$_NFT_SETS" | grep -q "mergen_destroytest"
	assertNotEquals "Set removed after destroy" 0 $?
}

test_set_destroy_noop_when_unavailable() {
	MERGEN_NFT_AVAILABLE="0"
	mergen_nft_set_destroy "noexist"
	assertEquals "Destroy noop when unavailable" 0 $?
}

# ── fwmark Rule Tests ──────────────────────────────────

test_nft_rule_add_success() {
	mergen_nft_init
	mergen_nft_set_create "fwtest"
	mergen_nft_rule_add "fwtest" "100"
	assertEquals "Rule add succeeds" 0 $?
	echo "$_NFT_RULES" | grep -q "@mergen_fwtest"
	assertEquals "Rule references set" 0 $?
	echo "$_NFT_RULES" | grep -q "mark set 100"
	assertEquals "Rule has correct mark" 0 $?
}

test_nft_rule_add_empty_params_fails() {
	mergen_nft_rule_add "" "100"
	assertEquals "Empty rule name fails" 1 $?
	mergen_nft_rule_add "test" ""
	assertEquals "Empty fwmark fails" 1 $?
}

# ── Cleanup Tests ──────────────────────────────────────

test_nft_cleanup_removes_all() {
	mergen_nft_init
	mergen_nft_set_create "set1"
	mergen_nft_set_create "set2"
	mergen_nft_cleanup
	assertEquals "Cleanup succeeds" 0 $?
	assertEquals "Tables cleared" "" "$(echo "$_NFT_TABLES" | tr -d ' ')"
}

test_nft_cleanup_noop_when_unavailable() {
	MERGEN_NFT_AVAILABLE="0"
	mergen_nft_cleanup
	assertEquals "Cleanup noop when unavailable" 0 $?
}

# ── Route Apply nftables Integration ───────────────────

test_apply_uses_nftables_when_available() {
	MERGEN_NFT_AVAILABLE=""
	_MOCK_FOREACH_SECTIONS="rule1"
	_mock_uci_set "mergen.rule1.name=cloudflare"
	_mock_uci_set "mergen.rule1.ip=1.0.0.0/24"
	_mock_uci_set "mergen.rule1.via=wg0"
	_mock_uci_set "mergen.rule1.priority=100"
	_mock_uci_set "mergen.rule1.enabled=1"

	mergen_route_apply "cloudflare"
	assertEquals "Apply succeeds" 0 $?

	# Verify nftables set was created
	echo "$_NFT_SETS" | grep -q "mergen_cloudflare"
	assertEquals "nftables set created" 0 $?

	# Verify fwmark ip rule was added
	echo "$_IP_RULES" | grep -q "fwmark"
	assertEquals "fwmark ip rule added" 0 $?
}

test_apply_fallback_without_nftables() {
	MERGEN_NFT_AVAILABLE="0"
	MERGEN_IPSET_AVAILABLE="0"
	MERGEN_ENGINE_ACTIVE=""
	_MOCK_FOREACH_SECTIONS="rule1"
	_mock_uci_set "mergen.rule1.name=test_fb"
	_mock_uci_set "mergen.rule1.ip=10.0.0.0/8"
	_mock_uci_set "mergen.rule1.via=wg0"
	_mock_uci_set "mergen.rule1.priority=100"
	_mock_uci_set "mergen.rule1.enabled=1"

	mergen_route_apply "test_fb"
	assertEquals "Apply succeeds without nft" 0 $?

	# Verify per-prefix ip rule was added (fallback)
	echo "$_IP_RULES" | grep -q "to 10.0.0.0/8"
	assertEquals "Per-prefix ip rule added" 0 $?

	# Verify NO nftables set was created
	echo "$_NFT_SETS" | grep -q "mergen_test_fb"
	assertNotEquals "No nftables set" 0 $?
}

test_apply_creates_routes_regardless() {
	MERGEN_NFT_AVAILABLE=""
	_MOCK_FOREACH_SECTIONS="rule1"
	_mock_uci_set "mergen.rule1.name=routetest"
	_mock_uci_set "mergen.rule1.ip=10.0.0.0/8"
	_mock_uci_set "mergen.rule1.via=wg0"
	_mock_uci_set "mergen.rule1.priority=100"
	_mock_uci_set "mergen.rule1.enabled=1"

	mergen_route_apply "routetest"

	# ip routes are always created (regardless of nftables availability)
	echo "$_IP_ROUTES" | grep -q "10.0.0.0/8"
	assertEquals "IP routes created" 0 $?
}

# ── Route Remove nftables Integration ──────────────────

test_remove_destroys_nftables_set() {
	MERGEN_NFT_AVAILABLE=""
	_MOCK_FOREACH_SECTIONS="rule1"
	_mock_uci_set "mergen.rule1.name=rmtest"
	_mock_uci_set "mergen.rule1.ip=10.0.0.0/8"
	_mock_uci_set "mergen.rule1.via=wg0"
	_mock_uci_set "mergen.rule1.priority=100"
	_mock_uci_set "mergen.rule1.enabled=1"

	# Apply first
	mergen_route_apply "rmtest"
	echo "$_NFT_SETS" | grep -q "mergen_rmtest"
	assertEquals "Set exists after apply" 0 $?

	# Remove
	mergen_route_remove "rmtest"
	echo "$_NFT_SETS" | grep -q "mergen_rmtest"
	assertNotEquals "Set removed after route remove" 0 $?
}

# ── Snapshot nftables Integration ──────────────────────

test_snapshot_saves_nftables_state() {
	MERGEN_NFT_AVAILABLE=""
	mergen_nft_init
	mergen_nft_set_create "snaptest"

	mergen_snapshot_create

	assertTrue "nftsets.save created" "[ -f '${MERGEN_SNAPSHOT_DIR}/nftsets.save' ]"
}

test_snapshot_restore_calls_nft_restore() {
	MERGEN_NFT_AVAILABLE=""
	mergen_nft_init

	# Create a snapshot
	mergen_snapshot_create
	assertTrue "Snapshot exists" "[ -f '${MERGEN_SNAPSHOT_DIR}/meta' ]"

	# Restore should not fail
	mergen_snapshot_restore
	assertEquals "Snapshot restore succeeds" 0 $?
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

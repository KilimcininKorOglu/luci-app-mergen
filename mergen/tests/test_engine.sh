#!/bin/sh
# Test suite for mergen/files/usr/lib/mergen/engine.sh
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
		del_list) _mock_uci_del_list "$1" ;;
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
	# Add to foreach sections
	_MOCK_FOREACH_SECTIONS="${_MOCK_FOREACH_SECTIONS} ${idx}"
	echo "$idx"
}

_mock_uci_delete() {
	local path="$1"
	_MOCK_UCI_STORE="$(echo "$_MOCK_UCI_STORE" | grep -v "^${path}" 2>/dev/null)"
	# Remove from foreach sections
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
	# Append to existing value with space separator (simulates UCI list)
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

_mock_uci_del_list() { :; }

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

# Mock ip command for validate_interface
ip() {
	case "$1" in
		link)
			# Simulate interface check: wg0, eth0, br-lan exist
			case "$3" in
				wg0|eth0|br-lan) return 0 ;;
				*) return 1 ;;
			esac
			;;
		-br)
			echo "lo       UP"
			echo "eth0     UP"
			echo "br-lan   UP"
			echo "wg0      UP"
			;;
	esac
}

# ── Source modules under test ───────────────────────────

. "${MERGEN_ROOT}/files/usr/lib/mergen/core.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/utils.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/engine.sh"

# Override mergen_uci_add to avoid subshell variable loss.
# The real mergen_uci_add uses $(uci add ...) which creates a subshell,
# causing _MOCK_FOREACH_SECTIONS updates to be lost.
mergen_uci_add() {
	local type="$1"
	_MOCK_ADD_COUNTER=$((_MOCK_ADD_COUNTER + 1))
	local idx="cfg${_MOCK_ADD_COUNTER}"
	_MOCK_UCI_STORE="${_MOCK_UCI_STORE}
${MERGEN_CONF}.${idx}=${type}"
	_MOCK_FOREACH_SECTIONS="${_MOCK_FOREACH_SECTIONS} ${idx}"
	MERGEN_UCI_RESULT="$idx"
}

# ── Setup/Teardown ──────────────────────────────────────

setUp() {
	_MOCK_UCI_STORE=""
	_MOCK_FOREACH_SECTIONS=""
	_MOCK_ADD_COUNTER=0
	MERGEN_UCI_RESULT=""
	MERGEN_UCI_LIST_RESULT=""
	MERGEN_VALIDATE_ERR=""
	MERGEN_RULE_NAME=""
	MERGEN_RULE_VIA=""
	MERGEN_RULE_PRIORITY=""
	MERGEN_RULE_ENABLED=""
	MERGEN_RULE_TYPE=""
	MERGEN_RULE_TARGETS=""
	MERGEN_RULE_SECTION=""

	# Set up default config
	_mock_uci_set "mergen.global.enabled=1"
	_mock_uci_set "mergen.global.default_table=100"
	_mock_uci_set "mergen.global.log_level=info"
	_MOCK_CONFIG_LOADED="mergen"
}

# ── Rule Add Tests ──────────────────────────────────────

test_rule_add_single_asn() {
	mergen_rule_add "cloudflare" "asn" "13335" "wg0"
	assertEquals "Add single ASN rule" 0 $?

	# Verify UCI entries
	local stored_name
	stored_name="$(_mock_uci_get "mergen.cfg1.name")"
	assertEquals "Name stored" "cloudflare" "$stored_name"

	local stored_via
	stored_via="$(_mock_uci_get "mergen.cfg1.via")"
	assertEquals "Via stored" "wg0" "$stored_via"

	local stored_asn
	stored_asn="$(_mock_uci_get "mergen.cfg1.asn")"
	assertEquals "ASN stored" "13335" "$stored_asn"

	local stored_enabled
	stored_enabled="$(_mock_uci_get "mergen.cfg1.enabled")"
	assertEquals "Enabled by default" "1" "$stored_enabled"
}

test_rule_add_multiple_asns() {
	mergen_rule_add "google" "asn" "15169,36040" "wg0" "200"
	assertEquals "Add multi-ASN rule" 0 $?

	local stored_asn
	stored_asn="$(_mock_uci_get "mergen.cfg1.asn")"
	# Should contain both ASNs (space-separated in mock list)
	echo "$stored_asn" | grep -q "15169"
	assertEquals "First ASN in list" 0 $?
	echo "$stored_asn" | grep -q "36040"
	assertEquals "Second ASN in list" 0 $?

	local stored_priority
	stored_priority="$(_mock_uci_get "mergen.cfg1.priority")"
	assertEquals "Custom priority" "200" "$stored_priority"
}

test_rule_add_single_ip() {
	mergen_rule_add "office" "ip" "10.0.0.0/8" "eth0" "50"
	assertEquals "Add single IP rule" 0 $?

	local stored_ip
	stored_ip="$(_mock_uci_get "mergen.cfg1.ip")"
	assertEquals "IP stored" "10.0.0.0/8" "$stored_ip"
}

test_rule_add_multiple_ips() {
	mergen_rule_add "office-nets" "ip" "10.0.0.0/8,172.16.0.0/12" "eth0" "50"
	assertEquals "Add multi-IP rule" 0 $?

	local stored_ip
	stored_ip="$(_mock_uci_get "mergen.cfg1.ip")"
	echo "$stored_ip" | grep -q "10.0.0.0/8"
	assertEquals "First IP in list" 0 $?
	echo "$stored_ip" | grep -q "172.16.0.0/12"
	assertEquals "Second IP in list" 0 $?
}

test_rule_add_default_priority() {
	mergen_rule_add "test-rule" "asn" "13335" "wg0"
	assertEquals "Add with default priority" 0 $?

	local stored_priority
	stored_priority="$(_mock_uci_get "mergen.cfg1.priority")"
	assertEquals "Default priority from UCI" "100" "$stored_priority"
}

test_rule_add_strips_as_prefix() {
	mergen_rule_add "test-as" "asn" "AS13335" "wg0"
	assertEquals "Add with AS prefix" 0 $?

	local stored_asn
	stored_asn="$(_mock_uci_get "mergen.cfg1.asn")"
	assertEquals "AS prefix stripped" "13335" "$stored_asn"
}

# ── Rule Add Validation Tests ───────────────────────────

test_rule_add_duplicate_name() {
	mergen_rule_add "cloudflare" "asn" "13335" "wg0"
	assertEquals "First add succeeds" 0 $?

	mergen_rule_add "cloudflare" "asn" "15169" "wg0"
	assertNotEquals "Duplicate name rejected" 0 $?
}

test_rule_add_empty_name() {
	mergen_rule_add "" "asn" "13335" "wg0"
	assertNotEquals "Empty name rejected" 0 $?
}

test_rule_add_invalid_type() {
	mergen_rule_add "test" "invalid" "13335" "wg0"
	assertNotEquals "Invalid type rejected" 0 $?
}

test_rule_add_invalid_asn() {
	mergen_rule_add "bad-asn" "asn" "abc" "wg0"
	assertNotEquals "Invalid ASN rejected" 0 $?
}

test_rule_add_invalid_ip() {
	mergen_rule_add "bad-ip" "ip" "999.999.999.999/8" "wg0"
	assertNotEquals "Invalid IP rejected" 0 $?
}

test_rule_add_empty_targets() {
	mergen_rule_add "empty-targets" "asn" "" "wg0"
	assertNotEquals "Empty targets rejected" 0 $?
}

test_rule_add_empty_via() {
	mergen_rule_add "no-via" "asn" "13335" ""
	assertNotEquals "Empty via rejected" 0 $?
}

test_rule_add_invalid_priority() {
	mergen_rule_add "bad-pri" "asn" "13335" "wg0" "99999"
	assertNotEquals "Invalid priority rejected" 0 $?
}

# ── Rule Remove Tests ───────────────────────────────────

test_rule_remove_existing() {
	mergen_rule_add "cloudflare" "asn" "13335" "wg0"
	assertEquals "Add succeeds" 0 $?

	mergen_rule_remove "cloudflare"
	assertEquals "Remove succeeds" 0 $?

	mergen_find_rule_by_name "cloudflare"
	assertNotEquals "Rule no longer found" 0 $?
}

test_rule_remove_nonexistent() {
	mergen_rule_remove "nonexistent"
	assertNotEquals "Remove nonexistent fails" 0 $?
}

test_rule_remove_empty_name() {
	mergen_rule_remove ""
	assertNotEquals "Remove empty name fails" 0 $?
}

# ── Rule Get Tests ──────────────────────────────────────

test_rule_get_existing() {
	mergen_rule_add "cloudflare" "asn" "13335" "wg0" "150"
	assertEquals "Add succeeds" 0 $?

	mergen_rule_get "cloudflare"
	assertEquals "Get succeeds" 0 $?
	assertEquals "Name matches" "cloudflare" "$MERGEN_RULE_NAME"
	assertEquals "Via matches" "wg0" "$MERGEN_RULE_VIA"
	assertEquals "Priority matches" "150" "$MERGEN_RULE_PRIORITY"
	assertEquals "Enabled by default" "1" "$MERGEN_RULE_ENABLED"
	assertEquals "Type is ASN" "asn" "$MERGEN_RULE_TYPE"
	assertEquals "Target stored" "13335" "$MERGEN_RULE_TARGETS"
}

test_rule_get_ip_rule() {
	mergen_rule_add "office" "ip" "10.0.0.0/8" "eth0" "50"
	assertEquals "Add IP rule" 0 $?

	mergen_rule_get "office"
	assertEquals "Get IP rule" 0 $?
	assertEquals "Type is IP" "ip" "$MERGEN_RULE_TYPE"
	assertEquals "Target stored" "10.0.0.0/8" "$MERGEN_RULE_TARGETS"
}

test_rule_get_nonexistent() {
	mergen_rule_get "nonexistent"
	assertNotEquals "Get nonexistent fails" 0 $?
}

test_rule_get_empty_name() {
	mergen_rule_get ""
	assertNotEquals "Get empty name fails" 0 $?
}

# ── Rule Toggle Tests ───────────────────────────────────

test_rule_toggle_disable() {
	mergen_rule_add "cloudflare" "asn" "13335" "wg0"

	mergen_rule_toggle "cloudflare" "0"
	assertEquals "Toggle disable" 0 $?

	mergen_rule_get "cloudflare"
	assertEquals "Rule disabled" "0" "$MERGEN_RULE_ENABLED"
}

test_rule_toggle_enable() {
	mergen_rule_add "cloudflare" "asn" "13335" "wg0"
	mergen_rule_toggle "cloudflare" "0"

	mergen_rule_toggle "cloudflare" "1"
	assertEquals "Toggle enable" 0 $?

	mergen_rule_get "cloudflare"
	assertEquals "Rule enabled" "1" "$MERGEN_RULE_ENABLED"
}

test_rule_toggle_invalid_state() {
	mergen_rule_add "cloudflare" "asn" "13335" "wg0"

	mergen_rule_toggle "cloudflare" "2"
	assertNotEquals "Invalid toggle state rejected" 0 $?
}

test_rule_toggle_nonexistent() {
	mergen_rule_toggle "nonexistent" "0"
	assertNotEquals "Toggle nonexistent fails" 0 $?
}

# ── Rule Update Tests ───────────────────────────────────

test_rule_update_priority() {
	mergen_rule_add "cloudflare" "asn" "13335" "wg0" "100"

	mergen_rule_update "cloudflare" "priority" "200"
	assertEquals "Update priority" 0 $?

	mergen_rule_get "cloudflare"
	assertEquals "Priority updated" "200" "$MERGEN_RULE_PRIORITY"
}

test_rule_update_via() {
	mergen_rule_add "cloudflare" "asn" "13335" "wg0"

	mergen_rule_update "cloudflare" "via" "eth0"
	assertEquals "Update via" 0 $?

	mergen_rule_get "cloudflare"
	assertEquals "Via updated" "eth0" "$MERGEN_RULE_VIA"
}

test_rule_update_enabled() {
	mergen_rule_add "cloudflare" "asn" "13335" "wg0"

	mergen_rule_update "cloudflare" "enabled" "0"
	assertEquals "Update enabled" 0 $?

	mergen_rule_get "cloudflare"
	assertEquals "Enabled updated" "0" "$MERGEN_RULE_ENABLED"
}

test_rule_update_invalid_field() {
	mergen_rule_add "cloudflare" "asn" "13335" "wg0"

	mergen_rule_update "cloudflare" "name" "new-name"
	assertNotEquals "Invalid field rejected" 0 $?
}

test_rule_update_nonexistent() {
	mergen_rule_update "nonexistent" "priority" "200"
	assertNotEquals "Update nonexistent fails" 0 $?
}

test_rule_update_invalid_priority() {
	mergen_rule_add "cloudflare" "asn" "13335" "wg0"

	mergen_rule_update "cloudflare" "priority" "99999"
	assertNotEquals "Invalid priority rejected" 0 $?
}

# ── Rule List Tests ─────────────────────────────────────

test_rule_list_empty() {
	local output
	output="$(mergen_rule_list)"
	echo "$output" | grep -q "(kayıtlı kural yok)"
	assertEquals "Empty list message" 0 $?
}

test_rule_list_with_rules() {
	mergen_rule_add "cloudflare" "asn" "13335" "wg0" "100"
	mergen_rule_add "office" "ip" "10.0.0.0/8" "eth0" "50"

	local output
	output="$(mergen_rule_list)"

	echo "$output" | grep -q "ID"
	assertEquals "Header present" 0 $?

	echo "$output" | grep -q "cloudflare"
	assertEquals "Cloudflare rule listed" 0 $?

	echo "$output" | grep -q "office"
	assertEquals "Office rule listed" 0 $?
}

test_rule_list_shows_disabled() {
	mergen_rule_add "cloudflare" "asn" "13335" "wg0"
	mergen_rule_toggle "cloudflare" "0"

	local output
	output="$(mergen_rule_list)"

	echo "$output" | grep -q "disabled"
	assertEquals "Disabled status shown" 0 $?
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

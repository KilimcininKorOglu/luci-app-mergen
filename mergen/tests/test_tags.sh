#!/bin/sh
# Test suite for rule tagging/grouping (T029)
# Tests tag add, remove, get, has_tag, list_by_tag, toggle_by_tag
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

_mock_uci_del_list() {
	local assignment="$1"
	local key="${assignment%%=*}"
	local value="${assignment#*=}"
	local existing
	existing="$(_mock_uci_get "$key")"

	if [ -z "$existing" ]; then
		return 0
	fi

	local new_list="" item
	for item in $existing; do
		if [ "$item" != "$value" ]; then
			if [ -n "$new_list" ]; then
				new_list="$new_list $item"
			else
				new_list="$item"
			fi
		fi
	done

	_MOCK_UCI_STORE="$(echo "$_MOCK_UCI_STORE" | grep -v "^${key}=" 2>/dev/null)"
	if [ -n "$new_list" ]; then
		_MOCK_UCI_STORE="${_MOCK_UCI_STORE}
${key}=${new_list}"
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

# Mock ip command (not needed for tag tests)
ip() { return 0; }

# ── Source modules under test ─────────────────────────────

. "${MERGEN_ROOT}/files/usr/lib/mergen/core.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/utils.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/engine.sh"

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

# ── Setup/Teardown ────────────────────────────────────────

setUp() {
	_MOCK_UCI_STORE=""
	_MOCK_FOREACH_SECTIONS=""
	_MOCK_ADD_COUNTER=0
	MERGEN_UCI_RESULT=""
	MERGEN_RULE_TAGS=""
	MERGEN_TAG_TOGGLE_COUNT=0

	_mock_uci_set "mergen.global.enabled=1"
	_mock_uci_set "mergen.global.default_table=100"
	_mock_uci_set "mergen.global.log_level=info"
	_MOCK_CONFIG_LOADED="mergen"
}

# ── Helper ────────────────────────────────────────────────

_add_rule() {
	local name="$1" type="$2" targets="$3" via="$4" priority="${5:-100}"
	mergen_rule_add "$name" "$type" "$targets" "$via" "$priority"
}

# ── Tag Add Tests ─────────────────────────────────────────

test_tag_add_single() {
	_add_rule "webvpn" "asn" "15169" "wan" 100
	mergen_rule_tag_add "webvpn" "vpn"
	assertEquals "tag add should succeed" 0 $?

	mergen_rule_tags_get "webvpn"
	echo "$MERGEN_RULE_TAGS" | grep -q "vpn"
	assertEquals "tag should be present" 0 $?
}

test_tag_add_multiple() {
	_add_rule "webvpn" "asn" "15169" "wan" 100
	mergen_rule_tag_add "webvpn" "vpn"
	mergen_rule_tag_add "webvpn" "work"

	mergen_rule_tags_get "webvpn"
	echo "$MERGEN_RULE_TAGS" | grep -q "vpn"
	assertEquals "first tag present" 0 $?
	echo "$MERGEN_RULE_TAGS" | grep -q "work"
	assertEquals "second tag present" 0 $?
}

test_tag_add_duplicate() {
	_add_rule "webvpn" "asn" "15169" "wan" 100
	mergen_rule_tag_add "webvpn" "vpn"
	mergen_rule_tag_add "webvpn" "vpn"
	assertEquals "duplicate tag add should succeed (idempotent)" 0 $?

	mergen_rule_tags_get "webvpn"
	local count
	count=$(echo "$MERGEN_RULE_TAGS" | tr ' ' '\n' | grep -c "^vpn$")
	assertEquals "tag should appear only once" 1 "$count"
}

test_tag_add_nonexistent_rule() {
	mergen_rule_tag_add "noexist" "vpn"
	assertNotEquals "should fail for nonexistent rule" 0 $?
}

test_tag_add_empty_params() {
	mergen_rule_tag_add "" ""
	assertNotEquals "should fail for empty params" 0 $?
}

# ── Tag Remove Tests ──────────────────────────────────────

test_tag_remove() {
	_add_rule "webvpn" "asn" "15169" "wan" 100
	mergen_rule_tag_add "webvpn" "vpn"
	mergen_rule_tag_add "webvpn" "work"

	mergen_rule_tag_remove "webvpn" "vpn"
	assertEquals "tag remove should succeed" 0 $?

	mergen_rule_tags_get "webvpn"
	echo "$MERGEN_RULE_TAGS" | grep -q "vpn"
	assertNotEquals "vpn tag should be gone" 0 $?
	echo "$MERGEN_RULE_TAGS" | grep -q "work"
	assertEquals "work tag should remain" 0 $?
}

test_tag_remove_nonexistent_rule() {
	mergen_rule_tag_remove "noexist" "vpn"
	assertNotEquals "should fail for nonexistent rule" 0 $?
}

test_tag_remove_last_tag() {
	_add_rule "webvpn" "asn" "15169" "wan" 100
	mergen_rule_tag_add "webvpn" "vpn"

	mergen_rule_tag_remove "webvpn" "vpn"
	assertEquals "remove last tag should succeed" 0 $?

	mergen_rule_tags_get "webvpn"
	assertEquals "tags should be empty" "" "$MERGEN_RULE_TAGS"
}

# ── Has Tag Tests ─────────────────────────────────────────

test_has_tag_true() {
	_add_rule "webvpn" "asn" "15169" "wan" 100
	mergen_rule_tag_add "webvpn" "vpn"

	mergen_rule_has_tag "webvpn" "vpn"
	assertEquals "should return 0 when tag exists" 0 $?
}

test_has_tag_false() {
	_add_rule "webvpn" "asn" "15169" "wan" 100
	mergen_rule_tag_add "webvpn" "vpn"

	mergen_rule_has_tag "webvpn" "work"
	assertNotEquals "should return non-zero when tag missing" 0 $?
}

test_has_tag_no_tags() {
	_add_rule "webvpn" "asn" "15169" "wan" 100

	mergen_rule_has_tag "webvpn" "vpn"
	assertNotEquals "should return non-zero when no tags" 0 $?
}

# ── Tags Get Tests ────────────────────────────────────────

test_tags_get_empty() {
	_add_rule "webvpn" "asn" "15169" "wan" 100

	mergen_rule_tags_get "webvpn"
	assertEquals "should succeed" 0 $?
	assertEquals "tags should be empty" "" "$MERGEN_RULE_TAGS"
}

test_tags_get_multiple() {
	_add_rule "webvpn" "asn" "15169" "wan" 100
	mergen_rule_tag_add "webvpn" "vpn"
	mergen_rule_tag_add "webvpn" "work"
	mergen_rule_tag_add "webvpn" "critical"

	mergen_rule_tags_get "webvpn"
	assertEquals "should succeed" 0 $?

	local count
	count=$(echo "$MERGEN_RULE_TAGS" | wc -w | tr -d ' ')
	assertEquals "should have 3 tags" 3 "$count"
}

test_tags_get_nonexistent_rule() {
	mergen_rule_tags_get "noexist"
	assertNotEquals "should fail for nonexistent rule" 0 $?
}

# ── List By Tag Tests ─────────────────────────────────────

test_list_by_tag_filters() {
	_add_rule "rule1" "asn" "15169" "wan" 100
	_add_rule "rule2" "ip" "10.0.0.0/8" "vpn" 200
	_add_rule "rule3" "asn" "13335" "wan" 150

	mergen_rule_tag_add "rule1" "vpn"
	mergen_rule_tag_add "rule2" "vpn"
	mergen_rule_tag_add "rule3" "work"

	local output
	output="$(mergen_rule_list_by_tag "vpn")"

	echo "$output" | grep -q "rule1"
	assertEquals "rule1 should be listed" 0 $?
	echo "$output" | grep -q "rule2"
	assertEquals "rule2 should be listed" 0 $?
	echo "$output" | grep -q "rule3"
	assertNotEquals "rule3 should NOT be listed" 0 $?
}

test_list_by_tag_empty_result() {
	_add_rule "rule1" "asn" "15169" "wan" 100
	mergen_rule_tag_add "rule1" "work"

	local output
	output="$(mergen_rule_list_by_tag "nonexistent")"
	echo "$output" | grep -q "kural yok"
	assertEquals "should show no-match message" 0 $?
}

test_list_by_tag_empty_param() {
	mergen_rule_list_by_tag ""
	assertNotEquals "should fail for empty tag" 0 $?
}

# ── Toggle By Tag Tests ───────────────────────────────────

test_toggle_by_tag_disable() {
	_add_rule "rule1" "asn" "15169" "wan" 100
	_add_rule "rule2" "ip" "10.0.0.0/8" "vpn" 200
	_add_rule "rule3" "asn" "13335" "wan" 150

	mergen_rule_tag_add "rule1" "vpn"
	mergen_rule_tag_add "rule2" "vpn"
	mergen_rule_tag_add "rule3" "work"

	mergen_rule_toggle_by_tag "vpn" "0"
	assertEquals "toggle should succeed" 0 $?
	assertEquals "should toggle 2 rules" 2 "$MERGEN_TAG_TOGGLE_COUNT"

	# Verify rule1 and rule2 disabled
	mergen_rule_get "rule1"
	assertEquals "rule1 should be disabled" "0" "$MERGEN_RULE_ENABLED"
	mergen_rule_get "rule2"
	assertEquals "rule2 should be disabled" "0" "$MERGEN_RULE_ENABLED"

	# Verify rule3 still enabled
	mergen_rule_get "rule3"
	assertEquals "rule3 should still be enabled" "1" "$MERGEN_RULE_ENABLED"
}

test_toggle_by_tag_enable() {
	_add_rule "rule1" "asn" "15169" "wan" 100
	_add_rule "rule2" "ip" "10.0.0.0/8" "vpn" 200

	mergen_rule_tag_add "rule1" "vpn"
	mergen_rule_tag_add "rule2" "vpn"

	# Disable first
	mergen_rule_toggle "rule1" "0"
	mergen_rule_toggle "rule2" "0"

	# Re-enable by tag
	mergen_rule_toggle_by_tag "vpn" "1"
	assertEquals "should toggle 2 rules" 2 "$MERGEN_TAG_TOGGLE_COUNT"

	mergen_rule_get "rule1"
	assertEquals "rule1 should be enabled" "1" "$MERGEN_RULE_ENABLED"
	mergen_rule_get "rule2"
	assertEquals "rule2 should be enabled" "1" "$MERGEN_RULE_ENABLED"
}

test_toggle_by_tag_no_match() {
	_add_rule "rule1" "asn" "15169" "wan" 100
	mergen_rule_tag_add "rule1" "work"

	mergen_rule_toggle_by_tag "nonexistent" "0"
	assertEquals "should return 1 for no matches" 1 $?
	assertEquals "toggle count should be 0" 0 "$MERGEN_TAG_TOGGLE_COUNT"
}

test_toggle_by_tag_empty_param() {
	mergen_rule_toggle_by_tag "" "0"
	assertNotEquals "should fail for empty tag" 0 $?
}

test_toggle_by_tag_invalid_state() {
	mergen_rule_toggle_by_tag "vpn" "invalid"
	assertNotEquals "should fail for invalid state" 0 $?
}

# ── Rule Get Loads Tags ───────────────────────────────────

test_rule_get_includes_tags() {
	_add_rule "webvpn" "asn" "15169" "wan" 100
	mergen_rule_tag_add "webvpn" "vpn"
	mergen_rule_tag_add "webvpn" "work"

	mergen_rule_get "webvpn"
	assertEquals "rule get should succeed" 0 $?
	echo "$MERGEN_RULE_TAGS" | grep -q "vpn"
	assertEquals "tags should include vpn" 0 $?
	echo "$MERGEN_RULE_TAGS" | grep -q "work"
	assertEquals "tags should include work" 0 $?
}

# ── Load Runner ───────────────────────────────────────────
. "${MERGEN_TEST_DIR}/shunit2"

#!/bin/sh
# Test suite for JSON import/export (T030)
# Tests mergen_rule_export_json, mergen_rule_import_json, mergen_load_rules_dir
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

# Mock ip command
ip() { return 0; }

# ── Mock jsonfilter ───────────────────────────────────────
# Simulates OpenWrt jsonfilter using awk for test JSON files
# Handles: @.rules, @.rules.length, @.rules[N].field

jsonfilter() {
	local file="" expr=""

	while [ $# -gt 0 ]; do
		case "$1" in
			-i) file="$2"; shift 2 ;;
			-e) expr="$2"; shift 2 ;;
			*) shift ;;
		esac
	done

	[ -z "$file" ] && return 1
	[ ! -f "$file" ] && return 1

	case "$expr" in
		'@.rules')
			grep -q '"rules"' "$file" && return 0
			return 1
			;;
		'@.rules.length')
			awk '
				BEGIN { in_arr=0; brace_depth=0; count=0 }
				/"rules"[[:space:]]*:/ { in_arr=1 }
				in_arr && /\{/ {
					brace_depth++
					if (brace_depth == 1) count++
				}
				in_arr && /\}/ { brace_depth-- }
				in_arr && /\]/ && brace_depth == 0 { in_arr=0 }
				END { print count }
			' "$file"
			;;
		@.rules\[*\].*)
			local idx field
			idx=$(echo "$expr" | sed 's/@\.rules\[\([0-9]*\)\]\.\(.*\)/\1/')
			field=$(echo "$expr" | sed 's/@\.rules\[\([0-9]*\)\]\.\(.*\)/\2/')
			_json_extract_field "$file" "$idx" "$field"
			;;
		*)
			return 1
			;;
	esac
}

# Extract a field from the Nth rule in a JSON file using awk
_json_extract_field() {
	local file="$1"
	local target_idx="$2"
	local field="$3"

	local result
	result=$(awk -v target="$target_idx" -v fld="$field" '
		BEGIN {
			in_arr=0; brace_depth=0; rule_idx=-1; found=0
			pat = "\"" fld "\""
		}
		/"rules"[[:space:]]*:/ { in_arr=1 }
		in_arr && /\{/ {
			brace_depth++
			if (brace_depth == 1) rule_idx++
		}
		in_arr && /\}/ { brace_depth-- }
		in_arr && brace_depth == 1 && rule_idx == target {
			if (index($0, pat) > 0) {
				line = $0
				idx = index(line, pat)
				line = substr(line, idx + length(pat))
				sub(/^[[:space:]]*:[[:space:]]*/, "", line)
				sub(/[[:space:]]*,?[[:space:]]*$/, "", line)
				print line
				found=1
			}
		}
		END { if (!found) exit 1 }
	' "$file")

	[ $? -ne 0 ] && return 1
	[ -z "$result" ] && return 1

	# Post-process the value
	case "$result" in
		\"*\")
			# String — strip quotes
			echo "$result" | sed 's/^"//;s/"$//'
			;;
		\[*)
			# Array — extract elements, output space-separated
			echo "$result" | sed 's/^\[//;s/\]$//' | sed 's/"//g' | tr ',' ' ' | tr -s ' ' | sed 's/^ //;s/ $//'
			;;
		*)
			# Number or other
			echo "$result"
			;;
	esac
}

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

_TEST_TMPDIR=""

setUp() {
	_MOCK_UCI_STORE=""
	_MOCK_FOREACH_SECTIONS=""
	_MOCK_ADD_COUNTER=0
	MERGEN_UCI_RESULT=""
	MERGEN_RULE_TAGS=""
	MERGEN_IMPORT_COUNT=0
	MERGEN_IMPORT_SKIP=0
	MERGEN_IMPORT_ERROR=0

	_mock_uci_set "mergen.global.enabled=1"
	_mock_uci_set "mergen.global.default_table=100"
	_mock_uci_set "mergen.global.log_level=info"
	_MOCK_CONFIG_LOADED="mergen"

	_TEST_TMPDIR="$(mktemp -d)"
}

tearDown() {
	[ -n "$_TEST_TMPDIR" ] && rm -rf "$_TEST_TMPDIR"
}

# ── Helper ────────────────────────────────────────────────

_add_rule() {
	local name="$1" type="$2" targets="$3" via="$4" priority="${5:-100}"
	mergen_rule_add "$name" "$type" "$targets" "$via" "$priority"
}

_write_json() {
	local file="$1"
	shift
	cat > "$file" <<EOF
$@
EOF
}

# ── Export Tests ──────────────────────────────────────────

test_export_empty() {
	local output
	output="$(mergen_rule_export_json)"

	echo "$output" | grep -q '"rules"'
	assertEquals "should contain rules key" 0 $?
	echo "$output" | grep -q '\[\]'
	assertNotEquals "rules array should exist" "" "$output"
}

test_export_single_asn_rule() {
	_add_rule "cloudflare" "asn" "13335" "wg0" "100"

	local output
	output="$(mergen_rule_export_json)"

	echo "$output" | grep -q '"name": "cloudflare"'
	assertEquals "should have name" 0 $?
	echo "$output" | grep -q '"asn": 13335'
	assertEquals "should have asn" 0 $?
	echo "$output" | grep -q '"via": "wg0"'
	assertEquals "should have via" 0 $?
	echo "$output" | grep -q '"priority": 100'
	assertEquals "should have priority" 0 $?
}

test_export_multiple_asn_rule() {
	_add_rule "google" "asn" "15169,36040" "wg0" "200"

	local output
	output="$(mergen_rule_export_json)"

	echo "$output" | grep -q '"asn": \[15169, 36040\]'
	assertEquals "should have asn array" 0 $?
}

test_export_ip_rule() {
	_add_rule "internal" "ip" "10.0.0.0/8" "lan" "50"

	local output
	output="$(mergen_rule_export_json)"

	echo "$output" | grep -q '"ip": "10.0.0.0/8"'
	assertEquals "should have ip" 0 $?
}

test_export_multiple_ip_rule() {
	_add_rule "internal" "ip" "10.0.0.0/8,172.16.0.0/12" "lan" "50"

	local output
	output="$(mergen_rule_export_json)"

	echo "$output" | grep -q '"ip": \["10.0.0.0/8", "172.16.0.0/12"\]'
	assertEquals "should have ip array" 0 $?
}

test_export_multiple_rules() {
	_add_rule "cloudflare" "asn" "13335" "wg0" "100"
	_add_rule "internal" "ip" "10.0.0.0/8" "lan" "50"

	local output
	output="$(mergen_rule_export_json)"

	echo "$output" | grep -q '"name": "cloudflare"'
	assertEquals "should have first rule" 0 $?
	echo "$output" | grep -q '"name": "internal"'
	assertEquals "should have second rule" 0 $?
}

test_export_with_tags() {
	_add_rule "webvpn" "asn" "13335" "wg0" "100"
	mergen_rule_tag_add "webvpn" "vpn"
	mergen_rule_tag_add "webvpn" "work"

	local output
	output="$(mergen_rule_export_json)"

	echo "$output" | grep -q '"tags"'
	assertEquals "should have tags key" 0 $?
	echo "$output" | grep -q '"vpn"'
	assertEquals "should have vpn tag" 0 $?
	echo "$output" | grep -q '"work"'
	assertEquals "should have work tag" 0 $?
}

test_export_disabled_rule() {
	_add_rule "myrule" "asn" "13335" "wg0" "100"
	mergen_rule_toggle "myrule" "0"

	local output
	output="$(mergen_rule_export_json)"

	echo "$output" | grep -q '"enabled": 0'
	assertEquals "should have enabled: 0" 0 $?
}

test_export_to_file() {
	_add_rule "cloudflare" "asn" "13335" "wg0" "100"

	local outfile="${_TEST_TMPDIR}/export.json"
	mergen_rule_export_json > "$outfile"

	assertTrue "output file should exist" "[ -f '$outfile' ]"
	grep -q '"name": "cloudflare"' "$outfile"
	assertEquals "file should have rule" 0 $?
}

# ── Import Tests ──────────────────────────────────────────

test_import_single_asn() {
	local jsonfile="${_TEST_TMPDIR}/rules.json"
	cat > "$jsonfile" <<'ENDJSON'
{
  "rules": [
    {
      "name": "cloudflare",
      "asn": 13335,
      "via": "wg0",
      "priority": 100
    }
  ]
}
ENDJSON

	mergen_rule_import_json "$jsonfile"
	assertEquals "import should succeed" 0 $?
	assertEquals "should import 1 rule" 1 "$MERGEN_IMPORT_COUNT"

	mergen_rule_get "cloudflare"
	assertEquals "rule should exist" 0 $?
	assertEquals "type should be asn" "asn" "$MERGEN_RULE_TYPE"
	assertEquals "via should be wg0" "wg0" "$MERGEN_RULE_VIA"
}

test_import_multiple_rules() {
	local jsonfile="${_TEST_TMPDIR}/rules.json"
	cat > "$jsonfile" <<'ENDJSON'
{
  "rules": [
    {
      "name": "cloudflare",
      "asn": 13335,
      "via": "wg0",
      "priority": 100
    },
    {
      "name": "internal",
      "ip": "10.0.0.0/8",
      "via": "lan",
      "priority": 50
    }
  ]
}
ENDJSON

	mergen_rule_import_json "$jsonfile"
	assertEquals "import should succeed" 0 $?
	assertEquals "should import 2 rules" 2 "$MERGEN_IMPORT_COUNT"

	mergen_rule_get "cloudflare"
	assertEquals "first rule should exist" 0 $?
	mergen_rule_get "internal"
	assertEquals "second rule should exist" 0 $?
}

test_import_multi_asn() {
	local jsonfile="${_TEST_TMPDIR}/rules.json"
	cat > "$jsonfile" <<'ENDJSON'
{
  "rules": [
    {
      "name": "google",
      "asn": [15169, 36040],
      "via": "wg0",
      "priority": 200
    }
  ]
}
ENDJSON

	mergen_rule_import_json "$jsonfile"
	assertEquals "import should succeed" 0 $?
	assertEquals "should import 1 rule" 1 "$MERGEN_IMPORT_COUNT"

	mergen_rule_get "google"
	assertEquals "rule should exist" 0 $?
}

test_import_skip_existing() {
	_add_rule "cloudflare" "asn" "13335" "wg0" "100"

	local jsonfile="${_TEST_TMPDIR}/rules.json"
	cat > "$jsonfile" <<'ENDJSON'
{
  "rules": [
    {
      "name": "cloudflare",
      "asn": 13335,
      "via": "wg0",
      "priority": 100
    }
  ]
}
ENDJSON

	mergen_rule_import_json "$jsonfile"
	assertEquals "import should succeed" 0 $?
	assertEquals "should skip 1" 1 "$MERGEN_IMPORT_SKIP"
	assertEquals "should import 0" 0 "$MERGEN_IMPORT_COUNT"
}

test_import_replace_mode() {
	_add_rule "oldrule" "asn" "13335" "wg0" "100"

	local jsonfile="${_TEST_TMPDIR}/rules.json"
	cat > "$jsonfile" <<'ENDJSON'
{
  "rules": [
    {
      "name": "newrule",
      "asn": 15169,
      "via": "wg0",
      "priority": 200
    }
  ]
}
ENDJSON

	mergen_rule_import_json "$jsonfile" "1"
	assertEquals "import should succeed" 0 $?
	assertEquals "should import 1" 1 "$MERGEN_IMPORT_COUNT"

	# Old rule should be gone
	mergen_rule_get "oldrule"
	assertNotEquals "old rule should not exist" 0 $?

	# New rule should exist
	mergen_rule_get "newrule"
	assertEquals "new rule should exist" 0 $?
}

test_import_missing_file() {
	mergen_rule_import_json "/nonexistent/file.json"
	assertNotEquals "should fail for missing file" 0 $?
}

test_import_empty_path() {
	mergen_rule_import_json ""
	assertNotEquals "should fail for empty path" 0 $?
}

test_import_invalid_json() {
	local jsonfile="${_TEST_TMPDIR}/bad.json"
	echo "not json at all" > "$jsonfile"

	mergen_rule_import_json "$jsonfile"
	assertNotEquals "should fail for invalid JSON" 0 $?
}

test_import_missing_name() {
	local jsonfile="${_TEST_TMPDIR}/rules.json"
	cat > "$jsonfile" <<'ENDJSON'
{
  "rules": [
    {
      "asn": 13335,
      "via": "wg0"
    }
  ]
}
ENDJSON

	mergen_rule_import_json "$jsonfile"
	assertEquals "import should succeed (with errors)" 0 $?
	assertEquals "should have 1 error" 1 "$MERGEN_IMPORT_ERROR"
	assertEquals "should import 0" 0 "$MERGEN_IMPORT_COUNT"
}

test_import_with_tags() {
	local jsonfile="${_TEST_TMPDIR}/rules.json"
	cat > "$jsonfile" <<'ENDJSON'
{
  "rules": [
    {
      "name": "webvpn",
      "asn": 13335,
      "via": "wg0",
      "priority": 100,
      "tags": ["vpn", "work"]
    }
  ]
}
ENDJSON

	mergen_rule_import_json "$jsonfile"
	assertEquals "import should succeed" 0 $?

	mergen_rule_has_tag "webvpn" "vpn"
	assertEquals "should have vpn tag" 0 $?
	mergen_rule_has_tag "webvpn" "work"
	assertEquals "should have work tag" 0 $?
}

# ── Round Trip Test ───────────────────────────────────────

test_export_import_roundtrip() {
	_add_rule "cloudflare" "asn" "13335" "wg0" "100"
	_add_rule "internal" "ip" "10.0.0.0/8" "lan" "50"

	# Export
	local jsonfile="${_TEST_TMPDIR}/export.json"
	mergen_rule_export_json > "$jsonfile"

	# Clear rules
	mergen_rule_remove "cloudflare"
	mergen_rule_remove "internal"

	# Verify rules are gone
	mergen_rule_get "cloudflare"
	assertNotEquals "cloudflare should be gone" 0 $?

	# Import
	mergen_rule_import_json "$jsonfile"
	assertEquals "import should succeed" 0 $?
	assertEquals "should import 2 rules" 2 "$MERGEN_IMPORT_COUNT"

	# Verify rules are back
	mergen_rule_get "cloudflare"
	assertEquals "cloudflare should be back" 0 $?
	assertEquals "type should be asn" "asn" "$MERGEN_RULE_TYPE"
	assertEquals "via should be wg0" "wg0" "$MERGEN_RULE_VIA"

	mergen_rule_get "internal"
	assertEquals "internal should be back" 0 $?
	assertEquals "type should be ip" "ip" "$MERGEN_RULE_TYPE"
}

# ── Rules Directory Test ──────────────────────────────────

test_load_rules_dir() {
	local dir="${_TEST_TMPDIR}/rules.d"
	mkdir -p "$dir"

	cat > "$dir/first.json" <<'ENDJSON'
{
  "rules": [
    {
      "name": "rule1",
      "asn": 13335,
      "via": "wg0",
      "priority": 100
    }
  ]
}
ENDJSON

	cat > "$dir/second.json" <<'ENDJSON'
{
  "rules": [
    {
      "name": "rule2",
      "ip": "10.0.0.0/8",
      "via": "lan",
      "priority": 50
    }
  ]
}
ENDJSON

	mergen_load_rules_dir "$dir"

	mergen_rule_get "rule1"
	assertEquals "rule1 should exist" 0 $?
	mergen_rule_get "rule2"
	assertEquals "rule2 should exist" 0 $?
}

test_load_rules_dir_empty() {
	local dir="${_TEST_TMPDIR}/empty_rules.d"
	mkdir -p "$dir"

	mergen_load_rules_dir "$dir"
	assertEquals "should succeed for empty dir" 0 $?
}

test_load_rules_dir_nonexistent() {
	mergen_load_rules_dir "/nonexistent/path"
	assertEquals "should succeed for missing dir (no-op)" 0 $?
}

# ── Load Runner ───────────────────────────────────────────
. "${MERGEN_TEST_DIR}/shunit2"

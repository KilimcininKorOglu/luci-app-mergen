#!/bin/sh
# Test suite for CLI commands in mergen/files/usr/bin/mergen
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
		del_list) return 0 ;;
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

# Mock logger, flock, kill
logger() { :; }
flock() { return 0; }

# Mock ip command
_IP_COMMANDS=""
ip() {
	_IP_COMMANDS="${_IP_COMMANDS}
ip $*"
	case "$1" in
		route)
			case "$2" in
				show)
					# Return mock routing data
					if echo "$*" | grep -q "dev wg0"; then
						echo "default via 10.0.0.1 dev wg0"
					elif echo "$*" | grep -q "dev lan"; then
						echo "default via 192.168.1.1 dev lan"
					elif echo "$*" | grep -q "table"; then
						# Return nothing for table queries by default
						:
					fi
					;;
				*)
					return 0
					;;
			esac
			;;
		rule)
			return 0
			;;
		link)
			# For validate_interface
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

# Source CLI with dispatch guard
MERGEN_SOURCED=1
. "${MERGEN_ROOT}/files/usr/bin/mergen"

# ── Post-source Overrides ──────────────────────────────
# These MUST come after sourcing to override real implementations

# Override mergen_uci_add to avoid subshell variable loss
# The real mergen_uci_add uses $() which creates a subshell,
# causing _MOCK_FOREACH_SECTIONS changes to be lost
mergen_uci_add() {
	local type="$1"
	_MOCK_SECTION_COUNTER=$((_MOCK_SECTION_COUNTER + 1))
	local new_id="cfg$(printf '%03d' $_MOCK_SECTION_COUNTER)"
	MERGEN_UCI_RESULT="$new_id"
	if [ "$type" = "rule" ]; then
		_MOCK_FOREACH_SECTIONS="${_MOCK_FOREACH_SECTIONS} ${new_id}"
	fi
}

# Override lock functions (real ones fail on macOS)
mergen_lock_acquire() { return 0; }
mergen_lock_release() { return 0; }

# ── Mock Provider ───────────────────────────────────────

_create_mock_provider() {
	cat > "${_TEST_TMPDIR}/providers/mock.sh" <<'PROVEOF'
#!/bin/sh
provider_name() { echo "mock-provider"; }
provider_test() { return 0; }
provider_resolve() {
	echo "192.0.2.0/24"
	echo "198.51.100.0/24"
	echo "2001:db8::/32" >&3
	return 0
}
PROVEOF
	chmod +x "${_TEST_TMPDIR}/providers/mock.sh"
}

# ── Setup/Teardown ──────────────────────────────────────

setUp() {
	_MOCK_UCI_STORE=""
	_MOCK_FOREACH_SECTIONS=""
	_MOCK_SECTION_COUNTER=0
	_IP_COMMANDS=""
	MERGEN_UCI_RESULT=""
	MERGEN_RESOLVE_RESULT_V4=""
	MERGEN_RESOLVE_RESULT_V6=""
	MERGEN_RESOLVE_PROVIDER=""
	MERGEN_RESOLVE_COUNT_V4=0
	MERGEN_RESOLVE_COUNT_V6=0
	MERGEN_ROUTE_APPLIED_COUNT=0
	MERGEN_ROUTE_FAILED_COUNT=0

	# Create temp directory structure
	_TEST_TMPDIR="$(mktemp -d)"
	mkdir -p "${_TEST_TMPDIR}/providers"
	mkdir -p "${_TEST_TMPDIR}/cache"

	# Override module globals
	MERGEN_PROVIDERS_DIR="${_TEST_TMPDIR}/providers"
	MERGEN_CACHE_DIR="${_TEST_TMPDIR}/cache"
	MERGEN_TMP="${_TEST_TMPDIR}"

	# Set up default UCI config
	_mock_uci_set "mergen.global.enabled=1"
	_mock_uci_set "mergen.global.log_level=info"
	_mock_uci_set "mergen.global.cache_dir=${_TEST_TMPDIR}/cache"
	_mock_uci_set "mergen.global.update_interval=86400"
	_mock_uci_set "mergen.global.default_table=100"
	_MOCK_CONFIG_LOADED="mergen"
}

tearDown() {
	if [ -n "$_TEST_TMPDIR" ] && [ -d "$_TEST_TMPDIR" ]; then
		rm -rf "$_TEST_TMPDIR"
	fi
}

# ── cmd_add Tests ──────────────────────────────────────

test_add_asn_rule() {
	local output
	output="$(cmd_add --name cloudflare --asn 13335 --via wg0 2>/dev/null)"
	assertEquals "Add ASN rule succeeds" 0 $?
	echo "$output" | grep -q "cloudflare"
	assertEquals "Output mentions rule name" 0 $?
}

test_add_ip_rule() {
	local output
	output="$(cmd_add --name internal --ip 10.0.0.0/8 --via lan 2>/dev/null)"
	assertEquals "Add IP rule succeeds" 0 $?
	echo "$output" | grep -q "internal"
	assertEquals "Output mentions rule name" 0 $?
}

test_add_with_priority() {
	cmd_add --name test-pri --asn 15169 --via wg0 --priority 200 2>/dev/null
	assertEquals "Add with priority succeeds" 0 $?

	mergen_rule_get "test-pri"
	assertEquals "Priority is set" "200" "$MERGEN_RULE_PRIORITY"
}

test_add_multiple_asns() {
	cmd_add --name multi --asn 13335,15169 --via wg0 2>/dev/null
	assertEquals "Add multiple ASNs succeeds" 0 $?
}

test_add_missing_name() {
	cmd_add --asn 13335 --via wg0 2>/dev/null
	assertEquals "Missing name returns 2" 2 $?
}

test_add_missing_type() {
	cmd_add --name test --via wg0 2>/dev/null
	assertEquals "Missing type returns 2" 2 $?
}

test_add_missing_via() {
	cmd_add --name test --asn 13335 2>/dev/null
	assertEquals "Missing via returns 2" 2 $?
}

test_add_mixed_asn_ip() {
	cmd_add --name test --asn 13335 --ip 10.0.0.0/8 --via wg0 2>/dev/null
	assertEquals "Mixed asn/ip returns 2" 2 $?
}

test_add_unknown_option() {
	cmd_add --name test --asn 13335 --via wg0 --bogus 2>/dev/null
	assertEquals "Unknown option returns 2" 2 $?
}

test_add_duplicate_name() {
	cmd_add --name dup-test --asn 13335 --via wg0 2>/dev/null
	cmd_add --name dup-test --asn 15169 --via wg0 2>/dev/null
	assertNotEquals "Duplicate name fails" 0 $?
}

# ── cmd_remove Tests ────────────────────────────────────

test_remove_existing() {
	cmd_add --name to-remove --asn 13335 --via wg0 2>/dev/null
	local output
	output="$(cmd_remove to-remove 2>/dev/null)"
	assertEquals "Remove succeeds" 0 $?
	echo "$output" | grep -q "to-remove"
	assertEquals "Output mentions rule name" 0 $?
}

test_remove_nonexistent() {
	cmd_remove nonexistent 2>/dev/null
	assertNotEquals "Remove nonexistent fails" 0 $?
}

test_remove_no_name() {
	cmd_remove 2>/dev/null
	assertEquals "Remove no name returns 2" 2 $?
}

# ── cmd_list Tests ──────────────────────────────────────

test_list_empty() {
	local output
	output="$(cmd_list 2>/dev/null)"
	echo "$output" | grep -q "kural yok"
	assertEquals "Empty list message" 0 $?
}

test_list_with_rules() {
	cmd_add --name rule-one --asn 13335 --via wg0 2>/dev/null
	cmd_add --name rule-two --ip 10.0.0.0/8 --via lan 2>/dev/null

	local output
	output="$(cmd_list 2>/dev/null)"

	echo "$output" | grep -q "rule-one"
	assertEquals "List shows first rule" 0 $?

	echo "$output" | grep -q "rule-two"
	assertEquals "List shows second rule" 0 $?
}

test_list_table_header() {
	local output
	output="$(cmd_list 2>/dev/null)"
	echo "$output" | grep -q "NAME"
	assertEquals "List has header" 0 $?
}

# ── cmd_show Tests ──────────────────────────────────────

test_show_existing() {
	cmd_add --name show-test --asn 13335 --via wg0 --priority 150 2>/dev/null

	local output
	output="$(cmd_show show-test 2>/dev/null)"
	assertEquals "Show succeeds" 0 $?

	echo "$output" | grep -q "show-test"
	assertEquals "Shows rule name" 0 $?

	echo "$output" | grep -q "asn"
	assertEquals "Shows type" 0 $?

	echo "$output" | grep -q "wg0"
	assertEquals "Shows via" 0 $?

	echo "$output" | grep -q "150"
	assertEquals "Shows priority" 0 $?
}

test_show_nonexistent() {
	cmd_show nonexistent 2>/dev/null
	assertNotEquals "Show nonexistent fails" 0 $?
}

test_show_no_name() {
	cmd_show 2>/dev/null
	assertEquals "Show no name returns 2" 2 $?
}

# ── cmd_enable / cmd_disable Tests ──────────────────────

test_enable_rule() {
	cmd_add --name toggle-test --asn 13335 --via wg0 2>/dev/null
	cmd_disable toggle-test 2>/dev/null
	mergen_rule_get "toggle-test"
	assertEquals "Rule is disabled" "0" "$MERGEN_RULE_ENABLED"

	cmd_enable toggle-test 2>/dev/null
	assertEquals "Enable succeeds" 0 $?
	mergen_rule_get "toggle-test"
	assertEquals "Rule is enabled" "1" "$MERGEN_RULE_ENABLED"
}

test_disable_rule() {
	cmd_add --name dis-test --asn 13335 --via wg0 2>/dev/null
	cmd_disable dis-test 2>/dev/null
	assertEquals "Disable succeeds" 0 $?

	mergen_rule_get "dis-test"
	assertEquals "Rule is disabled" "0" "$MERGEN_RULE_ENABLED"
}

test_enable_no_name() {
	cmd_enable 2>/dev/null
	assertEquals "Enable no name returns 2" 2 $?
}

test_disable_no_name() {
	cmd_disable 2>/dev/null
	assertEquals "Disable no name returns 2" 2 $?
}

test_enable_nonexistent() {
	cmd_enable ghost-rule 2>/dev/null
	assertNotEquals "Enable nonexistent fails" 0 $?
}

# ── cmd_apply Tests ──────────────────────────────────────

test_apply_empty() {
	local output
	output="$(cmd_apply 2>/dev/null)"
	assertEquals "Apply empty succeeds" 0 $?
	echo "$output" | grep -q "0 kural"
	assertEquals "Shows zero rules applied" 0 $?
}

test_apply_with_ip_rule() {
	cmd_add --name apply-ip --ip 10.0.0.0/8 --via wg0 2>/dev/null

	local output
	output="$(cmd_apply 2>/dev/null)"
	assertEquals "Apply succeeds" 0 $?
	echo "$output" | grep -q "1 kural"
	assertEquals "Shows applied count" 0 $?
}

test_apply_skips_disabled() {
	cmd_add --name skip-dis --ip 10.0.0.0/8 --via wg0 2>/dev/null
	cmd_disable skip-dis 2>/dev/null

	local output
	output="$(cmd_apply 2>/dev/null)"
	assertEquals "Apply succeeds" 0 $?
	echo "$output" | grep -q "0 kural"
	assertEquals "Shows zero applied (disabled skipped)" 0 $?
}

test_apply_writes_last_sync() {
	cmd_add --name sync-test --ip 10.0.0.0/8 --via wg0 2>/dev/null
	cmd_apply 2>/dev/null

	assertTrue "Last sync file created" "[ -f '${_TEST_TMPDIR}/last_sync' ]"
}

test_apply_unknown_option() {
	cmd_apply --bogus 2>/dev/null
	assertEquals "Unknown option returns 2" 2 $?
}

test_apply_force_flag() {
	# Should accept --force without error
	cmd_apply --force 2>/dev/null
	assertEquals "Force flag accepted" 0 $?
}

test_apply_safe_flag() {
	# Should accept --safe without error
	local output
	output="$(cmd_apply --safe 2>/dev/null)"
	assertEquals "Safe flag accepted" 0 $?
	echo "$output" | grep -q "Guvenli mod"
	assertEquals "Safe mode message shown" 0 $?
}

# ── cmd_status Tests ────────────────────────────────────

test_status_shows_version() {
	local output
	output="$(cmd_status 2>/dev/null)"
	echo "$output" | grep -q "Mergen v"
	assertEquals "Status shows version" 0 $?
}

test_status_shows_service() {
	local output
	output="$(cmd_status 2>/dev/null)"
	echo "$output" | grep -q "Servis:"
	assertEquals "Status shows service" 0 $?
}

test_status_shows_rules() {
	cmd_add --name stat-test --asn 13335 --via wg0 2>/dev/null

	local output
	output="$(cmd_status 2>/dev/null)"
	echo "$output" | grep -q "Kurallar:"
	assertEquals "Status shows rules" 0 $?
	echo "$output" | grep -q "1 toplam"
	assertEquals "Status shows rule count" 0 $?
}

test_status_no_last_sync() {
	local output
	output="$(cmd_status 2>/dev/null)"
	echo "$output" | grep -q "henuz uygulanmadi"
	assertEquals "Status shows no sync" 0 $?
}

test_status_with_last_sync() {
	date +%s > "${_TEST_TMPDIR}/last_sync"

	local output
	output="$(cmd_status 2>/dev/null)"
	echo "$output" | grep -q "Son uygulama:"
	assertEquals "Status shows last sync" 0 $?
}

# ── cmd_version Tests ───────────────────────────────────

test_version_output() {
	local output
	output="$(cmd_version 2>/dev/null)"
	echo "$output" | grep -q "Mergen v0.1.0"
	assertEquals "Version shows correct version" 0 $?
}

# ── cmd_help Tests ──────────────────────────────────────

test_help_general() {
	local output
	output="$(cmd_help 2>/dev/null)"
	echo "$output" | grep -q "mergen"
	assertEquals "Help shows usage" 0 $?
	echo "$output" | grep -q "add"
	assertEquals "Help mentions add" 0 $?
	echo "$output" | grep -q "remove"
	assertEquals "Help mentions remove" 0 $?
}

test_help_add() {
	local output
	output="$(cmd_help add 2>/dev/null)"
	echo "$output" | grep -q "\-\-name"
	assertEquals "Help add shows --name" 0 $?
	echo "$output" | grep -q "\-\-asn"
	assertEquals "Help add shows --asn" 0 $?
	echo "$output" | grep -q "\-\-via"
	assertEquals "Help add shows --via" 0 $?
}

test_help_apply() {
	local output
	output="$(cmd_help apply 2>/dev/null)"
	echo "$output" | grep -q "\-\-force"
	assertEquals "Help apply shows --force" 0 $?
	echo "$output" | grep -q "\-\-safe"
	assertEquals "Help apply shows --safe" 0 $?
}

test_help_unknown_command() {
	cmd_help boguscommand 2>/dev/null
	assertNotEquals "Help unknown returns 1" 0 $?
}

# ── cmd_validate Tests ──────────────────────────────────

test_validate_empty() {
	local output
	output="$(cmd_validate 2>/dev/null)"
	assertEquals "Validate empty succeeds" 0 $?
	echo "$output" | grep -q "Kayitli kural yok"
	assertEquals "Shows no rules message" 0 $?
}

test_validate_valid_rules() {
	cmd_add --name valid-asn --asn 13335 --via wg0 2>/dev/null
	cmd_add --name valid-ip --ip 10.0.0.0/8 --via lan 2>/dev/null

	local output
	output="$(cmd_validate 2>/dev/null)"
	assertEquals "Validate valid config succeeds" 0 $?
	echo "$output" | grep -q "2 kural"
	assertEquals "Shows validated count" 0 $?
}

test_validate_invalid_rule() {
	# Manually create a rule with invalid data
	_MOCK_SECTION_COUNTER=$((_MOCK_SECTION_COUNTER + 1))
	local sid="cfg$(printf '%03d' $_MOCK_SECTION_COUNTER)"
	_MOCK_FOREACH_SECTIONS="${_MOCK_FOREACH_SECTIONS} ${sid}"
	_mock_uci_set "mergen.${sid}.name=bad-rule"
	_mock_uci_set "mergen.${sid}.via=wg0"
	_mock_uci_set "mergen.${sid}.priority=100"
	_mock_uci_set "mergen.${sid}.enabled=1"
	# No asn or ip — type is undefined

	cmd_validate 2>/dev/null
	assertNotEquals "Validate invalid config fails" 0 $?
}

test_validate_unknown_option() {
	cmd_validate --bogus 2>/dev/null
	assertEquals "Unknown option returns 2" 2 $?
}

test_help_validate() {
	local output
	output="$(cmd_help validate 2>/dev/null)"
	echo "$output" | grep -q "\-\-check-providers"
	assertEquals "Help validate shows --check-providers" 0 $?
}

# ── Integration: add -> list -> show -> remove ──────────

test_full_lifecycle() {
	# Add
	cmd_add --name lifecycle --asn 13335 --via wg0 --priority 150 2>/dev/null
	assertEquals "Add succeeds" 0 $?

	# List
	local list_output
	list_output="$(cmd_list 2>/dev/null)"
	echo "$list_output" | grep -q "lifecycle"
	assertEquals "List shows rule" 0 $?

	# Show
	local show_output
	show_output="$(cmd_show lifecycle 2>/dev/null)"
	echo "$show_output" | grep -q "150"
	assertEquals "Show displays priority" 0 $?

	# Disable
	cmd_disable lifecycle 2>/dev/null
	assertEquals "Disable succeeds" 0 $?
	mergen_rule_get "lifecycle"
	assertEquals "Rule disabled" "0" "$MERGEN_RULE_ENABLED"

	# Enable
	cmd_enable lifecycle 2>/dev/null
	assertEquals "Enable succeeds" 0 $?
	mergen_rule_get "lifecycle"
	assertEquals "Rule enabled" "1" "$MERGEN_RULE_ENABLED"

	# Remove
	cmd_remove lifecycle 2>/dev/null
	assertEquals "Remove succeeds" 0 $?

	# Verify removed
	local list_after
	list_after="$(cmd_list 2>/dev/null)"
	echo "$list_after" | grep -q "lifecycle"
	assertNotEquals "Rule no longer in list" 0 $?
}

# ── cmd_flush Tests ────────────────────────────────────

test_flush_requires_confirm() {
	cmd_flush 2>/dev/null
	assertEquals "Flush without --confirm returns 1" 1 $?
}

test_flush_with_confirm() {
	cmd_add --name flush-test --ip 10.0.0.0/8 --via wg0 2>/dev/null
	local output
	output="$(cmd_flush --confirm 2>/dev/null)"
	assertEquals "Flush with --confirm succeeds" 0 $?
	echo "$output" | grep -q "temizlendi"
	assertEquals "Flush output confirms cleanup" 0 $?
}

test_flush_unknown_option() {
	cmd_flush --bogus 2>/dev/null
	assertEquals "Flush unknown option returns 2" 2 $?
}

test_flush_warning_without_confirm() {
	local stderr_output
	stderr_output="$(cmd_flush 2>&1 >/dev/null)"
	echo "$stderr_output" | grep -q "\-\-confirm"
	assertEquals "Flush shows --confirm hint" 0 $?
}

# ── cmd_diag Tests ─────────────────────────────────────

test_diag_shows_version() {
	local output
	output="$(cmd_diag 2>/dev/null)"
	echo "$output" | grep -q "Mergen v"
	assertEquals "Diag shows version" 0 $?
}

test_diag_shows_engine() {
	local output
	output="$(cmd_diag 2>/dev/null)"
	echo "$output" | grep -q "Paket Motoru"
	assertEquals "Diag shows engine section" 0 $?
}

test_diag_shows_ip_rules() {
	local output
	output="$(cmd_diag 2>/dev/null)"
	echo "$output" | grep -q "IP Kurallari"
	assertEquals "Diag shows IP rules section" 0 $?
}

test_diag_shows_routing_tables() {
	local output
	output="$(cmd_diag 2>/dev/null)"
	echo "$output" | grep -q "Routing Tablolari"
	assertEquals "Diag shows routing tables section" 0 $?
}

test_diag_shows_interfaces() {
	local output
	output="$(cmd_diag 2>/dev/null)"
	echo "$output" | grep -q "Arayuzler"
	assertEquals "Diag shows interfaces section" 0 $?
}

test_diag_unknown_option() {
	cmd_diag --bogus 2>/dev/null
	assertEquals "Diag unknown option returns 2" 2 $?
}

test_diag_asn_missing_value() {
	cmd_diag --asn 2>/dev/null
	assertEquals "Diag --asn without value returns 2" 2 $?
}

# ── cmd_log Tests ──────────────────────────────────────

test_log_no_entries() {
	local output
	output="$(cmd_log 2>/dev/null)"
	echo "$output" | grep -q "bulunamadi"
	assertEquals "Log shows no entries message" 0 $?
}

test_log_with_tail() {
	# Should not error even without entries
	cmd_log --tail 10 2>/dev/null
	assertEquals "Log --tail succeeds" 0 $?
}

test_log_with_level() {
	cmd_log --level error 2>/dev/null
	assertEquals "Log --level succeeds" 0 $?
}

test_log_with_component() {
	cmd_log --component Route 2>/dev/null
	assertEquals "Log --component succeeds" 0 $?
}

test_log_combined_options() {
	cmd_log --tail 20 --level error --component CLI 2>/dev/null
	assertEquals "Log combined options succeeds" 0 $?
}

test_log_unknown_option() {
	cmd_log --bogus 2>/dev/null
	assertEquals "Log unknown option returns 2" 2 $?
}

test_log_missing_tail_value() {
	cmd_log --tail 2>/dev/null
	assertEquals "Log --tail without value returns 2" 2 $?
}

test_log_missing_level_value() {
	cmd_log --level 2>/dev/null
	assertEquals "Log --level without value returns 2" 2 $?
}

# ── cmd_show Extended Tests ────────────────────────────

test_show_asn_prefix_info() {
	cmd_add --name cache-show --asn 13335 --via wg0 2>/dev/null

	# Create mock cache
	mkdir -p "${_TEST_TMPDIR}/cache"
	printf "192.0.2.0/24\n198.51.100.0/24\n" > "${_TEST_TMPDIR}/cache/AS13335.v4.txt"
	printf "timestamp=1234567890\nprovider=ripe\n" > "${_TEST_TMPDIR}/cache/AS13335.meta"

	local output
	output="$(cmd_show cache-show 2>/dev/null)"
	echo "$output" | grep -q "Provider:"
	assertEquals "Show displays provider" 0 $?
	echo "$output" | grep -q "ripe"
	assertEquals "Show displays provider name" 0 $?
	echo "$output" | grep -q "Prefix:"
	assertEquals "Show displays prefix count" 0 $?
	echo "$output" | grep -q "2 adet"
	assertEquals "Show displays correct prefix count" 0 $?
}

test_show_asn_no_cache() {
	cmd_add --name nocache --asn 99999 --via wg0 2>/dev/null

	local output
	output="$(cmd_show nocache 2>/dev/null)"
	echo "$output" | grep -q "onbellekte yok"
	assertEquals "Show displays no cache message" 0 $?
}

test_show_ip_no_prefix_section() {
	cmd_add --name ip-show --ip 10.0.0.0/8 --via wg0 2>/dev/null

	local output
	output="$(cmd_show ip-show 2>/dev/null)"
	echo "$output" | grep -q "Prefix:"
	assertNotEquals "IP show does not have Prefix section" 0 $?
}

# ── Help Tests for New Commands ────────────────────────

test_help_flush() {
	local output
	output="$(cmd_help flush 2>/dev/null)"
	echo "$output" | grep -q "\-\-confirm"
	assertEquals "Help flush shows --confirm" 0 $?
}

test_help_diag() {
	local output
	output="$(cmd_help diag 2>/dev/null)"
	echo "$output" | grep -q "\-\-asn"
	assertEquals "Help diag shows --asn" 0 $?
}

test_help_log() {
	local output
	output="$(cmd_help log 2>/dev/null)"
	echo "$output" | grep -q "\-\-tail"
	assertEquals "Help log shows --tail" 0 $?
	echo "$output" | grep -q "\-\-level"
	assertEquals "Help log shows --level" 0 $?
	echo "$output" | grep -q "\-\-component"
	assertEquals "Help log shows --component" 0 $?
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

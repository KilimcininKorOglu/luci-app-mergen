#!/bin/sh
# Test suite for mergen/files/usr/lib/mergen/utils.sh
# Uses shunit2 framework — ash/busybox compatible

# Setup: source utils.sh with mocked core.sh
MERGEN_TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
MERGEN_ROOT="$(cd "$MERGEN_TEST_DIR/.." && pwd)"

# Mock core.sh dependencies before sourcing utils.sh
MERGEN_CONF="mergen"
MERGEN_UCI_RESULT=""

mergen_log() { :; }  # no-op for tests

mergen_uci_get() {
	MERGEN_UCI_RESULT="$3"
}

# Source the module under test
. "${MERGEN_ROOT}/files/usr/lib/mergen/utils.sh"

# ── ASN Validation Tests ─────────────────────────────────

test_validate_asn_valid() {
	validate_asn "13335"
	assertEquals "Valid ASN 13335" 0 $?

	validate_asn "1"
	assertEquals "Valid ASN 1" 0 $?

	validate_asn "4294967295"
	assertEquals "Valid ASN max (4294967295)" 0 $?

	validate_asn "AS13335"
	assertEquals "Valid ASN with AS prefix" 0 $?

	validate_asn "as15169"
	assertEquals "Valid ASN with lowercase as prefix" 0 $?
}

test_validate_asn_invalid() {
	validate_asn "abc"
	assertNotEquals "Non-numeric ASN" 0 $?
	assertContains "Error message mentions example" "$MERGEN_VALIDATE_ERR" "13335"

	validate_asn ""
	assertNotEquals "Empty ASN" 0 $?

	validate_asn "0"
	assertNotEquals "Zero ASN" 0 $?

	validate_asn "-1"
	assertNotEquals "Negative ASN" 0 $?

	validate_asn "99999999999"
	assertNotEquals "ASN over max" 0 $?

	validate_asn "4294967296"
	assertNotEquals "ASN exactly over max" 0 $?
}

test_validate_asn_injection() {
	validate_asn "13335; rm -rf /"
	assertNotEquals "Shell injection in ASN" 0 $?

	validate_asn '13335$(whoami)'
	assertNotEquals "Command substitution in ASN" 0 $?

	validate_asn "13335|cat /etc/passwd"
	assertNotEquals "Pipe injection in ASN" 0 $?
}

# ── IP/CIDR Validation Tests ─────────────────────────────

test_validate_ip_cidr_valid_ipv4() {
	validate_ip_cidr "10.0.0.0/8"
	assertEquals "Valid IPv4 CIDR /8" 0 $?

	validate_ip_cidr "192.168.1.0/24"
	assertEquals "Valid IPv4 CIDR /24" 0 $?

	validate_ip_cidr "0.0.0.0/0"
	assertEquals "Valid IPv4 default route" 0 $?

	validate_ip_cidr "255.255.255.255/32"
	assertEquals "Valid IPv4 host route" 0 $?

	validate_ip_cidr "1.2.3.4"
	assertEquals "Valid IPv4 without prefix" 0 $?
}

test_validate_ip_cidr_invalid_ipv4() {
	validate_ip_cidr "10.0.0.0/33"
	assertNotEquals "IPv4 prefix > 32" 0 $?

	validate_ip_cidr "256.0.0.0/8"
	assertNotEquals "IPv4 octet > 255" 0 $?

	validate_ip_cidr "abc/8"
	assertNotEquals "Non-numeric IPv4" 0 $?

	validate_ip_cidr ""
	assertNotEquals "Empty IP" 0 $?

	validate_ip_cidr "10.0.0/8"
	assertNotEquals "IPv4 missing octet" 0 $?

	validate_ip_cidr "10.0.0.0.0/8"
	assertNotEquals "IPv4 extra octet" 0 $?
}

test_validate_ip_cidr_valid_ipv6() {
	validate_ip_cidr "2001:db8::/32"
	assertEquals "Valid IPv6 CIDR" 0 $?

	validate_ip_cidr "::1/128"
	assertEquals "Valid IPv6 loopback" 0 $?

	validate_ip_cidr "::/0"
	assertEquals "Valid IPv6 default route" 0 $?

	validate_ip_cidr "fe80::1"
	assertEquals "Valid IPv6 link-local without prefix" 0 $?
}

test_validate_ip_cidr_invalid_ipv6() {
	validate_ip_cidr "2001:db8::/129"
	assertNotEquals "IPv6 prefix > 128" 0 $?

	validate_ip_cidr "2001:gggg::1/64"
	assertNotEquals "Invalid hex in IPv6" 0 $?
}

test_validate_ip_cidr_injection() {
	validate_ip_cidr "10.0.0.0/8; rm -rf /"
	assertNotEquals "Shell injection in CIDR" 0 $?
}

# ── Rule Name Validation Tests ───────────────────────────

test_validate_name_valid() {
	validate_name "cloudflare"
	assertEquals "Simple name" 0 $?

	validate_name "my-rule"
	assertEquals "Name with hyphen" 0 $?

	validate_name "rule_01"
	assertEquals "Name with underscore and digit" 0 $?

	validate_name "A"
	assertEquals "Single char name" 0 $?
}

test_validate_name_invalid() {
	validate_name ""
	assertNotEquals "Empty name" 0 $?

	validate_name "rule name"
	assertNotEquals "Name with space" 0 $?

	validate_name "rule@name"
	assertNotEquals "Name with special char" 0 $?

	validate_name "abcdefghijklmnopqrstuvwxyz1234567"
	assertNotEquals "Name > 32 chars" 0 $?
}

test_validate_name_injection() {
	validate_name "test;ls"
	assertNotEquals "Semicolon injection in name" 0 $?

	validate_name 'test$(id)'
	assertNotEquals "Command substitution in name" 0 $?
}

# ── Priority Validation Tests ────────────────────────────

test_validate_priority_valid() {
	validate_priority "1"
	assertEquals "Min priority" 0 $?

	validate_priority "100"
	assertEquals "Default priority" 0 $?

	validate_priority "32000"
	assertEquals "Max priority" 0 $?
}

test_validate_priority_invalid() {
	validate_priority ""
	assertNotEquals "Empty priority" 0 $?

	validate_priority "0"
	assertNotEquals "Zero priority" 0 $?

	validate_priority "32001"
	assertNotEquals "Over max priority" 0 $?

	validate_priority "abc"
	assertNotEquals "Non-numeric priority" 0 $?

	validate_priority "-1"
	assertNotEquals "Negative priority" 0 $?
}

# ── Sanitize Input Tests ─────────────────────────────────

test_sanitize_safe_inputs() {
	mergen_sanitize_input "hello"
	assertEquals "Plain text" 0 $?

	mergen_sanitize_input "my-rule_01"
	assertEquals "Alphanumeric with special" 0 $?

	mergen_sanitize_input "10.0.0.0/8"
	assertEquals "IP CIDR" 0 $?

	mergen_sanitize_input "2001:db8::1"
	assertEquals "IPv6 address" 0 $?
}

test_sanitize_dangerous_inputs() {
	mergen_sanitize_input "test;ls"
	assertNotEquals "Semicolon" 0 $?

	mergen_sanitize_input "test|cat"
	assertNotEquals "Pipe" 0 $?

	mergen_sanitize_input "test&bg"
	assertNotEquals "Ampersand" 0 $?

	mergen_sanitize_input 'test`id`'
	assertNotEquals "Backtick" 0 $?

	mergen_sanitize_input 'test$(id)'
	assertNotEquals "Dollar paren" 0 $?

	mergen_sanitize_input "test>file"
	assertNotEquals "Redirect" 0 $?

	mergen_sanitize_input "test'quoted"
	assertNotEquals "Single quote" 0 $?
}

# ── Load shunit2 ─────────────────────────────────────────

# Find shunit2 — check local vendored copy first, then system
if [ -f "${MERGEN_TEST_DIR}/shunit2" ]; then
	. "${MERGEN_TEST_DIR}/shunit2"
elif [ -f /usr/share/shunit2/shunit2 ]; then
	. /usr/share/shunit2/shunit2
else
	echo "ERROR: shunit2 not found. Install it or place it in tests/"
	exit 1
fi

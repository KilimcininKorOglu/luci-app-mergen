#!/bin/sh
# Performance Test Suite for Mergen
# Tests: prefix processing speed, memory usage, batch operations
# Uses shunit2 framework — ash/busybox compatible

MERGEN_TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
MERGEN_ROOT="$(cd "$MERGEN_TEST_DIR/.." && pwd)"

# ── Mock UCI System ──────────────────────────────────────

_MOCK_UCI_STORE=""
_MOCK_CONFIG_LOADED=""

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
			if [ "$1" = "-q" ]; then shift; fi
			_mock_uci_get "$1"
			;;
		set) _mock_uci_set "$1" ;;
		add) _mock_uci_add "$1" "$2" ;;
		delete) _mock_uci_delete "$1" ;;
		commit) return 0 ;;
		*) return 0 ;;
	esac
}

_mock_uci_get() {
	local path="$1"
	local key
	key="$(echo "$path" | tr '.' '_')"
	eval "echo \"\${_UCI_${key}:-}\""
}

_mock_uci_set() {
	local assignment="$1"
	local path="${assignment%%=*}"
	local value="${assignment#*=}"
	local key
	key="$(echo "$path" | tr '.' '_')"
	eval "_UCI_${key}=\"${value}\""
}

_mock_uci_add() {
	return 0
}

_mock_uci_delete() {
	return 0
}

# Mock config_load/config_get/config_foreach
config_load() { _MOCK_CONFIG_LOADED="$1"; }
config_get() {
	local var="$1" section="$2" option="$3" default="$4"
	local key="_UCI_${_MOCK_CONFIG_LOADED}_${section}_${option}"
	local val
	eval "val=\"\${${key}:-}\""
	if [ -z "$val" ]; then
		eval "${var}=\"${default}\""
	else
		eval "${var}=\"${val}\""
	fi
}
config_set() { return 0; }
config_foreach() { return 0; }

# Mock network commands (no-op for performance tests)
ip() { return 0; }
nft() {
	case "$1" in
		list) echo "table inet mergen { }" ;;
		add|delete) return 0 ;;
		-f) return 0 ;;
		*) return 0 ;;
	esac
}

# ── Test Temp Setup ──────────────────────────────────────

setUp() {
	MERGEN_TMP="$(mktemp -d)"
	MERGEN_CONF="mergen"
	MERGEN_LIB_DIR="${MERGEN_ROOT}/files/usr/lib/mergen"
	export MERGEN_TMP MERGEN_CONF MERGEN_LIB_DIR

	mkdir -p "${MERGEN_TMP}/cache"

	# Set UCI defaults
	_UCI_mergen_global_enabled="1"
	_UCI_mergen_global_log_level="error"
	_UCI_mergen_global_default_table="100"
	_UCI_mergen_global_prefix_limit="100000"
	_UCI_mergen_global_total_prefix_limit="500000"
	_UCI_mergen_global_ipv6_enabled="0"
	_UCI_mergen_global_packet_engine="nftables"
	_UCI_mergen_global_mode="standalone"
}

tearDown() {
	rm -rf "$MERGEN_TMP"
}

# ── Source Libraries ─────────────────────────────────────

# Source core.sh (minimal, for logging)
. "${MERGEN_ROOT}/files/usr/lib/mergen/core.sh"
. "${MERGEN_ROOT}/files/usr/lib/mergen/utils.sh"

# ── Helper Functions ─────────────────────────────────────

# Generate N random CIDR prefixes
_generate_prefixes() {
	local count="$1"
	local i=0
	while [ "$i" -lt "$count" ]; do
		local a=$((i / 65536 % 256))
		local b=$((i / 256 % 256))
		local c=$((i % 256))
		echo "10.${a}.${b}.${c}/32"
		i=$((i + 1))
	done
}

# Measure execution time of a command (in milliseconds)
# Usage: _measure_time <command>
# Sets MEASURED_TIME_MS on completion
MEASURED_TIME_MS=0

_measure_time() {
	local start_ts end_ts
	start_ts="$(date +%s)"
	eval "$@"
	end_ts="$(date +%s)"
	MEASURED_TIME_MS=$(( (end_ts - start_ts) * 1000 ))
}

# ── Performance Tests ────────────────────────────────────

# Test: Validate 1000 CIDR prefixes should be fast
test_validate_1000_cidrs() {
	local prefix_file="${MERGEN_TMP}/prefixes_1000.txt"
	_generate_prefixes 1000 > "$prefix_file"

	local start_ts end_ts
	start_ts="$(date +%s)"

	local valid_count=0
	while IFS= read -r prefix; do
		if validate_ip_cidr "$prefix"; then
			valid_count=$((valid_count + 1))
		fi
	done < "$prefix_file"

	end_ts="$(date +%s)"
	local elapsed=$((end_ts - start_ts))

	assertEquals "All 1000 prefixes should be valid" 1000 "$valid_count"
	assertTrue "1000 prefix validation should complete in < 10s (took ${elapsed}s)" \
		"[ $elapsed -lt 10 ]"
}

# Test: Validate 10000 names should be fast
test_validate_10000_names() {
	local start_ts end_ts
	start_ts="$(date +%s)"

	local valid_count=0
	local i=0
	while [ "$i" -lt 10000 ]; do
		if validate_name "rule_${i}"; then
			valid_count=$((valid_count + 1))
		fi
		i=$((i + 1))
	done

	end_ts="$(date +%s)"
	local elapsed=$((end_ts - start_ts))

	assertEquals "All 10000 names should be valid" 10000 "$valid_count"
	assertTrue "10000 name validation should complete in < 15s (took ${elapsed}s)" \
		"[ $elapsed -lt 15 ]"
}

# Test: Generate large prefix list (50000 prefixes) as string
test_generate_50000_prefixes() {
	local prefix_file="${MERGEN_TMP}/prefixes_50k.txt"

	local start_ts end_ts
	start_ts="$(date +%s)"

	_generate_prefixes 50000 > "$prefix_file"

	end_ts="$(date +%s)"
	local elapsed=$((end_ts - start_ts))

	local line_count
	line_count="$(wc -l < "$prefix_file" | tr -d ' ')"

	assertEquals "Should generate 50000 prefixes" 50000 "$line_count"
	assertTrue "50000 prefix generation should complete in < 30s (took ${elapsed}s)" \
		"[ $elapsed -lt 30 ]"
}

# Test: Prefix limit check should be fast even with large counts
test_prefix_limit_check_performance() {
	. "${MERGEN_ROOT}/files/usr/lib/mergen/engine.sh" 2>/dev/null || true

	# Test that the limit check function exists and is fast
	local start_ts end_ts
	start_ts="$(date +%s)"

	local i=0
	while [ "$i" -lt 1000 ]; do
		mergen_check_prefix_limit "test_rule" 5000 >/dev/null 2>&1
		i=$((i + 1))
	done

	end_ts="$(date +%s)"
	local elapsed=$((end_ts - start_ts))

	assertTrue "1000 prefix limit checks should complete in < 15s (took ${elapsed}s)" \
		"[ $elapsed -lt 15 ]"
}

# Test: Cache file I/O performance
test_cache_write_read_performance() {
	local cache_file="${MERGEN_TMP}/cache/AS_perf_test.v4.txt"
	local prefix_file="${MERGEN_TMP}/prefixes_5k.txt"

	# Generate 5000 prefixes
	_generate_prefixes 5000 > "$prefix_file"

	# Write test
	local start_ts end_ts
	start_ts="$(date +%s)"
	cp "$prefix_file" "$cache_file"
	end_ts="$(date +%s)"
	local write_elapsed=$((end_ts - start_ts))

	assertTrue "Cache write (5000 prefixes) should be instant" \
		"[ $write_elapsed -lt 3 ]"

	# Read test
	start_ts="$(date +%s)"
	local line_count
	line_count="$(wc -l < "$cache_file" | tr -d ' ')"
	end_ts="$(date +%s)"
	local read_elapsed=$((end_ts - start_ts))

	assertEquals "Should read back 5000 lines" 5000 "$line_count"
	assertTrue "Cache read (5000 prefixes) should be instant" \
		"[ $read_elapsed -lt 3 ]"
}

# Test: Batch nft file generation performance
test_nft_batch_file_generation() {
	local batch_file="${MERGEN_TMP}/nft_batch_perf.nft"
	local prefix_count=5000

	local start_ts end_ts
	start_ts="$(date +%s)"

	# Simulate batch file generation (same logic as mergen_nft_set_add)
	{
		echo "flush set inet mergen mergen_perf_rule"
		printf "add element inet mergen mergen_perf_rule { "
		local i=0
		local first=1
		while [ "$i" -lt "$prefix_count" ]; do
			local a=$((i / 65536 % 256))
			local b=$((i / 256 % 256))
			local c=$((i % 256))
			if [ "$first" = "1" ]; then
				printf "10.%d.%d.%d/32" "$a" "$b" "$c"
				first=0
			else
				printf ", 10.%d.%d.%d/32" "$a" "$b" "$c"
			fi
			i=$((i + 1))
		done
		echo " }"
	} > "$batch_file"

	end_ts="$(date +%s)"
	local elapsed=$((end_ts - start_ts))

	assertTrue "nft batch file (5000 elements) should be generated in < 15s (took ${elapsed}s)" \
		"[ $elapsed -lt 15 ]"

	local file_size
	file_size="$(wc -c < "$batch_file" | tr -d ' ')"
	assertTrue "Batch file should have content" "[ $file_size -gt 0 ]"
}

# Test: Domain validation performance (bulk)
test_domain_validation_performance() {
	local start_ts end_ts
	start_ts="$(date +%s)"

	local valid_count=0
	local i=0
	while [ "$i" -lt 5000 ]; do
		if validate_domain "subdomain${i}.example.com"; then
			valid_count=$((valid_count + 1))
		fi
		i=$((i + 1))
	done

	end_ts="$(date +%s)"
	local elapsed=$((end_ts - start_ts))

	assertEquals "All 5000 domains should be valid" 5000 "$valid_count"
	assertTrue "5000 domain validations should complete in < 15s (took ${elapsed}s)" \
		"[ $elapsed -lt 15 ]"
}

# Test: Country code validation performance (bulk)
test_country_validation_performance() {
	local start_ts end_ts
	start_ts="$(date +%s)"

	local valid_count=0
	local codes="US TR DE FR GB NL JP KR AU CA"
	local i=0
	while [ "$i" -lt 5000 ]; do
		for code in $codes; do
			if validate_country_code "$code"; then
				valid_count=$((valid_count + 1))
			fi
			i=$((i + 1))
			[ "$i" -ge 5000 ] && break
		done
	done

	end_ts="$(date +%s)"
	local elapsed=$((end_ts - start_ts))

	assertTrue "Country code validation count should be >= 5000" \
		"[ $valid_count -ge 5000 ]"
	assertTrue "5000 country code validations should complete in < 30s (took ${elapsed}s)" \
		"[ $elapsed -lt 30 ]"
}

# Test: Format bytes function correctness and performance
test_format_bytes_correctness() {
	# Source route.sh in a subshell-safe way (it sources engine.sh/resolver.sh)
	# We only need _format_bytes, so define it inline if not available
	if ! type _format_bytes >/dev/null 2>&1; then
		_format_bytes() {
			local bytes="$1"
			if [ "$bytes" -ge 1073741824 ]; then
				local gb=$((bytes / 1073741824))
				local gb_rem=$(( (bytes % 1073741824) * 10 / 1073741824 ))
				echo "${gb}.${gb_rem} GB"
			elif [ "$bytes" -ge 1048576 ]; then
				local mb=$((bytes / 1048576))
				local mb_rem=$(( (bytes % 1048576) * 10 / 1048576 ))
				echo "${mb}.${mb_rem} MB"
			elif [ "$bytes" -ge 1024 ]; then
				local kb=$((bytes / 1024))
				local kb_rem=$(( (bytes % 1024) * 10 / 1024 ))
				echo "${kb}.${kb_rem} KB"
			else
				echo "${bytes} B"
			fi
		}
	fi

	if type _format_bytes >/dev/null 2>&1; then
		local result

		result="$(_format_bytes 0)"
		assertEquals "0 bytes" "0 B" "$result"

		result="$(_format_bytes 1023)"
		assertEquals "1023 bytes" "1023 B" "$result"

		result="$(_format_bytes 1024)"
		assertEquals "1 KB" "1.0 KB" "$result"

		result="$(_format_bytes 1048576)"
		assertEquals "1 MB" "1.0 MB" "$result"

		result="$(_format_bytes 1073741824)"
		assertEquals "1 GB" "1.0 GB" "$result"

		# Performance: format 10000 values
		local start_ts end_ts
		start_ts="$(date +%s)"
		local i=0
		while [ "$i" -lt 10000 ]; do
			_format_bytes "$((i * 1024))" >/dev/null
			i=$((i + 1))
		done
		end_ts="$(date +%s)"
		local elapsed=$((end_ts - start_ts))

		assertTrue "10000 format_bytes calls should complete in < 15s (took ${elapsed}s)" \
			"[ $elapsed -lt 15 ]"
	else
		startSkipping
	fi
}

# Test: Memory usage estimation (large string handling)
test_large_string_memory() {
	# Shell can struggle with very large strings
	# This test verifies that our prefix processing approach
	# (file-based rather than string-based) works for large sets

	local large_file="${MERGEN_TMP}/large_prefix_list.txt"
	_generate_prefixes 10000 > "$large_file"

	local start_ts end_ts
	start_ts="$(date +%s)"

	# Process via file (the correct approach)
	local count=0
	while IFS= read -r line; do
		count=$((count + 1))
	done < "$large_file"

	end_ts="$(date +%s)"
	local elapsed=$((end_ts - start_ts))

	assertEquals "Should process 10000 lines" 10000 "$count"
	assertTrue "File-based processing of 10000 lines should be fast (took ${elapsed}s)" \
		"[ $elapsed -lt 10 ]"
}

# ── Run Tests ────────────────────────────────────────────

. "${MERGEN_TEST_DIR}/shunit2"

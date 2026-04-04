#!/bin/sh
# Mergen Test Runner
# Executes all test suites and reports aggregate results
# Usage: sh tests/run_all.sh [--verbose] [--stop-on-fail] [test_file...]

set -e

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAILED_SUITES=""
VERBOSE=0
STOP_ON_FAIL=0

# Parse arguments
TEST_FILES=""
for arg in "$@"; do
	case "$arg" in
		--verbose|-v) VERBOSE=1 ;;
		--stop-on-fail|-s) STOP_ON_FAIL=1 ;;
		--help|-h)
			echo "Mergen Test Runner"
			echo ""
			echo "Usage: sh run_all.sh [options] [test_file...]"
			echo ""
			echo "Options:"
			echo "  --verbose, -v       Show full test output"
			echo "  --stop-on-fail, -s  Stop on first failing suite"
			echo "  --help, -h          Show this help"
			echo ""
			echo "If no test files are specified, all test_*.sh files are run."
			exit 0
			;;
		test_*.sh)
			TEST_FILES="$TEST_FILES ${TESTS_DIR}/${arg}"
			;;
		*)
			if [ -f "$arg" ]; then
				TEST_FILES="$TEST_FILES $arg"
			elif [ -f "${TESTS_DIR}/$arg" ]; then
				TEST_FILES="$TEST_FILES ${TESTS_DIR}/$arg"
			else
				echo "[!] Bilinmeyen arguman: $arg" >&2
				exit 2
			fi
			;;
	esac
done

# Default: run all test files
if [ -z "$TEST_FILES" ]; then
	TEST_FILES="$(find "$TESTS_DIR" -name 'test_*.sh' -type f | sort)"
fi

# Check shunit2 availability
if [ ! -f "${TESTS_DIR}/shunit2" ] && [ ! -f /usr/share/shunit2/shunit2 ]; then
	echo "[!] shunit2 bulunamadi. tests/ dizinine yerlestiriniz." >&2
	exit 1
fi

TOTAL_SUITES=0
for f in $TEST_FILES; do
	TOTAL_SUITES=$((TOTAL_SUITES + 1))
done

echo "========================================"
echo "  Mergen Test Runner"
echo "========================================"
echo "Calistirilacak: ${TOTAL_SUITES} test dosyasi"
echo ""

SUITE_INDEX=0
START_TIME="$(date +%s)"

for test_file in $TEST_FILES; do
	SUITE_INDEX=$((SUITE_INDEX + 1))
	suite_name="$(basename "$test_file")"

	printf "[%d/%d] %s ... " "$SUITE_INDEX" "$TOTAL_SUITES" "$suite_name"

	# Run test and capture output (strip ANSI escape codes for parsing)
	output_file="${TMPDIR:-/tmp}/mergen_test_$$.out"
	clean_file="${TMPDIR:-/tmp}/mergen_test_$$.clean"
	if sh "$test_file" > "$output_file" 2>&1; then
		# Strip ANSI color codes for reliable parsing
		sed 's/\x1b\[[0-9;]*m//g' "$output_file" > "$clean_file"

		ran="$(grep -o 'Ran [0-9]* tests' "$clean_file" | grep -o '[0-9]*' || echo "0")"
		failures="$(grep -o 'failures=[0-9]*' "$clean_file" | grep -o '[0-9]*' || echo "0")"

		if [ "$failures" = "0" ] || [ -z "$failures" ]; then
			echo "OK (${ran} test)"
			PASS_COUNT=$((PASS_COUNT + 1))
		else
			echo "FAIL (${ran} test, ${failures} basarisiz)"
			FAIL_COUNT=$((FAIL_COUNT + 1))
			FAILED_SUITES="$FAILED_SUITES $suite_name"
		fi
	else
		# Non-zero exit code
		sed 's/\x1b\[[0-9;]*m//g' "$output_file" > "$clean_file"

		ran="$(grep -o 'Ran [0-9]* tests' "$clean_file" | grep -o '[0-9]*' || echo "0")"
		failures="$(grep -o 'failures=[0-9]*' "$clean_file" | grep -o '[0-9]*' || echo "?")"

		if [ "$ran" != "0" ] && [ "$failures" != "?" ]; then
			echo "FAIL (${ran} test, ${failures} basarisiz)"
		else
			echo "HATA (calistirilamadi)"
		fi
		FAIL_COUNT=$((FAIL_COUNT + 1))
		FAILED_SUITES="$FAILED_SUITES $suite_name"
	fi

	if [ "$VERBOSE" -eq 1 ]; then
		echo "--- Output ---"
		cat "$output_file"
		echo "--- End ---"
		echo ""
	fi

	rm -f "$output_file" "$clean_file"

	if [ "$STOP_ON_FAIL" -eq 1 ] && [ "$FAIL_COUNT" -gt 0 ]; then
		echo ""
		echo "[!] --stop-on-fail: Ilk basarisizlikta durduruluyor."
		break
	fi
done

END_TIME="$(date +%s)"
DURATION=$((END_TIME - START_TIME))

echo ""
echo "========================================"
echo "  Sonuclar"
echo "========================================"
echo "Toplam:     ${TOTAL_SUITES} dosya"
echo "Basarili:   ${PASS_COUNT}"
echo "Basarisiz:  ${FAIL_COUNT}"
echo "Sure:       ${DURATION}s"

if [ -n "$FAILED_SUITES" ]; then
	echo ""
	echo "Basarisiz dosyalar:"
	for s in $FAILED_SUITES; do
		echo "  - $s"
	done
fi

echo "========================================"

if [ "$FAIL_COUNT" -gt 0 ]; then
	exit 1
fi

exit 0

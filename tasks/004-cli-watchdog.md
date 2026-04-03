# F004 - CLI MVP & Watchdog

## Description

Mergen CLI main entry point, core commands, watchdog daemon infrastructure, and procd service integration.

**PRD Reference**: Section 7.1-7.4, 5.1.1 (Phase 1 — CLI + Watchdog + Tests)

## Tasks

### T010 - Core CLI Commands

**Status**: COMPLETED
**Priority**: P1 (Critical)
**Effort**: 3 days

**Description**:
Mergen CLI main script and core commands: add, remove, list, apply, status.

**Dependencies**: T003, T007, T008, T009

**Technical Details**:
- `/usr/bin/mergen` — main CLI entry point (ash script)
- Command dispatch: `case "$1" in add|remove|list|apply|status|...)`
- `mergen add --asn 13335 --via wg0 --name cloudflare --priority 100`
- `mergen add --ip 10.0.0.0/8 --via lan --name internal`
- `mergen remove cloudflare`
- `mergen list` — table-formatted output (PRD Section 7.3)
- `mergen apply [--safe] [--force]` — resolver -> engine -> route flow (PRD Section 5.3). `--force` bypasses prefix limit warnings (PRD Section 7.4). `--safe` enables safe mode (see T016).
- `mergen status` — daemon status, rule/prefix counts, last sync (PRD Section 7.3)
- Argument parsing: `getopts` or manual shift-based
- Error exit codes: 0=success, 1=general error, 2=validation error

**Success Criteria**:
1. `mergen add --asn 13335 --via wg0 --name cf` adds a rule (visible in UCI)
2. `mergen list` displays added rules in table format
3. `mergen apply` resolves prefixes and applies routing rules
4. `mergen status` displays daemon status and statistics
5. PRD 7.4 error messages are returned for invalid inputs
6. Runs without errors in ash shell

**Files to Touch**:
- `mergen/files/usr/bin/mergen` (update — full CLI implementation)

---

### T011 - Utility CLI Commands

**Status**: COMPLETED
**Priority**: P2 (High)
**Effort**: 1 day

**Description**:
Utility CLI commands: version, help, validate.

**Dependencies**: T010

**Technical Details**:
- `mergen version` — `Mergen v{VERSION} | OpenWrt {release}` format
- `mergen help` — general help (command list)
- `mergen help <command>` — command-specific detailed help
- `mergen validate` — validate UCI config (without applying)
  - Check provider accessibility (optional `--check-providers`)
  - Rule syntax check (valid ASN, IP, interface)
  - Conflict check (same prefix with different targets)

**Success Criteria**:
1. `mergen version` displays correct version information
2. `mergen help` lists all commands
3. `mergen help add` shows the add command's flags
4. `mergen validate` returns "OK" for a valid config
5. `mergen validate` returns a list of issues for an invalid config

**Files to Touch**:
- `mergen/files/usr/bin/mergen` (update — version/help/validate handlers)

---

### T012 - Watchdog Daemon

**Status**: COMPLETED
**Priority**: P2 (High)
**Effort**: 2 days

**Description**:
Lightweight watchdog daemon script. Managed by procd, handles hotplug events and periodic tasks.

**Dependencies**: T001, T003

**Technical Details**:
- `/usr/sbin/mergen-watchdog` — daemon main loop
- Procd service: `/etc/init.d/mergen` (USE_PROCD=1, procd_set_param)
- Main loop: `while true; do ... sleep $interval; done`
- Tasks:
  - Periodic prefix update check (update_interval)
  - Safe mode ping check (after apply)
  - Status file writing: `/tmp/mergen/status.json`
- Lock file: `/var/lock/mergen.lock` — concurrent access control with CLI
- `mergen_lock_acquire()` / `mergen_lock_release()` — flock-based

**Success Criteria**:
1. `service mergen start` starts the watchdog
2. `service mergen stop` stops the watchdog
3. `/tmp/mergen/status.json` contains up-to-date status information
4. Lock mechanism prevents conflicts between CLI and watchdog
5. Procd respawn: watchdog automatically restarts if it crashes

**Files to Touch**:
- `mergen/files/usr/sbin/mergen-watchdog` (new)
- `mergen/files/etc/init.d/mergen` (update — procd service)
- `mergen/files/usr/lib/mergen/core.sh` (update — lock functions)

---

### T013 - Unit Test Framework & Basic Tests

**Status**: NOT_STARTED
**Priority**: P2 (High)
**Effort**: 1.5 days

**Description**:
shunit2 test infrastructure and unit tests for Phase 1 components.

**Dependencies**: T003, T007, T008, T009

**Technical Details**:
- Test framework: shunit2 (ash/busybox compatible — PRD Section 12)
- Test directory: `mergen/tests/`
- Test runner: `./tests/run_all.sh` — run all test files
- Mock strategy: override `ip`, `uci`, `curl` commands with mock functions
- Test files:
  - `test_core.sh`: UCI read/write
  - `test_engine.sh`: Rule CRUD
  - `test_route.sh`: Route creation (mocked ip)
  - `test_resolver.sh`: Provider orchestration (mocked provider)
  - `test_ripe_provider.sh`: RIPE API parsing (mocked response)
  - `test_utils.sh`: Validation functions
  - `test_cache.sh`: Cache TTL logic

**Success Criteria**:
1. `./tests/run_all.sh` runs all tests and reports results
2. At least 5 test cases per module
3. Edge cases (empty input, large data, timeout) are tested
4. Runs in ash shell (bash not required)
5. Can be executed in CI (GitHub Actions)

**Files to Touch**:
- `mergen/tests/run_all.sh` (new)
- `mergen/tests/shunit2` (new — vendored)
- `mergen/tests/test_*.sh` (new — per module)

# F007 - Logging, Extended CLI & Security Hardening

## Description

Structured logging infrastructure, additional CLI commands (show, enable/disable, flush, diag, log), and security hardening.

**PRD Reference**: Section 7.2, 8.6, 10 (Phase 2 — Logging + CLI + Security)

## Tasks

### T019 - Logging Framework

**Status**: NOT_STARTED
**Priority**: P2 (High)
**Effort**: 1.5 days

**Description**:
Structured logging with log levels, component tagging, and syslog integration.

**Dependencies**: T003

**Technical Details**:
- Log levels: DEBUG, INFO, WARNING, ERROR
- Component tags: Resolver, Engine, Route, Provider, Daemon, CLI
- Syslog integration: `logger -t mergen -p daemon.{level}` (logread compatible)
- Log function: `mergen_log(level, component, message)`
- Log level filter: UCI `option log_level` (default: info)
- DEBUG level active only when `log_level='debug'` is set
- Timestamp format: ISO 8601

**Success Criteria**:
1. Mergen logs appear in `logread -e mergen` output
2. Log level filter works (debug logs do not appear at info level)
3. Filtering by component tag is possible
4. All critical operations (apply, rollback, provider calls) are logged
5. shunit2 tests pass

**Files to Touch**:
- `mergen/files/usr/lib/mergen/core.sh` (update — logging functions)
- `mergen/tests/test_logging.sh` (new)

---

### T020 - Extended CLI Commands

**Status**: NOT_STARTED
**Priority**: P2 (High)
**Effort**: 2 days

**Description**:
Phase 2 additional CLI commands: show, enable/disable, flush, diag, log.

**Dependencies**: T010, T019

**Technical Details**:
- `mergen show <name>`: Single rule detail — including prefix list, provider information
- `mergen enable <name>` / `mergen disable <name>`: Rule toggle (UCI update + re-apply)
- `mergen flush [--confirm]`: Remove all Mergen routes, nft sets, and ip rules. Requires `--confirm` flag or interactive confirmation to prevent accidental flush.
- `mergen diag [--asn <asn>]`: Diagnostic information:
  - Routing tables: `ip rule show`, `ip route show table {X}`
  - nft sets: `nft list sets`
  - Interface states: `ip link show`
  - Optional: prefix resolution test for a specific ASN
- `mergen log [--tail N] [--level LEVEL]`: Filter Mergen logs from syslog

**Success Criteria**:
1. `mergen show cloudflare` displays detailed rule information
2. `mergen enable/disable` changes rule state and updates routes
3. `mergen flush` removes all Mergen traces
4. `mergen diag` summarizes system state
5. `mergen log --tail 20 --level error` displays filtered logs

**Files to Touch**:
- `mergen/files/usr/bin/mergen` (update — new command handlers)

---

### T021 - Security Hardening

**Status**: NOT_STARTED
**Priority**: P1 (Critical)
**Effort**: 1.5 days

**Description**:
Input sanitization, prefix limits, HTTPS enforcement, and file permissions.

**Dependencies**: T009, T005

**Technical Details**:
- Shell injection protection: All user inputs pass through `validate_*` functions (T009)
- Prefix limits:
  - Per-rule: `option max_prefix_per_rule '10000'`
  - Total: `option max_prefix_total '50000'`
  - Warning on limit exceeded + force with `--force` flag (PRD Section 7.4)
- HTTPS enforcement: `curl --proto '=https'` on provider API calls
- UCI file permissions: `/etc/config/mergen` → 0600
- Lock file security: flock timeout, stale lock cleanup
- Validation: All security checks run on `mergen validate` invocation

**Success Criteria**:
1. Shell injection attempt is rejected (echo test)
2. A rule with 10001 prefixes produces a warning and is rejected without `--force`
3. HTTP (non-HTTPS) provider URL is rejected
4. UCI config file permissions are 0600
5. Stale lock file is cleaned up after 5 minutes

**Files to Touch**:
- `mergen/files/usr/lib/mergen/utils.sh` (update — limit checks)
- `mergen/files/usr/lib/mergen/resolver.sh` (update — HTTPS enforcement)
- `mergen/files/usr/lib/mergen/core.sh` (update — permissions)

---

### T022 - Phase 2 Integration Tests

**Status**: NOT_STARTED
**Priority**: P2 (High)
**Effort**: 1 day

**Description**:
Integration tests for rollback, nftables, and logging.

**Dependencies**: T014, T015, T016, T017, T019

**Technical Details**:
- Rollback test: apply → rule error → automatic rollback → state verification
- nftables test: set creation → element addition → fwmark check → set cleanup
- Logging test: operation → syslog output verification (component + level + message)
- Test environment: OpenWrt x86 QEMU VM or with mock commands
- Compliant with PRD Section 12 test distribution

**Success Criteria**:
1. Rollback integration tests pass
2. nftables set lifecycle test passes
3. Log outputs are verified in the expected format
4. Can be run in CI pipeline

**Files to Touch**:
- `mergen/tests/test_integration_rollback.sh` (new)
- `mergen/tests/test_integration_nftables.sh` (new)
- `mergen/tests/test_integration_logging.sh` (new)

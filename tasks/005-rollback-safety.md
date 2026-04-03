# F005 - Rollback & Atomic Apply

## Description

Safe rule application for remotely managed devices. Atomic apply, state snapshot, rollback command, watchdog timer, and safe mode.

**PRD Reference**: Section 5.2.3, 8.7, 10 (Phase 2 — Rollback Mechanism)

## Tasks

### T014 - Routing State Snapshot & Rollback

**Status**: COMPLETED
**Priority**: P1 (Critical)
**Effort**: 2.5 days

**Description**:
Mechanism for saving the current routing state before apply and restoring it.

**Dependencies**: T008, T010

**Technical Details**:
- Snapshot: save `ip rule save`, `ip route show table all`, `nft list sets` outputs under `/tmp/mergen/snapshot/`
- Snapshot files: `rules.save`, `routes.save`, `nftsets.save`, `uci.backup`
- `mergen_snapshot_create()`: Called automatically before apply
- `mergen_snapshot_restore()`: Restore from snapshot
- `mergen rollback` CLI command: revert to the most recent snapshot
- Only 1 snapshot is kept (LIFO — state before the last apply)

**Success Criteria**:
1. Snapshot is automatically created before apply
2. `mergen rollback` reverts to the previous state
3. Routing tables match the pre-apply state after restore
4. Snapshot files are under `/tmp/` (not written to flash)
5. Integration test: apply -> rollback -> state verification

**Files to Touch**:
- `mergen/files/usr/lib/mergen/route.sh` (update — snapshot functions)
- `mergen/files/usr/bin/mergen` (update — rollback command)
- `mergen/tests/test_rollback.sh` (new)

---

### T015 - Atomic Apply

**Status**: COMPLETED
**Priority**: P1 (Critical)
**Effort**: 2 days

**Description**:
All rules are either fully applied or none are applied. Automatic rollback on any error.

**Dependencies**: T014

**Technical Details**:
- `mergen_apply_atomic()`: take snapshot -> apply rules one by one -> rollback on error
- Error detection: check return code of `ip rule add` or `ip route add`
- On partial application: revert all rules applied up to that point
- Application order: by priority value (lower priority = applied first)
- On success: keep the snapshot (for subsequent rollback)

**Success Criteria**:
1. If all rules succeed, all are applied
2. If one rule fails, none are applied (previous state is preserved)
3. Error message specifies which rule failed
4. `mergen apply` exit code is non-zero on error
5. Integration test passes

**Files to Touch**:
- `mergen/files/usr/lib/mergen/route.sh` (update — atomic apply)

---

### T016 - Watchdog Timer & Safe Mode

**Status**: NOT_STARTED
**Priority**: P1 (Critical)
**Effort**: 2 days

**Description**:
Automatic rollback if confirmation is not received within a specified time after apply, or if the connectivity test fails.

**Dependencies**: T012, T014

**Technical Details**:
- `mergen apply --safe`: Apply with safe mode active
- Safe mode flow:
  1. Take snapshot
  2. Apply rules
  3. Ping test (`safe_mode_ping_target`, default: 8.8.8.8)
  4. Automatic rollback on failure
- Watchdog timer: watchdog daemon performs a ping test after `watchdog_interval` (default: 60s) expires
- Timer mechanism: create `/tmp/mergen/pending_confirm` file during apply, watchdog checks when time expires
- `mergen confirm`: Safe mode confirmation (cancel the timer)
- PRD Section 4.6, 7.4 error messages

**Success Criteria**:
1. `mergen apply --safe` performs a ping test after application
2. Automatic rollback and error message if ping fails
3. Rules persist if ping succeeds
4. `mergen confirm` cancels the timer
5. Watchdog daemon performs automatic rollback on timeout

**Files to Touch**:
- `mergen/files/usr/bin/mergen` (update — apply --safe, confirm)
- `mergen/files/usr/sbin/mergen-watchdog` (update — timer check)
- `mergen/files/usr/lib/mergen/route.sh` (update — safe mode)
- `mergen/tests/test_safe_mode.sh` (new)

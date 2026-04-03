# F010 - Import/Export & Automation

## Description

JSON import/export, cron-based automatic updates, hotplug integration, and the resolve command.

**PRD Reference**: Section 4.3, 7.2, 9 (Phase 3 — JSON Import/Export + Automation)

## Tasks

### T030 - JSON Import/Export

**Status**: NOT_STARTED
**Priority**: P2 (High)
**Effort**: 2 days

**Description**:
Loading rules from a JSON file and exporting existing rules as JSON.

**Dependencies**: T007, T010

**Technical Details**:
- `mergen import <file.json>`: Load rules from a JSON file
  - Format: JSON schema from PRD Section 4.3 (`rules[]` array)
  - Validation for each rule (ASN, IP, interface)
  - Conflict check against existing rules
  - `--replace` flag: delete existing rules and replace with imported ones
- `mergen export [--format json]`: Write rules as JSON to stdout or file
  - `--output <file>` to write to a file
  - UCI export: `mergen export --format uci`
- Automatic loading from `/etc/mergen/rules.d/` directory at startup
- JSON parse: `jsonfilter` (OpenWrt native)

**Success Criteria**:
1. `mergen import rules.json` successfully loads rules
2. `mergen export --format json` produces valid JSON output
3. Import → export → import cycle yields the same result (round-trip)
4. Descriptive error message for invalid JSON files
5. Files in rules.d/ directory are loaded at boot

**Files to Touch**:
- `mergen/files/usr/bin/mergen` (update — import/export handlers)
- `mergen/files/usr/lib/mergen/engine.sh` (update — JSON parse/serialize)
- `mergen/tests/test_import_export.sh` (new)

---

### T031 - Cron Auto-Update & mergen update

**Status**: NOT_STARTED
**Priority**: P2 (High)
**Effort**: 1.5 days

**Description**:
Periodic prefix update and manual update command.

**Dependencies**: T006, T010

**Technical Details**:
- `mergen update`: Refresh prefix lists for all active rules
  - Fetch current prefixes from provider for each ASN rule
  - Update cache
  - Optional: `--apply` flag to automatically apply after update
- Cron integration: Periodic check within watchdog daemon
  - `option update_interval '86400'` (24 hours)
  - Watchdog checks the last update time
  - Calls `mergen update --apply` when the interval has elapsed
- Update log: which rules had their prefix count changed

**Success Criteria**:
1. `mergen update` refreshes all prefixes
2. Prefixes with expired cache TTL are refreshed
3. Watchdog automatically triggers periodic updates
4. Changed prefix counts are logged after update
5. `--apply` flag performs update + apply in a single command

**Files to Touch**:
- `mergen/files/usr/bin/mergen` (update — update handler)
- `mergen/files/usr/sbin/mergen-watchdog` (update — periodic update check)

---

### T032 - Hotplug Integration

**Status**: NOT_STARTED
**Priority**: P2 (High)
**Effort**: 1.5 days

**Description**:
Dynamic update of Mergen rules on interface up/down events.

**Dependencies**: T010, T012

**Technical Details**:
- `/etc/hotplug.d/iface/50-mergen`: Hotplug script
- On interface up event:
  - Check rules routed to this interface
  - Trigger `mergen apply` if rules exist (only the relevant rules)
- On interface down event:
  - Deactivate rules routed to this interface
  - Remove routes (traffic going to the downed interface)
  - If fallback exists: redirect to alternative interface
- VPN tunnel states: wg0, tun0, etc. up/down events
- Hotplug script is called through watchdog (lock mechanism)

**Success Criteria**:
1. Related routes are removed when VPN interface goes down
2. Routes are recreated when VPN interface comes up
3. Traffic is redirected to alternative interface if fallback interface is defined
4. Hotplug events are logged
5. Concurrent hotplug events are coordinated with locks

**Files to Touch**:
- `mergen/files/etc/hotplug.d/iface/50-mergen` (new)
- `mergen/files/usr/sbin/mergen-watchdog` (update — hotplug handler)
- `mergen/tests/test_hotplug.sh` (new)

---

### T033 - Resolve Command & Phase 3 Tests

**Status**: NOT_STARTED
**Priority**: P3 (Medium)
**Effort**: 1 day

**Description**:
Command to display ASN prefixes without applying them, and Phase 3 provider tests.

**Dependencies**: T005, T023

**Technical Details**:
- `mergen resolve <asn> [--provider <name>]`: Display ASN prefix list (without creating routes)
  - Output: prefix list (v4/v6 separate), total count, source provider
  - `--provider` to force a specific provider
  - Default: first successful provider using fallback strategy
- Phase 3 tests (PRD Section 12):
  - Unit tests for each of the 6 providers (mock API response)
  - Fallback/cache integration tests
  - IPv6 prefix resolution tests

**Success Criteria**:
1. `mergen resolve 13335` displays a prefix list
2. `mergen resolve 13335 --provider ripe` fetches from RIPE
3. All provider mock tests pass
4. Fallback test: 1st provider error → 2nd provider success
5. IPv6 prefixes are parsed correctly

**Files to Touch**:
- `mergen/files/usr/bin/mergen` (update — resolve handler)
- `mergen/tests/test_provider_*.sh` (update — Phase 3 tests)

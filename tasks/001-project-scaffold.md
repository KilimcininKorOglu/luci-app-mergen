# F001 - Project Scaffold & UCI Configuration

## Description

Create an OpenWrt buildroot-compatible package structure and define the UCI configuration schema. This is the foundational infrastructure upon which all Mergen components will be built.

**PRD Reference**: Section 6.3, 9 (Phase 1 — Project Scaffold + UCI Configuration)

## Tasks

### T001 - OpenWrt Package Structure and Makefile

**Status**: NOT_STARTED
**Priority**: P1 (Critical)
**Effort**: 2 days

**Description**:
Create the OpenWrt buildroot Makefile structure and package directory hierarchy. Set up `files/etc/`, `files/usr/bin/`, `files/usr/lib/mergen/` under the `mergen/` root directory.

**Dependencies**: None

**Technical Details**:
- OpenWrt Makefile: `PKG_NAME`, `PKG_VERSION`, `PKG_RELEASE`, `DEPENDS`, `define Package/mergen/install`
- Dependencies: `ip-full`, `nftables` (or `ipset`), `curl` (or `wget`), `jsonfilter`
- Package size target: < 500 KB (PRD Section 11)
- Minimum OpenWrt version: 23.05+

**Success Criteria**:
1. `make package/mergen/compile` runs successfully in the OpenWrt SDK
2. Generated `.ipk` file is under 500 KB
3. Package directory structure matches the hierarchy in PRD Section 9
4. `opkg install mergen_*.ipk` installs successfully

**Files to Touch**:
- `mergen/Makefile` (new)
- `mergen/files/etc/config/mergen` (new)
- `mergen/files/etc/init.d/mergen` (new)
- `mergen/files/usr/bin/mergen` (new — stub)
- `mergen/files/usr/lib/mergen/core.sh` (new — stub)

---

### T002 - UCI Configuration Schema

**Status**: NOT_STARTED
**Priority**: P1 (Critical)
**Effort**: 1.5 days

**Description**:
Implement the UCI config schema defined in PRD Section 6.3. Global settings, provider definitions, and rule blocks.

**Dependencies**: T001

**Technical Details**:
- `config mergen 'global'`: enabled, log_level, update_interval, default_table, ipv6_enabled, cache_dir, watchdog_enabled, watchdog_interval, safe_mode_ping_target, config_version
- `config provider`: enabled, priority, api_url, timeout, rate_limit
- `config rule`: name, asn/ip (list), via, priority, enabled, fallback
- Default config: RIPE and bgptools providers active, no example rules

**Success Criteria**:
1. `/etc/config/mergen` file is in valid UCI format
2. `uci show mergen` correctly displays all global, provider, and rule blocks
3. Operations like `uci set mergen.@rule[0].name='test'` work without errors
4. Config file permissions are 0600 (PRD Section 10)

**Files to Touch**:
- `mergen/files/etc/config/mergen` (update — full schema)

---

### T003 - UCI Read/Write Library

**Status**: NOT_STARTED
**Priority**: P1 (Critical)
**Effort**: 2 days

**Description**:
Shell library wrapping UCI read/write functions. All Mergen components access UCI through this layer.

**Dependencies**: T002

**Technical Details**:
- Functions in `core.sh`: `mergen_uci_get`, `mergen_uci_set`, `mergen_uci_add`, `mergen_uci_delete`, `mergen_uci_commit`
- Rule listing: `mergen_list_rules()` — iterate all `config rule` blocks
- Provider listing: `mergen_list_providers()` — active providers sorted by priority
- ash/busybox compatible (no bashisms)
- `uci` CLI wrapper (not libuci shell binding)

**Success Criteria**:
1. Global settings can be read and written
2. Rule add/delete/update works through UCI
3. Provider list returns in priority order
4. Runs without errors in ash shell (no bash-specific syntax)
5. shunit2 unit tests pass

**Files to Touch**:
- `mergen/files/usr/lib/mergen/core.sh` (update)
- `mergen/tests/test_core.sh` (new)

---

### T048 - Config Migration Script

**Status**: NOT_STARTED
**Priority**: P2 (High)
**Effort**: 1 day

**Description**:
UCI config versioning and automatic migration script for package upgrades. Ensures backward compatibility when the config schema changes between versions.

**Dependencies**: T002, T003

**Technical Details**:
- `/usr/lib/mergen/migrate.sh` — migration script (PRD Section 10.1)
- Version check: read `option config_version` from UCI, compare with expected version
- Migration flow:
  1. Package update triggers `postinst` script
  2. `postinst` calls `migrate.sh`
  3. Read current `config_version`
  4. If old: apply transformation rules, write new `config_version`
  5. On failure: restore from backup
- Pre-migration backup: `/tmp/mergen/config.backup` (automatic)
- Backward compatibility: supports 1 previous major version
- `postinst` integration in OpenWrt Makefile (`define Package/mergen/postinst`)

**Success Criteria**:
1. `migrate.sh` detects config version and applies transformations
2. Pre-migration backup is created at `/tmp/mergen/config.backup`
3. On migration failure, backup is restored automatically
4. `postinst` script calls `migrate.sh` on package upgrade
5. Config version is updated after successful migration

**Files to Touch**:
- `mergen/files/usr/lib/mergen/migrate.sh` (new)
- `mergen/Makefile` (update — postinst hook)
- `mergen/tests/test_migrate.sh` (new)

# F003 - Rule Engine & Route Manager

## Description

Rule management (CRUD) and Linux policy routing (ip rule + ip route) implementation. Mergen's core data path.

**PRD Reference**: Section 5.2.2, 5.2.3, 5.3 (Phase 1 — Rule Engine + Route Manager)

## Tasks

### T007 - Rule CRUD Operations

**Status**: COMPLETED
**Priority**: P1 (Critical)
**Effort**: 2 days

**Description**:
UCI-based rule add, delete, list, update, and enable/disable operations.

**Dependencies**: T003

**Technical Details**:
- `engine.sh` module
- `mergen_rule_add(name, type, target, via, priority)`: Add a `config rule` block to UCI
- `mergen_rule_remove(name)`: Delete rule by name
- `mergen_rule_list()`: Formatted table of all rules (ID, NAME, TYPE, TARGET, VIA, PRI, STATUS)
- `mergen_rule_get(name)`: Single rule detail
- `mergen_rule_toggle(name, enabled)`: Enable/disable
- Name uniqueness check (error if a rule with the same name exists)
- Rule types: `asn`, `ip`, `mixed` (multiple ASN or IP lists)

**Success Criteria**:
1. Rule add writes to UCI in the correct format
2. Rule remove cleans up the relevant UCI block
3. Rule list outputs a formatted table (PRD Section 7.3)
4. Error when attempting to add a rule with a duplicate name
5. shunit2 unit tests pass

**Files to Touch**:
- `mergen/files/usr/lib/mergen/engine.sh` (new)
- `mergen/tests/test_engine.sh` (new)

---

### T008 - Policy Routing via ip rule + ip route

**Status**: NOT_STARTED
**Priority**: P1 (Critical)
**Effort**: 2.5 days

**Description**:
Creating prefix-based routing tables using the Linux kernel policy routing mechanism. A separate routing table for each rule.

**Dependencies**: T003, T007

**Technical Details**:
- `route.sh` module
- Routing table: match with `ip rule add` via fwmark or to-prefix to a custom table
- `ip route add {prefix} via {gateway} dev {interface} table {table_num}`
- Default table number: 100 (UCI `option default_table`)
- Table per rule: `default_table + rule_index`
- `mergen_route_apply(rule_name)`: Apply routes for a single rule
- `mergen_route_remove(rule_name)`: Remove routes for a single rule
- `mergen_route_apply_all()`: Apply all active rules
- Automatic gateway detection: find default gw via `ip route show dev {interface}`

**Success Criteria**:
1. Mergen rules appear in `ip rule show` output
2. Prefixes are correctly routed to the right interface in `ip route show table 100` output
3. Routing table is cleaned up when a rule is removed
4. Error message for a non-existent interface (PRD Section 7.4)
5. shunit2 tests pass (with mocked ip command output)

**Files to Touch**:
- `mergen/files/usr/lib/mergen/route.sh` (new)
- `mergen/tests/test_route.sh` (new)

---

### T009 - Input Validation Library

**Status**: COMPLETED
**Priority**: P1 (Critical)
**Effort**: 1 day

**Description**:
Validation functions for all user inputs. Critical from a security perspective.

**Dependencies**: T001

**Technical Details**:
- `utils.sh` module
- `validate_asn(value)`: Numeric, range 1-4294967295
- `validate_ip_cidr(value)`: Valid IPv4/IPv6 CIDR format
- `validate_interface(name)`: Check if interface exists on the system (`ip link show`)
- `validate_name(value)`: Alphanumeric + hyphen/underscore, 1-32 characters
- `validate_priority(value)`: Numeric, range 1-32000
- Shell injection protection: special character check on all inputs (PRD Section 10)
- Error messages comply with PRD Section 7.4

**Success Criteria**:
1. Invalid ASN (abc, -1, 99999999999) is rejected
2. Invalid CIDR (10.0.0.0/33, abc/8) is rejected
3. Non-existent interface (wg99) is rejected along with a list of available interfaces
4. Shell injection attempt (`; rm -rf /`) is safely rejected
5. All error messages are user-friendly and in Turkish

**Files to Touch**:
- `mergen/files/usr/lib/mergen/utils.sh` (new)
- `mergen/tests/test_utils.sh` (new)

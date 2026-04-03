# F009 - IPv6 & Advanced Rule Engine

## Description

IPv6 dual-stack routing support, conflict detection, CIDR aggregation, and rule grouping.

**PRD Reference**: Section 5.2.2, 5.2.3, 8.7 (Phase 3 — IPv6 + Advanced Rule Engine)

## Tasks

### T027 - IPv6 Dual-Stack Routing

**Status**: COMPLETED
**Priority**: P2 (High)
**Effort**: 2.5 days

**Description**:
IPv6 prefix resolution and dual-stack policy routing with `ip -6 rule` + `ip -6 route`.

**Dependencies**: T008, T017

**Technical Details**:
- Fetch IPv6 prefixes from providers (v4/v6 separation is already done in T005)
- IPv6 routing tables with `ip -6 rule add` + `ip -6 route add`
- nftables: `inet` family sets (separate sets for ipv4_addr and ipv6_addr)
- ipset fallback: `hash:net family inet6`
- Manage v4+v6 prefixes together for the same rule
- UCI: `option ipv6_enabled '1'` toggle (IPv6 prefixes are skipped when disabled)
- Separate v4/v6 prefix count display in `mergen list` output

**Success Criteria**:
1. `mergen apply` creates both IPv4 and IPv6 routes
2. IPv6 rules appear in `ip -6 rule show` and `ip -6 route show table X` output
3. Only IPv4 prefixes are processed when IPv6 is disabled
4. nftables inet family sets work correctly
5. IPv6 prefix resolution tests pass

**Files to Touch**:
- `mergen/files/usr/lib/mergen/route.sh` (update — IPv6 routing)
- `mergen/files/usr/lib/mergen/resolver.sh` (update — v6 prefix separation)
- `mergen/tests/test_ipv6.sh` (new)

---

### T028 - Conflict Detection & CIDR Aggregation

**Status**: NOT_STARTED
**Priority**: P3 (Medium)
**Effort**: 2 days

**Description**:
Detecting conflicts where the same prefix is routed to different targets, and aggregating small CIDRs into larger blocks.

**Dependencies**: T007

**Technical Details**:
- Conflict detection:
  - `mergen_check_conflicts()`: Compare prefixes across all active rules
  - Detect overlapping CIDR blocks (rule A 10.0.0.0/8, rule B 10.1.0.0/16 → conflict)
  - Warning message: which rules conflict, which prefixes overlap
  - `mergen validate` reports conflicts
- CIDR aggregation:
  - `mergen_aggregate_prefixes()`: Merge consecutive small CIDRs into larger blocks
  - Example: 10.0.0.0/25 + 10.0.0.128/25 → 10.0.0.0/24
  - Reduces nftables set size, improves performance
  - Non-aggressive: only merge adjacent blocks

**Success Criteria**:
1. Overlapping prefixes are detected and a warning is issued
2. `mergen validate` reports conflicts
3. Set size is reduced after CIDR aggregation
4. Aggregation does not break original routing behavior
5. Unit tests pass

**Files to Touch**:
- `mergen/files/usr/lib/mergen/engine.sh` (update — conflict detection, aggregation)
- `mergen/tests/test_conflicts.sh` (new)
- `mergen/tests/test_aggregation.sh` (new)

---

### T029 - Rule Grouping (Label/Tag)

**Status**: NOT_STARTED
**Priority**: P4 (Low)
**Effort**: 1 day

**Description**:
Rule tagging/grouping system. Used for batch operations.

**Dependencies**: T007

**Technical Details**:
- UCI: `list tag 'vpn'`, `list tag 'work'` — add tags to a rule block
- `mergen list --tag vpn`: Filter by tag
- `mergen enable --tag vpn`: Enable all rules with the tag
- `mergen disable --tag vpn`: Disable all rules with the tag
- A rule can have multiple tags

**Success Criteria**:
1. Tags can be added to a rule and are stored in UCI
2. Tag-based filtering works
3. Tag-based batch enable/disable works
4. A rule can have multiple tags

**Files to Touch**:
- `mergen/files/usr/lib/mergen/engine.sh` (update — tag support)
- `mergen/files/usr/bin/mergen` (update — --tag flag)

# F006 - nftables/ipset Integration

## Description

nftables set and ipset fallback implementation for performant packet matching. Fast access to thousands of prefixes with O(1) hash lookup.

**PRD Reference**: Section 5.2.3, 11 (Phase 2 — nftables Set Integration)

## Tasks

### T017 - nftables Set Management

**Status**: NOT_STARTED
**Priority**: P1 (Critical)
**Effort**: 2.5 days

**Description**:
Creating an nftables set for each rule, bulk-adding prefixes to the set, and fwmark-based ip rule matching.

**Dependencies**: T008

**Technical Details**:
- Set creation: `nft add set inet mergen mergen_{rule_name} { type ipv4_addr; flags interval; }`
- Element addition: `nft add element inet mergen mergen_{rule_name} { 1.0.0.0/24, 1.1.1.0/24, ... }`
- Bulk addition: write prefixes to a batch file, load in bulk with `nft -f` (performance)
- fwmark-based routing: `nft add rule inet mergen prerouting ip daddr @mergen_{rule_name} meta mark set {mark}`
- `ip rule add fwmark {mark} table {table_num}`
- Separate sets for IPv4 and IPv6 (inet family)
- Performance target: 1000 prefixes < 5 sec (PRD Section 11)

**Success Criteria**:
1. `nft list set inet mergen mergen_cloudflare` shows the prefixes
2. Traffic matching the fwmark is routed to the correct routing table
3. 1000 prefixes load within 5 seconds
4. Set cleanup: set is deleted when the rule is deleted
5. Appropriate error message if nftables is not available

**Files to Touch**:
- `mergen/files/usr/lib/mergen/route.sh` (update — nftables functions)
- `mergen/tests/test_nftables.sh` (new)

---

### T018 - ipset Fallback

**Status**: NOT_STARTED
**Priority**: P2 (High)
**Effort**: 1.5 days

**Description**:
ipset fallback for older OpenWrt versions (22.03 and earlier) where nftables is not available.

**Dependencies**: T017

**Technical Details**:
- Automatic detection: `command -v nft` -> nftables, otherwise ipset
- ipset creation: `ipset create mergen_{rule_name} hash:net`
- Element addition: `ipset add mergen_{rule_name} {prefix}`
- iptables matching: `iptables -t mangle -A PREROUTING -m set --match-set mergen_{rule_name} dst -j MARK --set-mark {mark}`
- UCI setting: `option packet_engine 'auto'` / `'nftables'` / `'ipset'`
- Common interface: `mergen_set_create()`, `mergen_set_add()`, `mergen_set_flush()`, `mergen_set_destroy()` — dispatch based on backend

**Success Criteria**:
1. ipset is automatically used if nftables is not available
2. Same routing behavior is achieved with ipset
3. `mergen diag` shows which engine is in use
4. When the engine changes, existing sets are cleaned up and recreated
5. Engine can be force-selected via UCI

**Files to Touch**:
- `mergen/files/usr/lib/mergen/route.sh` (update — ipset fallback, engine abstraction)
- `mergen/tests/test_ipset.sh` (new)

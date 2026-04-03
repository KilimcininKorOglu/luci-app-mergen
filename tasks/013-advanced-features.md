# F013 - Advanced Features

## Description

Secondary objectives: DNS-based routing, country-based routing, traffic statistics, failover/health check and mwan3 integration.

**PRD Reference**: Section 3.2 (Phase 6 — Advanced Features)

## Tasks

### T042 - DNS-Based Routing

**Status**: COMPLETED
**Priority**: P3 (Medium)
**Effort**: 3 days

**Description**:
Domain-based routing rules. Dynamic IP resolution from DNS responses via dnsmasq nftset/ipset integration.

**Dependencies**: T017, T018

**Technical Details**:
- dnsmasq integration: `nftset=/netflix.com/inet#mergen#mergen_netflix` (nftables) or `ipset=/netflix.com/mergen_netflix` (ipset)
- UCI: `option domain 'netflix.com'` — domain support in rule block
- Rule type: `domain` (in addition to ASN/IP)
- IPs resolved from DNS responses are automatically added to the nft set
- dnsmasq restart is required (on config change)
- Wildcard support: `*.netflix.com`

**Success Criteria**:
1. `mergen add --domain netflix.com --via wg0` command works
2. DNS query result IP is automatically added to the nft set
3. dnsmasq config is automatically updated
4. Wildcard domain support works
5. When a domain rule is removed, dnsmasq config is cleaned up

**Files to Touch**:
- `mergen/files/usr/lib/mergen/engine.sh` (update — domain rule type)
- `mergen/files/usr/lib/mergen/route.sh` (update — dnsmasq integration)
- `mergen/files/usr/bin/mergen` (update — --domain flag)

---

### T043 - Country-Based Routing

**Status**: NOT_STARTED
**Priority**: P3 (Medium)
**Effort**: 2 days

**Description**:
Bulk ASN addition by country code. Country-ASN mapping via MaxMind GeoLite2 Country database.

**Dependencies**: T024, T010

**Technical Details**:
- `mergen add --country TR --via wan --name turkiye-direkt` (PRD Section 4.7)
- Country → ASN mapping: MaxMind GeoLite2 Country DB or country-asn list
- Bulk rule creation: a single super-rule for all ASNs in a country
- Prefix count warning: country-based rules can generate thousands of prefixes
- Country selector dropdown in LuCI

**Success Criteria**:
1. `mergen add --country TR --via wan` adds all TR ASN prefixes
2. Country code validation (ISO 3166-1 alpha-2)
3. Prefix limit warning is shown for large countries
4. Country-based rule appears in `mergen list` output
5. Country selector works in LuCI

**Files to Touch**:
- `mergen/files/usr/lib/mergen/engine.sh` (update — country rule type)
- `mergen/files/usr/bin/mergen` (update — --country flag)

---

### T044 - Traffic Statistics & Failover

**Status**: NOT_STARTED
**Priority**: P3 (Medium)
**Effort**: 3 days

**Description**:
Traffic statistics via nftables counters and interface failover/health check system.

**Dependencies**: T017, T012

**Technical Details**:
- **Traffic statistics**:
  - nftables counter: per-rule packet/byte counting with `nft add rule ... counter`
  - `mergen status --traffic`: per-rule traffic display
  - Traffic indicator in LuCI (additional column in rules table)
  - Optional: time series via collectd integration
- **Failover**:
  - `option fallback 'wan'` — fallback interface in rule UCI
  - Watchdog periodic ping for interface health check
  - When interface goes down: move routes to fallback interface
  - When interface comes back up: restore to original interface
  - Failover configuration in LuCI (PRD Section 8.4)

**Success Criteria**:
1. `mergen status --traffic` shows per-rule packet/byte counts
2. nft counter counts correctly
3. For a rule with a defined failover interface, traffic is automatically redirected when the interface goes down
4. When the interface comes back up, original route is restored
5. Traffic and failover information is visible in LuCI

**Files to Touch**:
- `mergen/files/usr/lib/mergen/route.sh` (update — counters, failover)
- `mergen/files/usr/sbin/mergen-watchdog` (update — health check, failover trigger)
- `mergen/files/usr/bin/mergen` (update — status --traffic)

---

### T045 - mwan3 Integration

**Status**: NOT_STARTED
**Priority**: P4 (Low)
**Effort**: 2 days

**Description**:
Compatibility and integration with existing mwan3 rules.

**Dependencies**: T008

**Technical Details**:
- mwan3 conflict detection: overlap check between mwan3 policies and Mergen rules
- mwan3 policy injection: writing Mergen rules into mwan3 config
- Mode selection: UCI `option mode 'standalone'` or `option mode 'mwan3'`
- Standalone: Mergen manages its own routing tables
- mwan3 mode: Mergen delegates rules to mwan3
- `mergen diag --mwan3`: mwan3 compatibility check

**Success Criteria**:
1. Conflict warning with mwan3 in standalone mode
2. In mwan3 mode, rules are written to mwan3 config
3. Mode transition is performed cleanly
4. `mergen diag --mwan3` provides a compatibility report

**Files to Touch**:
- `mergen/files/usr/lib/mergen/route.sh` (update — mwan3 mode)
- `mergen/files/usr/bin/mergen` (update — diag --mwan3)

# F008 - Multi-Provider System

## Description

Implementation of all 6 ASN data sources, priority-based fallback, health monitoring, and advanced cache management.

**PRD Reference**: Section 5.2.1, 8.5 (Phase 3 — Additional ASN Providers + Provider Management)

## Tasks

### T023 - bgp.tools & bgpview.io Providers

**Status**: COMPLETED
**Priority**: P2 (High)
**Effort**: 2 days

**Description**:
Two additional REST API-based providers: bgp.tools and bgpview.io.

**Dependencies**: T004

**Technical Details**:
- **bgp.tools**: `bgptools.sh`
  - Endpoint: `https://bgp.tools/table.jsonl` (ASN filtering)
  - Optional API key header (premium access)
  - Response: JSONL format — line-by-line parse
- **bgpview.io**: `bgpview.sh`
  - Endpoint: `https://api.bgpview.io/asn/{asn}/prefixes`
  - Response: JSON — `data.ipv4_prefixes[].prefix`, `data.ipv6_prefixes[].prefix`
  - Rate limit: 30 req/minute
- Both providers conform to the plugin interface (`provider_resolve`, `provider_name`, `provider_test`)

**Success Criteria**:
1. `mergen resolve 13335 --provider bgptools` returns a prefix list
2. `mergen resolve 13335 --provider bgpview` returns a prefix list
3. API key configuration is read from UCI
4. Timeout and rate limit management works
5. Unit tests with mock response pass

**Files to Touch**:
- `mergen/files/etc/mergen/providers/bgptools.sh` (new)
- `mergen/files/etc/mergen/providers/bgpview.sh` (new)
- `mergen/tests/test_bgptools_provider.sh` (new)
- `mergen/tests/test_bgpview_provider.sh` (new)

---

### T024 - MaxMind GeoLite2 Provider

**Status**: COMPLETED
**Priority**: P3 (Medium)
**Effort**: 2 days

**Description**:
Offline ASN resolution using a local MMDB database. Works without an internet connection.

**Dependencies**: T004

**Technical Details**:
- `maxmind.sh` provider
- GeoLite2-ASN.mmdb reading: Lua `mmdblua` module or `mmdbinspect` CLI tool
- DB path: UCI `option db_path '/usr/share/mergen/GeoLite2-ASN.mmdb'`
- License key: Stored in UCI (for automatic updates)
- DB update: Download from MaxMind API via `mergen update --provider maxmind`
- Advantage: Works offline, no latency
- Disadvantage: Requires DB updates, MMDB reading library dependency

**Success Criteria**:
1. Offline ASN resolution works when MMDB file is present
2. Appropriate error message when MMDB file is missing
3. DB update command works (license key required)
4. Can be used as fallback when online providers are down
5. Unit tests pass

**Files to Touch**:
- `mergen/files/etc/mergen/providers/maxmind.sh` (new)
- `mergen/tests/test_maxmind_provider.sh` (new)

---

### T025 - RouteViews & IRR/RADB Providers

**Status**: NOT_STARTED
**Priority**: P3 (Medium)
**Effort**: 2.5 days

**Description**:
MRT/RIB dump-based RouteViews and whois-based IRR/RADB providers.

**Dependencies**: T004

**Technical Details**:
- **RouteViews**: `routeviews.sh`
  - MRT dump download (large file — recommended during off-peak hours)
  - RIB parse: prefix extraction using `bgpdump` or custom ash script
  - Local cache: parsed results stored in file
- **IRR/RADB**: `irr.sh`
  - Whois query: `whois -h whois.radb.net -- -i origin AS{asn}`
  - Response parse: prefix extraction from `route:` lines
  - Server: configurable from UCI
- Both providers are heavy/slow — low priority, intended as fallback

**Success Criteria**:
1. ASN prefix list is extracted from RouteViews dump
2. Prefix list is extracted from IRR/RADB whois query
3. Large dump file does not cause memory overflow (streaming parse)
4. Timeout management works for slow providers
5. Unit tests pass

**Files to Touch**:
- `mergen/files/etc/mergen/providers/routeviews.sh` (new)
- `mergen/files/etc/mergen/providers/irr.sh` (new)
- `mergen/tests/test_routeviews_provider.sh` (new)
- `mergen/tests/test_irr_provider.sh` (new)

---

### T026 - Provider Fallback & Health Tracking

**Status**: NOT_STARTED
**Priority**: P2 (High)
**Effort**: 2 days

**Description**:
Priority-ordered fallback, provider health monitoring, and advanced cache management.

**Dependencies**: T004, T006, T023

**Technical Details**:
- Fallback strategy (UCI setting):
  - `sequential`: Try in priority order, use the first successful result
  - `parallel`: Query all active providers simultaneously, use the fastest result
  - `cache_only`: Cache only, no provider calls
- Health monitoring:
  - Success/failure counter (last 24 hours)
  - Average response time
  - State: `/tmp/mergen/provider_health.json`
- Cache: Use prefixes directly if TTL has not expired; refresh from provider if expired
- Provider health information in `mergen status` output

**Success Criteria**:
1. When the first provider fails, the second provider is automatically tried
2. Provider health metrics are recorded and viewable
3. When all providers are down, served from cache (if available)
4. Parallel mode returns the fastest result
5. Fallback/cache integration tests pass

**Files to Touch**:
- `mergen/files/usr/lib/mergen/resolver.sh` (update — fallback strategies, health tracking)
- `mergen/tests/test_provider_fallback.sh` (new)

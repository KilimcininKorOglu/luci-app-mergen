# F002 - ASN Resolver & RIPE Provider

## Description

Pluggable provider architecture and the first ASN data source (RIPE Stat API) implementation. Converts ASN numbers to prefix lists.

**PRD Reference**: Section 5.2.1 (Phase 1 — ASN Resolver — RIPE Provider)

## Tasks

### T004 - Provider Plugin Architecture

**Status**: COMPLETED
**Priority**: P1 (Critical)
**Effort**: 1.5 days

**Description**:
Plugin system where each provider implements a standard interface under `/etc/mergen/providers/`. Each plugin is loaded as a `.sh` file.

**Dependencies**: T003

**Technical Details**:
- Plugin interface: `provider_resolve(asn)` → prefix list (one CIDR per line on stdout)
- Plugin meta: `provider_name()`, `provider_priority()`, `provider_test()` (connectivity test)
- Plugin loading: `source /etc/mergen/providers/${provider}.sh`
- Resolver orchestration: `resolver.sh` — get active provider list from UCI, try in priority order
- On failure, fall back to the next provider

**Success Criteria**:
1. Plugin interface is defined and documented
2. Adding a new provider requires only a single `.sh` file
3. Resolver reads provider list from UCI in priority order
4. When a provider returns an error, the next provider is tried
5. shunit2 tests pass (with mock provider)

**Files to Touch**:
- `mergen/files/usr/lib/mergen/resolver.sh` (new)
- `mergen/files/etc/mergen/providers/` (new — directory)
- `mergen/tests/test_resolver.sh` (new)

---

### T005 - RIPE Stat API Integration

**Status**: COMPLETED
**Priority**: P1 (Critical)
**Effort**: 2 days

**Description**:
First provider implementation that fetches announced prefix lists for an ASN from the RIPE Stat API.

**Dependencies**: T004

**Technical Details**:
- Endpoint: `https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS{asn}`
- HTTP client: `curl -s --max-time 30` (wget fallback)
- JSON parse: `jsonfilter` (OpenWrt native) or `lua cjson`
- Response format: `data.prefixes[].prefix` — CIDR list
- ASN format validation: numeric only, range 1-4294967295 (PRD Section 10)
- Rate limit: default 1 req/s, configurable via UCI

**Success Criteria**:
1. `mergen resolve 13335` returns Cloudflare prefix list from RIPE
2. Descriptive error message for invalid ASN (PRD Section 7.4)
3. Proper error handling on timeout
4. IPv4 and IPv6 prefixes are parsed separately
5. shunit2 tests pass (with mock API response)

**Files to Touch**:
- `mergen/files/etc/mergen/providers/ripe.sh` (new)
- `mergen/tests/test_ripe_provider.sh` (new)

---

### T006 - Prefix Cache Layer

**Status**: COMPLETED
**Priority**: P2 (High)
**Effort**: 1.5 days

**Description**:
TTL-based caching of prefix lists fetched from providers under `/tmp/mergen/cache/`.

**Dependencies**: T004, T005

**Technical Details**:
- Cache directory: `/tmp/mergen/cache/` (RAM disk — not written to flash, PRD Section 6.3)
- Cache file format: `AS{asn}.v4.txt`, `AS{asn}.v6.txt` (one CIDR per line)
- Cache meta: `AS{asn}.meta` — `timestamp`, `provider`, `ttl`
- TTL: from UCI `option update_interval` (default: 86400s = 24 hours)
- Cache hit: if file exists and TTL has not expired, read directly from file
- Cache miss: fetch from provider, write to file
- `mergen_cache_clear()`: clear all cache

**Success Criteria**:
1. First resolution fetches from provider and writes to cache
2. Second resolution reads from cache (provider is not called)
3. Expired TTL cache is re-fetched from provider
4. Cache clear function works
5. Cache size stays under control on 32 MB RAM devices

**Files to Touch**:
- `mergen/files/usr/lib/mergen/resolver.sh` (update — cache integration)
- `mergen/tests/test_cache.sh` (new)

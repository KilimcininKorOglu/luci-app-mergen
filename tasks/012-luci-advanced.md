# F012 - LuCI Advanced Pages

## Description

Full-featured version of all 7 LuCI pages: drag-and-drop, bulk operations, ASN browser, interfaces, logs, advanced settings full version, provider advanced.

**PRD Reference**: Section 8.2-8.7 (Phase 5 — LuCI Advanced Pages)

## Tasks

### T038 - Rules Page Advanced (Drag-Drop, Bulk Ops)

**Status**: COMPLETED
**Priority**: P3 (Medium)
**Effort**: 2 days

**Description**:
Advanced features of the rules page: drag-and-drop prioritization, bulk operations, cloning, JSON export.

**Dependencies**: T036

**Technical Details**:
- Drag-and-drop: sorting rule rows with JavaScript, automatic priority recalculation
- Bulk operations: multi-select with checkboxes, bulk enable/disable, bulk delete, bulk interface change
- Rule cloning: copy an existing rule with a new name
- JSON export: download selected rules as JSON
- Changes are not saved until the "Apply" button is pressed

**Success Criteria**:
1. Drag-and-drop rule sorting works
2. Multi-select and bulk operations work
3. Rule cloning works
4. JSON export produces valid format
5. UI is smooth and responsive

**Files to Touch**:
- `luci-app-mergen/luasrc/view/mergen/rules.htm` (update)
- `luci-app-mergen/htdocs/luci-static/mergen/mergen.js` (update — drag-drop, bulk ops)

---

### T039 - ASN Browser Page

**Status**: COMPLETED
**Priority**: P3 (Medium)
**Effort**: 3 days

**Description**:
ASN discovery tool: search, detail panel, prefix preview, one-click rule creation, comparison mode.

**Dependencies**: T034, T005

**Technical Details**:
- Conforming to PRD Section 8.3 specification
- Search: ASN number, organization name (RIPE + bgpview support), reverse lookup by IP
- Debounced search (300ms delay)
- ASN detail panel: organization, country, RIR, prefix counts, source provider
- Prefix list: paginated table, v4/v6 filter, sorting
- [Add Rule for This ASN]: interface selection dropdown, one-click rule creation
- Comparison mode: multiple ASNs side by side, common prefix highlighting

**Success Criteria**:
1. Search by ASN number works
2. Organization name search returns results
3. Detail panel displays all information
4. Prefix list is paginated and filterable
5. One-click rule creation works
6. Comparison mode highlights common prefixes

**Files to Touch**:
- `luci-app-mergen/luasrc/model/cbi/mergen-asn-browser.lua` (new)
- `luci-app-mergen/luasrc/view/mergen/asn-browser.htm` (new)
- `luci-app-mergen/htdocs/luci-static/mergen/mergen.js` (update — search, compare)

---

### T040 - Interfaces & Logs Pages

**Status**: COMPLETED
**Priority**: P3 (Medium)
**Effort**: 3 days

> **Note**: This task covers two full LuCI pages (Interfaces + Logs). If scope proves too large during implementation, consider splitting into T040a (Interfaces, ~2 days) and T040b (Logs, ~2 days).

**Description**:
Interface status / health check page and live log viewer / filtering page.

**Dependencies**: T034

**Technical Details**:
- **Interfaces page** (PRD Section 8.4):
  - Interface list: name, type, status, IP, gateway, Mergen rule/prefix count
  - Detail panel: assigned rules, routing table, nft set contents
  - Connectivity test: [Ping Gateway], [Traceroute]
  - Health check: ping results, latency, packet loss
  - Up/down history (last 24 hours)
- **Logs page** (PRD Section 8.6):
  - Live log stream: auto-scroll via XHR polling (luci-mod-rpc)
  - Filtering: log level, component, rule name, time range, regex
  - Log detail panel: related context information
  - Export: download as .log file
  - Generate diagnostics bundle

**Success Criteria**:
1. Interface list displays all network interfaces
2. Ping test works and results are shown
3. Log stream updates in real-time
4. Filtering returns correct results
5. Log download works

**Files to Touch**:
- `luci-app-mergen/luasrc/model/cbi/mergen-interfaces.lua` (new)
- `luci-app-mergen/luasrc/view/mergen/interfaces.htm` (new)
- `luci-app-mergen/luasrc/model/cbi/mergen-logs.lua` (new)
- `luci-app-mergen/luasrc/view/mergen/logs.htm` (new)

---

### T041 - Advanced Settings Full & Provider Advanced

**Status**: COMPLETED
**Priority**: P3 (Medium)
**Effort**: 2 days

**Description**:
Advanced settings full version and provider settings advanced features.

**Dependencies**: T037

**Technical Details**:
- **Advanced settings — full** (PRD Section 8.7):
  - Rollback watchdog duration
  - Safe mode configuration (ping target, active/inactive)
  - API timeout and parallel query
  - [Flush All Routes]
  - [Factory Reset]
  - [Backup Configuration] / [Restore]
  - Version information
- **Provider settings — advanced** (PRD Section 8.5):
  - Drag-and-drop priority ordering
  - Success rate and average response time indicator
  - Fallback strategy selection
  - [Clear All Cache], [Test All]

**Success Criteria**:
1. Backup/restore works (UCI config download/upload)
2. Flush works (all routes are cleared)
3. Provider drag-and-drop ordering works
4. Provider test button shows results
5. All setting changes are saved to UCI

**Files to Touch**:
- `luci-app-mergen/luasrc/model/cbi/mergen-advanced.lua` (update)
- `luci-app-mergen/luasrc/view/mergen/advanced.htm` (update)
- `luci-app-mergen/luasrc/model/cbi/mergen-providers.lua` (update)
- `luci-app-mergen/luasrc/view/mergen/providers.htm` (update)

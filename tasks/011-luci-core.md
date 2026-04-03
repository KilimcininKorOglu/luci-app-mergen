# F011 - LuCI Core Pages

## Description

luci-app-mergen package infrastructure, RPC backend and 4 core LuCI pages: Overview, Rules, Provider Settings, Advanced Settings.

**PRD Reference**: Section 8.1, 8.2, 8.5, 8.7, 9 (Phase 4 — LuCI Core Pages)

## Tasks

### T034 - LuCI Package Scaffold & RPC Backend

**Status**: NOT_STARTED
**Priority**: P2 (High)
**Effort**: 2.5 days

**Description**:
luci-app-mergen package structure, LuCI menu integration and RPC access layer for mergen commands.

**Dependencies**: T010

**Technical Details**:
- LuCI1 (Lua/CBI) architecture (PRD Section 8 — deliberate choice)
- Package structure: `luci-app-mergen/` hierarchy from PRD Section 9
  - `luasrc/controller/mergen.lua`: URL routing, menu definition
  - `luasrc/model/cbi/`: CBI model files
  - `luasrc/view/mergen/`: View templates (.htm)
  - `htdocs/luci-static/mergen/`: CSS/JS files
  - `po/`: i18n files (en, tr)
- LuCI menu: Services → Mergen
- RPC backend: access to mergen CLI commands via `luci-mod-rpc` or `ubus`
  - `mergen_rpc_list()`, `mergen_rpc_apply()`, `mergen_rpc_status()`, etc.
- Makefile: OpenWrt buildroot LuCI package standard

**Success Criteria**:
1. `opkg install luci-app-mergen` package installs successfully
2. "Services → Mergen" appears in the LuCI menu
3. `mergen list` output is retrieved from the RPC backend
4. CSS/JS files load correctly
5. busted unit tests pass

**Files to Touch**:
- `luci-app-mergen/Makefile` (new)
- `luci-app-mergen/luasrc/controller/mergen.lua` (new)
- `luci-app-mergen/htdocs/luci-static/mergen/mergen.css` (new)
- `luci-app-mergen/htdocs/luci-static/mergen/mergen.js` (new)
- `luci-app-mergen/po/en/mergen.po` (new)
- `luci-app-mergen/po/tr/mergen.po` (new)

---

### T035 - Overview Page

**Status**: NOT_STARTED
**Priority**: P2 (High)
**Effort**: 2 days

**Description**:
Status cards, active rules summary table, quick actions and recent operations feed.

**Dependencies**: T034

**Technical Details**:
- Layout conforming to PRD Section 8.1 wireframe
- Status cards: daemon status (green/red/yellow), total rules, total prefixes, last sync, next sync
- Active rules table: name, type, target, interface, prefix count, status badge
- Quick actions: [Apply All], [Update Prefixes], [Restart Daemon]
- Last 10 operations feed (filtered from syslog)
- Auto-refresh: status update via XHR polling

**Success Criteria**:
1. All status cards are visible when the page loads
2. Rules table is populated with current data
3. Quick action buttons work
4. Recent operations feed shows real log data
5. Responsive design (mobile-friendly)

**Files to Touch**:
- `luci-app-mergen/luasrc/model/cbi/mergen.lua` (new — overview model)
- `luci-app-mergen/luasrc/view/mergen/overview.htm` (new)

---

### T036 - Rules Page (Basic CRUD)

**Status**: NOT_STARTED
**Priority**: P2 (High)
**Effort**: 3 days

**Description**:
Rule listing, adding, editing, deleting and validation. Core functionality of PRD Section 8.2.

**Dependencies**: T034

**Technical Details**:
- Rules list table: status toggle, name, type, target, interface, prefix, priority, actions
- New rule form:
  - Rule name (uniqueness validation)
  - Rule type (ASN/IP radio button)
  - ASN input (comma-separated, instant validation)
  - IP/CIDR input (one per line)
  - Target interface (dropdown — system interfaces)
  - Priority (numeric, default: 100)
- Editing: Inline or modal form
- Deletion: Confirmation dialog
- Status toggle: Rule active/inactive switch

**Success Criteria**:
1. Rules list displays all rules in table format
2. New rules can be added (form validation works)
3. Existing rules can be edited
4. Rules can be deleted (after confirmation)
5. Status toggle works
6. Invalid input is rejected (ASN, IP format)

**Files to Touch**:
- `luci-app-mergen/luasrc/model/cbi/mergen-rules.lua` (new)
- `luci-app-mergen/luasrc/view/mergen/rules.htm` (new)

---

### T037 - Provider Settings & Advanced Settings Pages (Basic)

**Status**: NOT_STARTED
**Priority**: P3 (Medium)
**Effort**: 2.5 days

**Description**:
Provider settings (list, toggle, per-provider forms) and advanced settings (routing table, engine, IPv6, limits).

**Dependencies**: T034

**Technical Details**:
- **Provider settings** (PRD Section 8.5):
  - Provider list: name, status toggle, priority, last query time
  - Per-provider forms: API URL, timeout, rate limit (RIPE, bgp.tools, bgpview, MaxMind, RouteViews, IRR)
  - MaxMind specific: DB path, license key
- **Advanced settings** (PRD Section 8.7):
  - Routing table number
  - Packet matching engine (nftables/ipset) selection
  - IPv6 toggle
  - Prefix limit settings
  - Update interval

**Success Criteria**:
1. Provider list displays all providers
2. Provider active/inactive toggle works
3. Per-provider settings forms are saved (UCI)
4. Advanced settings are saved and take effect
5. RPC backend integration tests pass

**Files to Touch**:
- `luci-app-mergen/luasrc/model/cbi/mergen-providers.lua` (new)
- `luci-app-mergen/luasrc/model/cbi/mergen-advanced.lua` (new)
- `luci-app-mergen/luasrc/view/mergen/providers.htm` (new)
- `luci-app-mergen/luasrc/view/mergen/advanced.htm` (new)

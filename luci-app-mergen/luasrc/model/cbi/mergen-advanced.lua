-- Mergen Advanced Settings CBI Model (PRD Section 8.7)
-- UCI-bound form for global/advanced configuration
-- Maps to mergen.global UCI section

local util = require "luci.util"

m = Map("mergen", translate("Mergen Advanced Settings"),
	translate("Routing table, packet engine, IPv6, performance limits, "
	.. "security and maintenance settings."))

-- ══════════════════════════════════════════════════════════
-- Global Section
-- ══════════════════════════════════════════════════════════

s = m:section(NamedSection, "global", "global", translate("Global Settings"))
s.addremove = false

-- Master enable
en = s:option(Flag, "enabled", translate("Enabled"))
en.default = "1"
en.rmempty = false

-- ── Routing Table Settings ─────────────────────────────

s:tab("routing", translate("Routing"))

rt = s:taboption("routing", Value, "default_table",
	translate("Routing Table Number"))
rt.default = "100"
rt.datatype = "range(1,252)"
rt.placeholder = "100"

rp = s:taboption("routing", Value, "rule_priority_start",
	translate("ip rule Priority Start"))
rp.default = "100"
rp.datatype = "range(1,32000)"
rp.placeholder = "100"

md = s:taboption("routing", ListValue, "mode",
	translate("Operating Mode"))
md:value("standalone", translate("Standalone") .. " (" .. translate("recommended") .. ")")
md:value("mwan3", translate("mwan3 Integration"))
md.default = "standalone"

-- ── Packet Engine ──────────────────────────────────────

s:tab("engine", translate("Packet Engine"))

se = s:taboption("engine", ListValue, "set_type",
	translate("Packet Matching Engine"))
se:value("nftables", translate("nftables") .. " (" .. translate("recommended") .. ")")
se:value("ipset", translate("ipset") .. " (" .. translate("legacy") .. ")")
se.default = "nftables"

-- ── IPv6 ───────────────────────────────────────────────

s:tab("ipv6", translate("IPv6"))

v6 = s:taboption("ipv6", Flag, "ipv6_enabled",
	translate("Enable IPv6"))
v6.default = "0"

v6t = s:taboption("ipv6", ListValue, "ipv6_table_mode",
	translate("IPv6 Table Mode"))
v6t:value("shared", translate("Shared table with IPv4"))
v6t:value("separate", translate("Separate IPv6 table"))
v6t.default = "shared"
v6t:depends("ipv6_enabled", "1")

-- ── Performance ────────────────────────────────────────

s:tab("performance", translate("Performance"))

pl = s:taboption("performance", Value, "prefix_limit",
	translate("Max Prefix Limit (per rule)"))
pl.default = "10000"
pl.datatype = "uinteger"
pl.placeholder = "10000"

tl = s:taboption("performance", Value, "total_prefix_limit",
	translate("Total Prefix Limit (all rules)"))
tl.default = "50000"
tl.datatype = "uinteger"
tl.placeholder = "50000"

ui = s:taboption("performance", Value, "update_interval",
	translate("Update Interval (seconds)"))
ui.default = "86400"
ui.datatype = "uinteger"
ui.placeholder = "86400"

at = s:taboption("performance", Value, "api_timeout",
	translate("API Timeout (seconds)"))
at.default = "30"
at.datatype = "range(1,120)"
at.placeholder = "30"

pq = s:taboption("performance", Value, "parallel_queries",
	translate("Parallel Query Limit"))
pq.default = "2"
pq.datatype = "range(1,10)"
pq.placeholder = "2"

-- ── Security ───────────────────────────────────────────

s:tab("security", translate("Security"))

wt = s:taboption("security", Value, "watchdog_timeout",
	translate("Rollback Watchdog Timeout (seconds)"))
wt.default = "60"
wt.datatype = "range(10,600)"
wt.placeholder = "60"

pt = s:taboption("security", Value, "ping_target",
	translate("Safe Mode Ping Target"))
pt.default = "8.8.8.8"
pt.datatype = "string"
pt.placeholder = "8.8.8.8"

-- ── Logging ────────────────────────────────────────────

s:tab("logging", translate("Logging"))

ll = s:taboption("logging", ListValue, "log_level",
	translate("Log Level"))
ll:value("debug", "Debug")
ll:value("info", "Info")
ll:value("warning", "Warning")
ll:value("error", "Error")
ll.default = "info"

-- ══════════════════════════════════════════════════════════
-- Maintenance Actions (SimpleSection for buttons)
-- ══════════════════════════════════════════════════════════

mt = m:section(SimpleSection, nil,
	translate("Maintenance operations for Mergen system."))

mt.template = "mergen/advanced-maintenance"

return m

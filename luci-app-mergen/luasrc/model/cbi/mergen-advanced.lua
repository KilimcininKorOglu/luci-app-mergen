-- Mergen Advanced Settings CBI Model
-- UCI-bound form for global/advanced configuration
-- Maps to mergen.global UCI section

m = Map("mergen", translate("Mergen Advanced Settings"),
	translate("Configure routing table, packet engine, IPv6, limits and update settings."))

-- Global section (NamedSection targets the specific "global" section)
s = m:section(NamedSection, "global", "global", translate("Global Settings"))
s.addremove = false

-- Enabled
en = s:option(Flag, "enabled", translate("Enabled"))
en.default = "1"
en.rmempty = false

-- Routing table number
rt = s:option(Value, "default_table", translate("Routing Table"))
rt.default = "100"
rt.datatype = "range(1,252)"
rt.placeholder = "100"

-- Packet matching engine
se = s:option(ListValue, "set_type", translate("Packet Engine"))
se:value("nftables", translate("nftables"))
se:value("ipset", translate("ipset"))
se.default = "nftables"

-- IPv6 toggle
v6 = s:option(Flag, "ipv6_enabled", translate("Enable IPv6"))
v6.default = "0"

-- Prefix limit
pl = s:option(Value, "prefix_limit", translate("Prefix Limit"))
pl.default = "10000"
pl.datatype = "uinteger"
pl.placeholder = "10000"

-- Update interval (seconds)
ui = s:option(Value, "update_interval", translate("Update Interval"))
ui.default = "86400"
ui.datatype = "uinteger"
ui.placeholder = "86400"

-- Fallback strategy
fs = s:option(ListValue, "fallback_strategy", translate("Fallback Strategy"))
fs:value("sequential", translate("Sequential"))
fs:value("parallel", translate("Parallel"))
fs:value("cache_only", translate("Cache Only"))
fs.default = "sequential"

-- Log level
ll = s:option(ListValue, "log_level", translate("Log Level"))
ll:value("debug", "Debug")
ll:value("info", "Info")
ll:value("warning", "Warning")
ll:value("error", "Error")
ll.default = "info"

return m

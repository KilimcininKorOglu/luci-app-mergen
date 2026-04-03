-- Mergen Providers CBI Model (PRD Section 8.5)
-- UCI-bound form for provider configuration and general cache settings
-- Each provider section in UCI maps to a row in the provider table

local util = require "luci.util"

m = Map("mergen", translate("Mergen Providers"),
	translate("Configure ASN resolution data providers, fallback strategy and cache settings."))

-- ══════════════════════════════════════════════════════════
-- Provider List (TypedSection)
-- ══════════════════════════════════════════════════════════

s = m:section(TypedSection, "provider", translate("Providers"))
s.addremove = true
s.anonymous = false
s.template = "cbi/tblsection"
s.sortable = true

-- Enabled toggle
en = s:option(Flag, "enabled", translate("Enabled"))
en.default = "1"
en.rmempty = false

-- Priority (lower = higher priority)
pr = s:option(Value, "priority", translate("Priority"))
pr.default = "10"
pr.datatype = "uinteger"
pr.placeholder = "10"

-- API URL
url = s:option(Value, "url", translate("API URL"))
url.placeholder = "https://..."
url.datatype = "string"
url.optional = true

function url.validate(self, value)
	if not value or value == "" then return value end
	-- Enforce HTTPS
	if not value:match("^https://") then
		return nil, translate("API URL must use HTTPS")
	end
	return value
end

-- Timeout (seconds)
to = s:option(Value, "timeout", translate("Timeout"))
to.default = "30"
to.datatype = "range(1,120)"
to.placeholder = "30"

-- Rate limit (requests/minute, 0 = unlimited)
rl = s:option(Value, "rate_limit", translate("Rate Limit"))
rl.default = "0"
rl.datatype = "uinteger"
rl.placeholder = "0"

-- Whois server (for IRR/RADB provider)
ws = s:option(Value, "whois_server", translate("Whois Server"))
ws.placeholder = "whois.radb.net"
ws.datatype = "string"
ws.optional = true

-- Database path (for MaxMind provider)
db = s:option(Value, "db_path", translate("DB Path"))
db.placeholder = "/usr/share/mergen/GeoLite2-ASN.mmdb"
db.datatype = "string"
db.optional = true

-- ══════════════════════════════════════════════════════════
-- General Provider Settings (global section)
-- ══════════════════════════════════════════════════════════

g = m:section(NamedSection, "global", "global",
	translate("General Provider Settings"))
g.addremove = false

-- Fallback strategy
fs = g:option(ListValue, "fallback_strategy", translate("Fallback Strategy"))
fs:value("sequential", translate("Sequential"))
fs:value("parallel", translate("Parallel"))
fs:value("cache_only", translate("Cache Only"))
fs.default = "sequential"

-- Cache TTL (update interval)
ci = g:option(Value, "update_interval", translate("Cache TTL (seconds)"))
ci.default = "86400"
ci.datatype = "uinteger"
ci.placeholder = "86400"

return m

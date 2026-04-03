-- Mergen Providers CBI Model
-- UCI-bound form for provider configuration
-- Each provider section in UCI maps to a row in this table

m = Map("mergen", translate("Mergen Providers"),
	translate("Configure ASN resolution data providers and their settings."))

-- Provider section
s = m:section(TypedSection, "provider", translate("Providers"))
s.addremove = true
s.anonymous = false
s.template = "cbi/tblsection"

-- Provider enabled toggle
en = s:option(Flag, "enabled", translate("Enabled"))
en.default = "1"
en.rmempty = false

-- Priority
pr = s:option(Value, "priority", translate("Priority"))
pr.default = "10"
pr.datatype = "uinteger"

-- API URL
url = s:option(Value, "url", translate("API URL"))
url.placeholder = "https://stat.ripe.net/data/announced-prefixes/data.json"
url.datatype = "string"

-- Timeout (seconds)
to = s:option(Value, "timeout", translate("Timeout"))
to.default = "30"
to.datatype = "range(1,120)"
to.placeholder = "30"

-- Rate limit (requests/minute)
rl = s:option(Value, "rate_limit", translate("Rate Limit"))
rl.default = "0"
rl.datatype = "uinteger"
rl.placeholder = "0"

return m

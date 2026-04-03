-- Mergen Rules CBI Model
-- UCI-bound form for managing routing rules
-- LuCI1 CBI architecture: form fields auto-bind to UCI config

local sys = require "luci.sys"
local util = require "luci.util"

m = Map("mergen", translate("Mergen Rules"),
	translate("Manage ASN/IP based policy routing rules."))

-- Rules section (TypedSection iterates over all "rule" sections)
s = m:section(TypedSection, "rule", translate("Rules"))
s.addremove = true
s.anonymous = false
s.template = "cbi/tblsection"
s.extedit = false

-- Rule name (section identifier)
nm = s:option(Value, "name", translate("Rule Name"))
nm.rmempty = false
nm.datatype = "string"
function nm.validate(self, value)
	if not value or value == "" then
		return nil, translate("Rule name is required")
	end
	if not value:match("^[a-zA-Z0-9_-]+$") then
		return nil, translate("Rule name must be alphanumeric (plus - and _)")
	end
	return value
end

-- Rule type (ASN or IP)
tp = s:option(ListValue, "type", translate("Rule Type"))
tp:value("asn", "ASN")
tp:value("ip", "IP/CIDR")
tp.default = "asn"

-- ASN target (visible when type=asn)
asn = s:option(Value, "asn", translate("ASN"))
asn.placeholder = "13335"
asn.datatype = "string"
asn:depends("type", "asn")
function asn.validate(self, value)
	if not value or value == "" then return nil end
	-- Allow comma-separated ASNs
	for item in value:gmatch("[^,]+") do
		local num = item:match("^%s*(%d+)%s*$")
		if not num then
			return nil, translate("Invalid ASN number")
		end
	end
	return value
end

-- IP target (visible when type=ip)
ip = s:option(Value, "ip", translate("IP/CIDR"))
ip.placeholder = "10.0.0.0/8"
ip.datatype = "string"
ip:depends("type", "ip")

-- Via interface
via = s:option(ListValue, "via", translate("Interface"))
-- Populate with system network interfaces
local ifaces = sys.net.devices() or {}
for _, iface in ipairs(ifaces) do
	if iface ~= "lo" then
		via:value(iface, iface)
	end
end
via.rmempty = false

-- Priority
pr = s:option(Value, "priority", translate("Priority"))
pr.default = "100"
pr.datatype = "range(1,32000)"
pr.placeholder = "100"

-- Enabled toggle
en = s:option(Flag, "enabled", translate("Enabled"))
en.default = "1"
en.rmempty = false

return m

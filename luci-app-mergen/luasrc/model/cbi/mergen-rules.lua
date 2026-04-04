-- Mergen Rules CBI Model
-- UCI-bound form for managing routing rules (PRD Section 8.2)
-- LuCI1 CBI architecture: form fields auto-bind to UCI config

local sys = require "luci.sys"
local util = require "luci.util"
local uci = require "luci.model.uci".cursor()

m = Map("mergen", translate("Mergen Rules"),
	translate("Manage ASN/IP based policy routing rules. "
	.. "Rules define which traffic is routed through which interface."))

-- ── Rules Section ──────────────────────────────────────
-- TypedSection iterates all "rule" sections in /etc/config/mergen

s = m:section(TypedSection, "rule", translate("Rules"))
s.addremove = true
s.anonymous = false
s.template = "cbi/tblsection"
s.extedit = false
s.sortable = true

-- Section removal confirmation
function s.remove(self, section)
	return TypedSection.remove(self, section)
end

-- ── Enabled toggle ─────────────────────────────────────
en = s:option(Flag, "enabled", translate("Enabled"))
en.default = "1"
en.rmempty = false

-- ── Rule name ──────────────────────────────────────────
nm = s:option(Value, "name", translate("Rule Name"))
nm.rmempty = false
nm.datatype = "string"
nm.placeholder = "my-rule"

function nm.validate(self, value)
	if not value or value == "" then
		return nil, translate("Rule name is required")
	end
	if not value:match("^[a-zA-Z0-9_-]+$") then
		return nil, translate("Rule name: only letters, digits, dash and underscore allowed")
	end
	if #value > 32 then
		return nil, translate("Rule name must be 32 characters or less")
	end
	return value
end

-- ── Rule type ──────────────────────────────────────────
tp = s:option(ListValue, "type", translate("Rule Type"))
tp:value("asn", "ASN")
tp:value("ip", "IP/CIDR")
tp.default = "asn"

-- ── ASN target (conditional: type=asn) ─────────────────
asn = s:option(Value, "asn", translate("ASN"))
asn.placeholder = "13335"
asn.datatype = "string"
asn:depends("type", "asn")

function asn.validate(self, value)
	if not value or value == "" then return nil end
	-- Allow comma or space separated ASNs
	for item in value:gmatch("[^,%s]+") do
		local num = item:match("^(%d+)$")
		if not num then
			return nil, translate("Invalid ASN number: ") .. item
		end
		local asn_num = tonumber(num)
		if asn_num < 1 or asn_num > 4294967295 then
			return nil, translate("ASN out of range: ") .. num
		end
	end
	return value
end

-- ── IP/CIDR target (conditional: type=ip) ──────────────
ip = s:option(Value, "ip", translate("IP/CIDR"))
ip.placeholder = "10.0.0.0/8"
ip.datatype = "string"
ip:depends("type", "ip")

function ip.validate(self, value)
	if not value or value == "" then return nil end
	-- Allow comma or space separated CIDRs
	for item in value:gmatch("[^,%s]+") do
		-- IPv4 CIDR: a.b.c.d/N
		local ipv4 = item:match("^(%d+%.%d+%.%d+%.%d+/%d+)$")
		-- IPv6 CIDR: xxxx::/N
		local ipv6 = item:match("^([%x:]+/%d+)$")
		if not ipv4 and not ipv6 then
			return nil, translate("Invalid CIDR format: ") .. item
		end
	end
	return value
end

-- ── Via interface ──────────────────────────────────────
via = s:option(ListValue, "via", translate("Interface"))
via.rmempty = false

-- Populate with system network interfaces
local ifaces = sys.net.devices() or {}
for _, iface in ipairs(ifaces) do
	if iface ~= "lo" then
		via:value(iface, iface)
	end
end

-- Also add UCI-defined interfaces that may not be up yet
uci:foreach("network", "interface", function(s)
	local ifname = s[".name"]
	if ifname and ifname ~= "loopback" then
		via:value(ifname, ifname .. " (logical)")
	end
end)

-- ── Priority ───────────────────────────────────────────
pr = s:option(Value, "priority", translate("Priority"))
pr.default = "100"
pr.datatype = "range(1,32000)"
pr.placeholder = "100"

-- ── Fallback Interface ─────────────────────────────────
fb = s:option(ListValue, "fallback", translate("Fallback Interface"))
fb.optional = true
fb.rmempty = true
fb:value("", translate("-- None --"))
for _, iface in ipairs(ifaces) do
	if iface ~= "lo" then
		fb:value(iface, iface)
	end
end
uci:foreach("network", "interface", function(s)
	local ifname = s[".name"]
	if ifname and ifname ~= "loopback" then
		fb:value(ifname, ifname .. " (logical)")
	end
end)

-- ── Tags ───────────────────────────────────────────────
tg = s:option(Value, "tag", translate("Tags"))
tg.placeholder = "vpn, office"
tg.datatype = "string"
tg.optional = true

return m

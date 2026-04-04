-- Mergen LuCI Controller
-- URL routing and menu definition for luci-app-mergen
-- LuCI1 (Lua/CBI) architecture

module("luci.controller.mergen", package.seeall)

function index()
	-- Main menu entry: Services > Mergen
	local e = entry({"admin", "services", "mergen"}, firstchild(), _("Mergen"), 90)
	e.dependent = false
	e.acl_depends = { "luci-app-mergen" }

	-- Sub-pages
	entry({"admin", "services", "mergen", "overview"},
		template("mergen/overview"), _("Overview"), 10)

	entry({"admin", "services", "mergen", "rules"},
		cbi("mergen-rules"), _("Rules"), 20)

	entry({"admin", "services", "mergen", "providers"},
		cbi("mergen-providers"), _("Providers"), 30)

	entry({"admin", "services", "mergen", "advanced"},
		cbi("mergen-advanced"), _("Advanced"), 40)

	entry({"admin", "services", "mergen", "asn-browser"},
		template("mergen/asn-browser"), _("ASN Browser"), 25)

	entry({"admin", "services", "mergen", "interfaces"},
		template("mergen/interfaces"), _("Interfaces"), 35)

	entry({"admin", "services", "mergen", "logs"},
		template("mergen/logs"), _("Logs"), 45)

	-- RPC endpoints (JSON API)
	entry({"admin", "services", "mergen", "rpc", "status"},
		call("rpc_status")).leaf = true

	entry({"admin", "services", "mergen", "rpc", "list"},
		call("rpc_list")).leaf = true

	entry({"admin", "services", "mergen", "rpc", "apply"},
		post("rpc_apply")).leaf = true

	entry({"admin", "services", "mergen", "rpc", "update"},
		post("rpc_update")).leaf = true

	entry({"admin", "services", "mergen", "rpc", "flush"},
		post("rpc_flush")).leaf = true

	entry({"admin", "services", "mergen", "rpc", "toggle"},
		post("rpc_toggle")).leaf = true

	entry({"admin", "services", "mergen", "rpc", "restart"},
		post("rpc_restart")).leaf = true

	entry({"admin", "services", "mergen", "rpc", "validate"},
		call("rpc_validate")).leaf = true

	entry({"admin", "services", "mergen", "rpc", "clone"},
		post("rpc_clone")).leaf = true

	entry({"admin", "services", "mergen", "rpc", "bulk"},
		post("rpc_bulk")).leaf = true

	entry({"admin", "services", "mergen", "rpc", "export_rules"},
		call("rpc_export_rules")).leaf = true

	entry({"admin", "services", "mergen", "rpc", "reorder"},
		post("rpc_reorder")).leaf = true

	entry({"admin", "services", "mergen", "rpc", "resolve"},
		call("rpc_resolve")).leaf = true

	entry({"admin", "services", "mergen", "rpc", "add_rule"},
		post("rpc_add_rule")).leaf = true

	entry({"admin", "services", "mergen", "rpc", "interfaces"},
		call("rpc_interfaces")).leaf = true

	entry({"admin", "services", "mergen", "rpc", "ping"},
		post("rpc_ping")).leaf = true

	entry({"admin", "services", "mergen", "rpc", "logs"},
		call("rpc_logs")).leaf = true

	entry({"admin", "services", "mergen", "rpc", "diag_bundle"},
		call("rpc_diag_bundle")).leaf = true

	entry({"admin", "services", "mergen", "rpc", "version"},
		call("rpc_version")).leaf = true

	entry({"admin", "services", "mergen", "rpc", "factory_reset"},
		post("rpc_factory_reset")).leaf = true

	entry({"admin", "services", "mergen", "rpc", "restore_config"},
		post("rpc_restore_config")).leaf = true

	entry({"admin", "services", "mergen", "rpc", "clear_cache"},
		post("rpc_clear_cache")).leaf = true

	entry({"admin", "services", "mergen", "rpc", "test_provider"},
		post("rpc_test_provider")).leaf = true

	entry({"admin", "services", "mergen", "rpc", "traffic_stats"},
		call("rpc_traffic_stats")).leaf = true
end

-- Helper: execute mergen CLI command and return output
local function mergen_exec(cmd)
	local util = require "luci.util"
	local result = util.exec("/usr/bin/mergen " .. cmd .. " 2>&1")
	return result or ""
end

-- Helper: send JSON response
local function json_response(data)
	local http = require "luci.http"
	local json = require "luci.jsonc"
	http.prepare_content("application/json")
	http.write(json.stringify(data))
end

-- RPC: Get Mergen status (daemon, rules, cache)
function rpc_status()
	local output = mergen_exec("status")
	json_response({
		success = true,
		output = output
	})
end

-- RPC: List all rules
function rpc_list()
	local output = mergen_exec("export --format json")
	local json = require "luci.jsonc"
	local data = json.parse(output)
	if data then
		json_response({
			success = true,
			rules = data.rules or {}
		})
	else
		json_response({
			success = true,
			output = mergen_exec("list")
		})
	end
end

-- RPC: Apply rules
function rpc_apply()
	local output = mergen_exec("apply")
	json_response({
		success = true,
		output = output
	})
end

-- RPC: Update prefix lists
function rpc_update()
	local output = mergen_exec("update --apply")
	json_response({
		success = true,
		output = output
	})
end

-- RPC: Flush all routes
function rpc_flush()
	local output = mergen_exec("flush --confirm")
	json_response({
		success = true,
		output = output
	})
end

-- RPC: Toggle rule (enable/disable)
function rpc_toggle()
	local http = require "luci.http"
	local name = http.formvalue("name")
	local action = http.formvalue("action")

	if not name or name == "" then
		json_response({ success = false, error = "Rule name required" })
		return
	end

	local cmd = (action == "disable") and "disable" or "enable"
	local output = mergen_exec(cmd .. " " .. name)
	json_response({
		success = true,
		output = output
	})
end

-- RPC: Restart daemon
function rpc_restart()
	local util = require "luci.util"
	util.exec("/etc/init.d/mergen restart 2>&1")
	json_response({
		success = true,
		output = "Daemon restarted"
	})
end

-- RPC: Validate configuration
function rpc_validate()
	local output = mergen_exec("validate --check-providers")
	json_response({
		success = true,
		output = output
	})
end

-- RPC: Clone a rule
function rpc_clone()
	local http = require "luci.http"
	local uci = require "luci.model.uci".cursor()
	local source = http.formvalue("source")
	local new_name = http.formvalue("new_name")

	if not source or source == "" then
		json_response({ success = false, error = "Source rule name required" })
		return
	end
	if not new_name or new_name == "" then
		json_response({ success = false, error = "New rule name required" })
		return
	end

	-- Validate new_name format
	if not new_name:match("^[a-zA-Z0-9_-]+$") or #new_name > 32 then
		json_response({ success = false, error = "Invalid rule name format" })
		return
	end

	-- Check source exists
	local src_data = nil
	uci:foreach("mergen", "rule", function(s)
		if s[".name"] == source then
			src_data = s
		end
	end)

	if not src_data then
		json_response({ success = false, error = "Source rule not found" })
		return
	end

	-- Check new_name doesn't conflict
	local exists = false
	uci:foreach("mergen", "rule", function(s)
		if s[".name"] == new_name then
			exists = true
		end
	end)

	if exists then
		json_response({ success = false, error = "Rule name already exists" })
		return
	end

	-- Create new section with same values
	uci:section("mergen", "rule", new_name)
	local copy_keys = { "enabled", "name", "type", "asn", "ip", "via", "priority", "tag" }
	for _, key in ipairs(copy_keys) do
		if src_data[key] then
			uci:set("mergen", new_name, key, src_data[key])
		end
	end
	-- Override name field to the new name
	uci:set("mergen", new_name, "name", new_name)
	uci:commit("mergen")

	json_response({
		success = true,
		output = "Rule cloned: " .. source .. " -> " .. new_name
	})
end

-- RPC: Bulk operations (enable/disable/delete)
function rpc_bulk()
	local http = require "luci.http"
	local uci = require "luci.model.uci".cursor()
	local action = http.formvalue("action")
	local rules_str = http.formvalue("rules") or ""

	if not action or action == "" then
		json_response({ success = false, error = "Action required" })
		return
	end

	-- Parse comma-separated rule names
	local rules = {}
	for name in rules_str:gmatch("[^,]+") do
		name = name:match("^%s*(.-)%s*$") -- trim
		if name ~= "" then
			rules[#rules + 1] = name
		end
	end

	if #rules == 0 then
		json_response({ success = false, error = "No rules specified" })
		return
	end

	local count = 0
	for _, rule_name in ipairs(rules) do
		if action == "enable" then
			uci:set("mergen", rule_name, "enabled", "1")
			count = count + 1
		elseif action == "disable" then
			uci:set("mergen", rule_name, "enabled", "0")
			count = count + 1
		elseif action == "delete" then
			uci:delete("mergen", rule_name)
			count = count + 1
		end
	end

	if count > 0 then
		uci:commit("mergen")
	end

	json_response({
		success = true,
		output = action .. ": " .. count .. " rules affected"
	})
end

-- RPC: Export rules as JSON
function rpc_export_rules()
	local output = mergen_exec("export --format json")
	local json = require "luci.jsonc"
	local data = json.parse(output)
	if data then
		json_response({
			success = true,
			rules = data.rules or data
		})
	else
		json_response({
			success = false,
			error = "Failed to export rules"
		})
	end
end

-- RPC: Reorder rules (update priorities)
function rpc_reorder()
	local http = require "luci.http"
	local json = require "luci.jsonc"
	local uci = require "luci.model.uci".cursor()
	local order_str = http.formvalue("order") or ""

	-- Parse JSON array of {name, priority} objects
	local order = json.parse(order_str)
	if not order or type(order) ~= "table" then
		json_response({ success = false, error = "Invalid order data" })
		return
	end

	for _, item in ipairs(order) do
		if item.name and item.priority then
			uci:set("mergen", item.name, "priority",
				tostring(item.priority))
		end
	end
	uci:commit("mergen")

	json_response({
		success = true,
		output = "Reordered " .. #order .. " rules"
	})
end

-- RPC: Resolve ASN prefixes (for ASN Browser)
function rpc_resolve()
	local http = require "luci.http"
	local json = require "luci.jsonc"
	local asn = http.formvalue("asn") or ""
	local provider = http.formvalue("provider") or ""

	-- Clean ASN input (strip AS/as prefix)
	asn = asn:gsub("^[Aa][Ss]", "")

	if asn == "" or not asn:match("^%d+$") then
		json_response({ success = false, error = "Valid ASN number required" })
		return
	end

	-- Build resolve command
	local cmd = "resolve " .. asn
	if provider ~= "" then
		cmd = cmd .. " --provider " .. provider
	end

	local output = mergen_exec(cmd)

	-- Parse the output into structured data
	local result = {
		asn = tonumber(asn),
		raw = output,
		prefixes_v4 = {},
		prefixes_v6 = {},
		provider = "",
		total_v4 = 0,
		total_v6 = 0
	}

	-- Extract provider name
	local prov = output:match("Provider:%s*(.-)%s*\n")
	if prov then result.provider = prov end

	-- Extract IPv4 prefixes
	local in_v4 = false
	local in_v6 = false
	for line in output:gmatch("[^\n]+") do
		if line:match("IPv4 Prefix") then
			in_v4 = true
			in_v6 = false
		elseif line:match("IPv6 Prefix") then
			in_v4 = false
			in_v6 = true
		elseif line:match("^%s*Toplam") or line:match("^%s*Total") then
			in_v4 = false
			in_v6 = false
		else
			local prefix = line:match("^%s*(%S+/%d+)")
			if prefix then
				if in_v4 then
					result.prefixes_v4[#result.prefixes_v4 + 1] = prefix
				elseif in_v6 then
					result.prefixes_v6[#result.prefixes_v6 + 1] = prefix
				end
			end
		end
	end

	result.total_v4 = #result.prefixes_v4
	result.total_v6 = #result.prefixes_v6

	json_response({
		success = true,
		result = result
	})
end

-- RPC: Quick add rule from ASN Browser
function rpc_add_rule()
	local http = require "luci.http"
	local uci = require "luci.model.uci".cursor()
	local name = http.formvalue("name") or ""
	local asn = http.formvalue("asn") or ""
	local via = http.formvalue("via") or ""

	if name == "" or asn == "" or via == "" then
		json_response({ success = false, error = "Name, ASN and interface required" })
		return
	end

	-- Validate name
	if not name:match("^[a-zA-Z0-9_-]+$") or #name > 32 then
		json_response({ success = false, error = "Invalid rule name format" })
		return
	end

	-- Check name doesn't exist
	local exists = false
	uci:foreach("mergen", "rule", function(s)
		if s[".name"] == name then
			exists = true
		end
	end)

	if exists then
		json_response({ success = false, error = "Rule name already exists" })
		return
	end

	-- Clean ASN
	asn = asn:gsub("^[Aa][Ss]", "")

	-- Create the rule
	uci:section("mergen", "rule", name)
	uci:set("mergen", name, "enabled", "1")
	uci:set("mergen", name, "name", name)
	uci:set("mergen", name, "type", "asn")
	uci:set("mergen", name, "asn", asn)
	uci:set("mergen", name, "via", via)
	uci:set("mergen", name, "priority", "100")
	uci:commit("mergen")

	json_response({
		success = true,
		output = "Rule created: " .. name .. " (AS" .. asn .. " via " .. via .. ")"
	})
end

-- RPC: Get interface details with Mergen context
function rpc_interfaces()
	local sys = require "luci.sys"
	local uci = require "luci.model.uci".cursor()
	local json = require "luci.jsonc"
	local util = require "luci.util"

	local result = {}
	local devs = sys.net.devices() or {}

	for _, dev in ipairs(devs) do
		if dev ~= "lo" then
			local info = {
				name = dev,
				status = "down",
				ip = "",
				gateway = "",
				rules = 0,
				prefixes = 0
			}

			-- Get IP address
			local addrs = sys.net.ipaddrs(dev)
			if addrs and #addrs > 0 then
				info.ip = addrs[1]
				info.status = "up"
			end

			-- Count Mergen rules targeting this interface
			uci:foreach("mergen", "rule", function(s)
				if s.via == dev and s.enabled == "1" then
					info.rules = info.rules + 1
				end
			end)

			result[#result + 1] = info
		end
	end

	-- Also add UCI logical interfaces
	uci:foreach("network", "interface", function(s)
		local ifname = s[".name"]
		if ifname and ifname ~= "loopback" then
			local found = false
			for _, r in ipairs(result) do
				if r.name == ifname then found = true; break end
			end

			if not found then
				local info = {
					name = ifname .. " (logical)",
					status = "unknown",
					ip = "",
					gateway = "",
					rules = 0,
					prefixes = 0
				}

				uci:foreach("mergen", "rule", function(rs)
					if rs.via == ifname and rs.enabled == "1" then
						info.rules = info.rules + 1
					end
				end)

				result[#result + 1] = info
			end
		end
	end)

	json_response({
		success = true,
		interfaces = result
	})
end

-- RPC: Ping a target (gateway connectivity test)
function rpc_ping()
	local http = require "luci.http"
	local util = require "luci.util"
	local target = http.formvalue("target") or ""
	local count = http.formvalue("count") or "4"
	local iface = http.formvalue("iface") or ""

	if target == "" then
		json_response({ success = false, error = "Target required" })
		return
	end

	-- Sanitize target (only allow IP addresses and hostnames)
	if not target:match("^[a-zA-Z0-9%.%-:]+$") then
		json_response({ success = false, error = "Invalid target format" })
		return
	end

	-- Sanitize count
	local cnt = tonumber(count)
	if not cnt or cnt < 1 or cnt > 10 then cnt = 4 end

	local cmd = "ping -c " .. cnt .. " -W 3"
	if iface ~= "" and iface:match("^[a-zA-Z0-9%-_]+$") then
		cmd = cmd .. " -I " .. iface
	end
	cmd = cmd .. " " .. target .. " 2>&1"

	local output = util.exec(cmd) or ""

	-- Parse ping results
	local transmitted = output:match("(%d+) packets transmitted")
	local received = output:match("(%d+) received") or output:match("(%d+) packets received")
	local loss = output:match("(%d+)%% packet loss")
	local rtt = output:match("rtt min/avg/max/mdev = ([%d%.]+)/([%d%.]+)/([%d%.]+)/([%d%.]+)")
	local rtt_min, rtt_avg, rtt_max = nil, nil, nil
	if rtt then
		rtt_min, rtt_avg, rtt_max = output:match("rtt min/avg/max/mdev = ([%d%.]+)/([%d%.]+)/([%d%.]+)")
	end

	json_response({
		success = true,
		target = target,
		transmitted = tonumber(transmitted) or 0,
		received = tonumber(received) or 0,
		loss = tonumber(loss) or 100,
		rtt_min = rtt_min,
		rtt_avg = rtt_avg,
		rtt_max = rtt_max,
		raw = output
	})
end

-- RPC: Get filtered Mergen logs
function rpc_logs()
	local http = require "luci.http"
	local util = require "luci.util"
	local lines = tonumber(http.formvalue("lines")) or 50
	local level = http.formvalue("level") or ""
	local filter = http.formvalue("filter") or ""

	if lines < 1 then lines = 50 end
	if lines > 500 then lines = 500 end

	-- Read from syslog (logread), filter for mergen entries
	local cmd = "logread -e mergen 2>/dev/null | tail -n " .. lines
	local output = util.exec(cmd) or ""

	-- Parse log lines into structured entries
	local entries = {}
	for line in output:gmatch("[^\n]+") do
		local timestamp = line:match("^(%S+ %S+ %S+ %S+)")
		local msg_level = line:match("mergen%[%d+%]: %[(%w+)%]") or "info"
		local message = line:match("mergen%[%d+%]: (.+)$") or line

		-- Apply level filter
		local include = true
		if level ~= "" then
			local levels = { debug = 1, info = 2, warning = 3, error = 4 }
			local req = levels[level] or 1
			local cur = levels[msg_level] or 2
			if cur < req then include = false end
		end

		-- Apply text filter
		if include and filter ~= "" then
			if not message:lower():find(filter:lower(), 1, true) then
				include = false
			end
		end

		if include then
			entries[#entries + 1] = {
				time = timestamp or "",
				level = msg_level,
				message = message
			}
		end
	end

	json_response({
		success = true,
		entries = entries,
		total = #entries
	})
end

-- RPC: Generate diagnostics bundle
function rpc_diag_bundle()
	local util = require "luci.util"
	local parts = {}

	parts[#parts + 1] = "=== Mergen Status ==="
	parts[#parts + 1] = mergen_exec("status")

	parts[#parts + 1] = "\n=== Mergen Rules ==="
	parts[#parts + 1] = mergen_exec("list")

	parts[#parts + 1] = "\n=== Mergen Validate ==="
	parts[#parts + 1] = mergen_exec("validate --check-providers")

	parts[#parts + 1] = "\n=== IP Rules ==="
	parts[#parts + 1] = util.exec("ip rule show 2>/dev/null") or ""

	parts[#parts + 1] = "\n=== IP Routes (table 100) ==="
	parts[#parts + 1] = util.exec("ip route show table 100 2>/dev/null") or ""

	parts[#parts + 1] = "\n=== nft Sets ==="
	parts[#parts + 1] = util.exec("nft list sets 2>/dev/null") or ""

	parts[#parts + 1] = "\n=== Recent Mergen Logs ==="
	parts[#parts + 1] = util.exec("logread -e mergen 2>/dev/null | tail -n 50") or ""

	json_response({
		success = true,
		bundle = table.concat(parts, "\n")
	})
end

-- RPC: Get version information
function rpc_version()
	local util = require "luci.util"
	local uci = require "luci.model.uci".cursor()

	local mergen_version = util.exec("/usr/bin/mergen version 2>/dev/null"):gsub("%s+$", "")
	if mergen_version == "" then mergen_version = "unknown" end

	local config_version = uci:get("mergen", "global", "config_version") or "1"
	local luci_version = "1.0.0"

	-- Read package version from opkg if available
	local pkg_version = util.exec(
		"opkg info luci-app-mergen 2>/dev/null | grep '^Version:'"
	):match("Version:%s*(.-)%s*$") or luci_version

	json_response({
		success = true,
		mergen_version = mergen_version,
		config_version = config_version,
		luci_version = pkg_version
	})
end

-- RPC: Factory reset (restore default UCI config)
function rpc_factory_reset()
	local uci = require "luci.model.uci".cursor()
	local util = require "luci.util"

	-- Delete all rule sections
	local rules = {}
	uci:foreach("mergen", "rule", function(s)
		rules[#rules + 1] = s[".name"]
	end)
	for _, name in ipairs(rules) do
		uci:delete("mergen", name)
	end

	-- Delete all provider sections
	local providers = {}
	uci:foreach("mergen", "provider", function(s)
		providers[#providers + 1] = s[".name"]
	end)
	for _, name in ipairs(providers) do
		uci:delete("mergen", name)
	end

	-- Reset global section to defaults
	uci:set("mergen", "global", "enabled", "1")
	uci:set("mergen", "global", "default_table", "100")
	uci:set("mergen", "global", "rule_priority_start", "100")
	uci:set("mergen", "global", "set_type", "nftables")
	uci:set("mergen", "global", "ipv6_enabled", "0")
	uci:set("mergen", "global", "prefix_limit", "10000")
	uci:set("mergen", "global", "total_prefix_limit", "50000")
	uci:set("mergen", "global", "update_interval", "86400")
	uci:set("mergen", "global", "api_timeout", "30")
	uci:set("mergen", "global", "parallel_queries", "2")
	uci:set("mergen", "global", "watchdog_timeout", "60")
	uci:set("mergen", "global", "ping_target", "8.8.8.8")
	uci:set("mergen", "global", "log_level", "info")
	uci:set("mergen", "global", "fallback_strategy", "sequential")
	uci:set("mergen", "global", "config_version", "1")
	uci:commit("mergen")

	-- Flush routes after reset
	mergen_exec("flush --confirm")

	json_response({
		success = true,
		output = "Factory reset completed. All rules and providers removed."
	})
end

-- RPC: Restore configuration from uploaded content
function rpc_restore_config()
	local http = require "luci.http"
	local nixio = require "nixio"
	local fs = require "nixio.fs"

	local config_data = http.formvalue("config_data") or ""

	if config_data == "" then
		json_response({ success = false, error = "No configuration data provided" })
		return
	end

	-- Validate it looks like a UCI config (basic sanity check)
	if not config_data:match("config%s+global") then
		json_response({
			success = false,
			error = "Invalid configuration format (missing global section)"
		})
		return
	end

	-- Write to /etc/config/mergen
	local ok = fs.writefile("/etc/config/mergen", config_data)
	if not ok then
		json_response({ success = false, error = "Failed to write configuration file" })
		return
	end

	json_response({
		success = true,
		output = "Configuration restored successfully. Reload the page to see changes."
	})
end

-- RPC: Clear all provider cache
function rpc_clear_cache()
	local util = require "luci.util"
	local fs = require "nixio.fs"

	-- Remove cache directory contents
	local cache_dir = "/tmp/mergen/cache"
	if fs.stat(cache_dir) then
		util.exec("rm -rf " .. cache_dir .. "/* 2>/dev/null")
	end

	-- Also try CLI cache clear if available
	mergen_exec("cache clear 2>/dev/null")

	json_response({
		success = true,
		output = "All provider caches cleared"
	})
end

-- RPC: Test a specific provider or all providers
function rpc_test_provider()
	local http = require "luci.http"
	local uci = require "luci.model.uci".cursor()

	local provider_name = http.formvalue("provider") or ""

	if provider_name == "" then
		-- Test all providers
		local output = mergen_exec("validate --check-providers")
		json_response({
			success = true,
			output = output,
			mode = "all"
		})
		return
	end

	-- Sanitize provider name
	if not provider_name:match("^[a-zA-Z0-9_-]+$") then
		json_response({ success = false, error = "Invalid provider name" })
		return
	end

	-- Test specific provider: resolve a known ASN through it
	local output = mergen_exec(
		"resolve 13335 --provider " .. provider_name)

	local success = output:match("Prefix") ~= nil
		or output:match("prefix") ~= nil

	json_response({
		success = true,
		provider = provider_name,
		test_passed = success,
		output = output,
		mode = "single"
	})
end

-- RPC: Get traffic statistics for all rules
function rpc_traffic_stats()
	local uci = require "luci.model.uci".cursor()
	local util = require "luci.util"
	local nixio = require "nixio"
	local fs = require "nixio.fs"

	local rules = {}

	-- Read nftables chain output for counter parsing
	local chain_output = util.exec(
		"nft list chain inet mergen mergen_prerouting 2>/dev/null") or ""

	uci:foreach("mergen", "rule", function(s)
		local name = s.name or s[".name"] or ""
		local enabled = s.enabled or "1"
		local via = s.via or ""
		local fallback = s.fallback or ""
		local set_name = "mergen_" .. name

		local packets = 0
		local bytes = 0

		-- Parse counter from nft output
		for line in chain_output:gmatch("[^\n]+") do
			if line:match("@" .. set_name .. "[_%s]") or line:match("@" .. set_name .. " ") then
				local p = line:match("counter packets (%d+)")
				local b = line:match("bytes (%d+)")
				if p then packets = packets + tonumber(p) end
				if b then bytes = bytes + tonumber(b) end
			end
		end

		-- Check failover state
		local failover_active = false
		local original_via = ""
		local state_file = "/tmp/mergen/failover/" .. name
		if fs.stat(state_file) then
			failover_active = true
			original_via = fs.readfile(state_file) or ""
			original_via = original_via:gsub("%s+$", "")
		end

		rules[#rules + 1] = {
			name = name,
			enabled = (enabled == "1"),
			via = via,
			fallback = fallback,
			packets = packets,
			bytes = bytes,
			failover_active = failover_active,
			original_via = original_via
		}
	end)

	json_response({
		success = true,
		rules = rules
	})
end

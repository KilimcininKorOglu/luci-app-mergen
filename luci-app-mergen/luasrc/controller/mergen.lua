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

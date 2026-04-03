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

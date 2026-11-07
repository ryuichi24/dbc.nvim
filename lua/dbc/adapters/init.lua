local M = {}
local registered = {}
local builtins = { mysql = "dbc.adapters.mysql", postgres = "dbc.adapters.postgres", sqlite = "dbc.adapters.sqlite" }
local required = { "request", "metadata", "children", "preview" }

function M.register(name, adapter)
	assert(type(name) == "string" and name ~= "", "Adapter requires a name")
	assert(type(adapter) == "table", "Adapter must be a table")

	for _, method in ipairs(required) do
		assert(type(adapter[method]) == "function", "Adapter " .. name .. " requires " .. method .. "()")
	end

	for _, method in ipairs({ "template", "quote", "qualify" }) do
		assert(
			adapter[method] == nil or type(adapter[method]) == "function",
			"Adapter " .. method .. " must be a function"
		)
	end

	assert(adapter.capabilities == nil or type(adapter.capabilities) == "table", "Adapter capabilities must be a table")

	for capability, supported in pairs(adapter.capabilities or {}) do
		assert(
			type(capability) == "string" and type(supported) == "boolean",
			"Adapter capabilities must map names to booleans"
		)
	end

	registered[name] = adapter
end

function M.get(profile)
	local name = profile.adapter or "mysql"

	if not registered[name] and builtins[name] then
		M.register(name, require(builtins[name]))
	end

	assert(registered[name], "Unknown database adapter: " .. tostring(name))
	return registered[name]
end

return M

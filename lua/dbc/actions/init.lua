local M = {}
local registered = {}
local initialized = false

local function strings(value, name)
	assert(type(value) == "table" and vim.islist(value), name .. " must be a list")

	for _, item in ipairs(value) do
		assert(type(item) == "string" and item ~= "", name .. " must contain names")
	end
end

local function store(action, opts)
	assert(type(action) == "table", "Action must be a table")
	assert(type(action.id) == "string" and action.id ~= "", "Action requires an id")
	assert(type(action.label) == "string" and action.label ~= "", "Action requires a label")
	assert(type(action.generate) == "function", "Action requires generate(ctx)")
	strings(action.node_kinds, "Action node_kinds")
	assert(#action.node_kinds > 0, "Action requires at least one node kind")

	for _, key in ipairs({ "adapter_methods", "adapters", "capabilities" }) do
		if action[key] then
			strings(action[key], "Action " .. key)
		end
	end

	if action.requires and type(action.requires) ~= "function" then
		strings(action.requires, "Action requires")
	end

	for _, key in ipairs({ "default", "allow_missing_metadata" }) do
		assert(action[key] == nil or type(action[key]) == "boolean", "Action " .. key .. " must be a boolean")
	end

	assert(action.available == nil or type(action.available) == "function", "Action available must be a function")
	assert(
		action.priority == nil
			or (
				type(action.priority) == "number"
				and action.priority == action.priority
				and math.abs(action.priority) < math.huge
			),
		"Action priority must be finite"
	)
	assert(not registered[action.id] or (opts and opts.replace), "Action already registered: " .. action.id)
	registered[action.id] = vim.deepcopy(action)
end

local function initialize()
	if initialized then
		return
	end

	initialized = true

	for _, name in ipairs({ "create_database", "create_table", "insert", "update", "preview", "legacy_template" }) do
		store(require("dbc.actions." .. name))
	end
end

function M.register(action, opts)
	initialize()
	store(action, opts)
end

function M.unregister(id)
	initialize()
	registered[id] = nil
end

function M.get(id)
	initialize()
	return registered[id] and vim.deepcopy(registered[id]) or nil
end

function M.list(ctx)
	initialize()
	local result = {}

	for _, action in pairs(registered) do
		local applicable = vim.tbl_contains(action.node_kinds, ctx.node.kind)
			and (not action.adapters or vim.tbl_contains(action.adapters, ctx.adapter_name))

		for _, method in ipairs(action.adapter_methods or {}) do
			applicable = applicable and type(ctx.adapter[method]) == "function"
		end

		for _, capability in ipairs(action.capabilities or {}) do
			applicable = applicable and ctx.adapter.capabilities and ctx.adapter.capabilities[capability] == true
		end

		if applicable and (not action.available or action.available(ctx)) then
			table.insert(result, vim.deepcopy(action))
		end
	end

	table.sort(result, function(left, right)
		if (left.priority or 0) ~= (right.priority or 0) then
			return (left.priority or 0) > (right.priority or 0)
		end

		return left.id < right.id
	end)
	return result
end

function M.default(ctx)
	for _, action in ipairs(M.list(ctx)) do
		if action.default then
			return action
		end
	end
end

function M.context(node)
	local adapter = require("dbc.adapters").get(node.profile)
	return {
		node = node,
		profile = node.profile,
		database = node.database,
		adapter = adapter,
		adapter_name = node.profile.adapter or "mysql",
		quote = adapter.quote,
		qualify = adapter.qualify and function(name)
			return adapter.qualify(node, name)
		end or nil,
	}
end

function M.generate(action, ctx)
	local result = action.generate(ctx)

	if result == nil then
		return
	end

	if type(result) == "string" then
		result = { sql = result }
	end

	assert(
		type(result) == "table" and type(result.sql) == "string" and result.sql:match("%S"),
		"Action must return SQL text or { sql = text }"
	)

	if result.cursor then
		local row, col = result.cursor[1], result.cursor[2]
		local lines = vim.split(result.sql, "\n", { plain = true })
		assert(
			type(row) == "number" and row % 1 == 0 and row >= 1 and row <= #lines,
			"Action cursor row is outside SQL"
		)
		assert(
			type(col) == "number" and col % 1 == 0 and col >= 0 and col <= #lines[row],
			"Action cursor column is outside SQL"
		)
	end

	return result
end

M.register_metadata = require("dbc.actions.metadata").register
M.unregister_metadata = require("dbc.actions.metadata").unregister
M.prepare = require("dbc.actions.metadata").prepare

return M

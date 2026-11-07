local M = {}
local defaults = {
	connections = {},
	ui = {
		sidebar_width = 30,
		results_height = 14,
		panes = {
			sidebar = { number = false, relativenumber = false },
			query = { number = false, relativenumber = false },
			results = { number = false, relativenumber = false },
		},
	},
	execution = { timeout_ms = 30000, max_output_bytes = 5 * 1024 * 1024, max_rows = 1000 },
	mappings = { run = "<localleader>r", cancel = "<localleader>c" },
}
M.config = vim.deepcopy(defaults)

function M.setup(opts)
	local config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

	for _, key in ipairs({ "timeout_ms", "max_output_bytes", "max_rows" }) do
		local value = config.execution[key]
		assert(
			type(value) == "number" and value > 0 and value == math.floor(value),
			key .. " must be a positive integer"
		)
	end

	for _, key in ipairs({ "sidebar_width", "results_height" }) do
		local value = config.ui[key]
		assert(
			type(value) == "number" and value >= 1 and value == math.floor(value),
			key .. " must be a positive integer"
		)
	end

	for _, pane in ipairs({ "sidebar", "query", "results" }) do
		for _, option in ipairs({ "number", "relativenumber" }) do
			assert(
				type(config.ui.panes[pane][option]) == "boolean",
				"ui.panes." .. pane .. "." .. option .. " must be a boolean"
			)
		end
	end

	require("dbc.connection_store").path(config)
	require("dbc.connection_store").validate(config.connections)

	M.config = config
end

function M.open()
	return require("dbc.workspace").open(M.config)
end

function M.run(first, last)
	require("dbc.workspace").run(first, last)
end

function M.action(id)
	require("dbc.workspace").action(id)
end

function M.command(args)
	local action = args.fargs[1] or "open"
	local workspace = require("dbc.workspace")

	if action == "open" then
		M.open()
	elseif action == "run" then
		M.run(args.range > 0 and args.line1 or nil, args.range > 0 and args.line2 or nil)
	elseif action == "update" then
		workspace.update(args.range > 0 and args.line1 or nil, args.range > 0 and args.line2 or nil)
	elseif action == "edit_connections" then
		local store = require("dbc.connection_store")
		store.ensure(M.config)
		vim.cmd("tabedit " .. vim.fn.fnameescape(store.path(M.config)))
	elseif
		workspace[action]
		and vim.tbl_contains({
			"connect",
			"add_connection",
			"reload_connections",
			"query",
			"next_query",
			"previous_query",
			"pick_query",
			"close_query",
			"actions",
			"cancel",
			"refresh",
			"close",
		}, action)
	then
		workspace[action]()
	else
		error("Unknown Dbc action: " .. action)
	end
end

return M

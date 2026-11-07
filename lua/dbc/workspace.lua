local M = {}
local api = vim.api
local adapters = require("dbc.adapters")
local actions = require("dbc.actions")
local current
local serial = 0
local render_tree
local activate_query

local function save_queries(state)
	if state.restoring or state.disposed then
		return
	end

	local queries = {}

	for _, tab in ipairs(state.queries) do
		if api.nvim_buf_is_valid(tab.buf) and api.nvim_buf_is_loaded(tab.buf) then
			local binding = state.bindings[tab.buf]
			table.insert(queries, {
				lines = api.nvim_buf_get_lines(tab.buf, 0, -1, false),
				connection = binding and binding.profile.name,
				database = binding and binding.database,
				active = tab.buf == state.query,
				snapshot = tab.snapshot,
			})
		end
	end

	local ok, err = pcall(function()
		vim.fn.mkdir(vim.fn.fnamemodify(state.storage, ":h"), "p", 448)
		vim.fn.writefile({ vim.json.encode(queries) }, state.storage)
		vim.fn.setfperm(state.storage, "rw-------")
	end)

	if not ok then
		vim.notify("dbc: could not save query tabs: " .. tostring(err), vim.log.levels.ERROR)
	end
end

local function write(buf, lines)
	if api.nvim_buf_is_valid(buf) then
		vim.bo[buf].modifiable = true
		api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modifiable = false
	end
end

local function scratch(kind)
	local buf = api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].filetype = kind == "results" and "markdown" or "dbc" .. kind
	return buf
end

local function require_workspace()
	assert(current and api.nvim_tabpage_is_valid(current.tab), "Open the dashboard with :Dbc first")
	return current
end

local function layout(state)
	local width = math.max(3, vim.o.columns - 4)
	local height = math.max(3, vim.o.lines - vim.o.cmdheight - 4)
	local panes = state.config.ui.panes
	local right_width = panes.query.width or panes.results.width
	local sidebar_width = panes.sidebar.width or (right_width and width - right_width - 1)
	local results_height = panes.query.height and height - panes.query.height - 1 or panes.results.height
	local sidebar = math.min(
		state.sidebar_width
			or sidebar_width
			or math.min(state.config.ui.sidebar_width, math.max(1, math.floor(width / 3))),
		math.max(1, width - 2)
	)
	local results = math.min(
		state.results_height
			or results_height
			or math.min(state.config.ui.results_height, math.max(1, math.floor((height - 1) / 2))),
		math.max(1, height - 2)
	)
	sidebar = math.max(1, sidebar)
	results = math.max(1, results)
	local right = width - sidebar - 1
	local query = height - results - 1
	return {
		sidebar = { row = 1, col = 1, width = sidebar, height = height },
		query = { row = 1, col = sidebar + 3, width = right, height = query },
		results = { row = query + 3, col = sidebar + 3, width = right, height = results },
	}
end

local function resize(state, key)
	local win = api.nvim_get_current_win()
	local pane

	for _, name in ipairs({ "sidebar", "query", "results" }) do
		if win == state[name .. "_win"] then
			pane = name
		end
	end

	if state.disposed or not pane then
		return
	end

	local geometry = layout(state)
	local delta = ((key == "k" or key == "l") and 1 or -1) * state.config.ui.resize_step

	if key == "h" or key == "l" then
		state.sidebar_width = math.max(1, geometry.sidebar.width + (pane == "sidebar" and delta or -delta))
	elseif pane ~= "sidebar" then
		state.results_height = math.max(1, geometry.results.height + (pane == "results" and delta or -delta))
	end

	for name, config in pairs(layout(state)) do
		if api.nvim_win_is_valid(state[name .. "_win"]) then
			config.relative = "editor"
			api.nvim_win_set_config(state[name .. "_win"], config)
		end
	end
end

local function query_header(state)
	local win = state.query_win

	if not api.nvim_win_is_valid(win) then
		return
	end

	local buf = api.nvim_win_get_buf(win)
	local binding = state.bindings[buf]
	local text = "Query · No database bound"

	if binding then
		state.query = buf
		text = string.format("Connection: %s · Database: %s", binding.profile.name, binding.database or "(default)")
	end

	local tabs = {}

	for index, tab in ipairs(state.queries) do
		local label = " " .. index .. ":Query " .. tab.id .. " "
		table.insert(tabs, tab.buf == buf and ("%#TabLineSel#" .. label .. "%*") or label)
	end

	vim.wo[win].winbar = table.concat(tabs, "|") .. " %<" .. text:gsub("[%c]", " "):gsub("%%", "%%%%")
end

local function focus(state, name)
	api.nvim_set_current_tabpage(state.tab)

	if not api.nvim_win_is_valid(state[name .. "_win"]) then
		local config = layout(state)[name]
		config.relative = "editor"
		config.style = "minimal"
		config.border = "rounded"
		state[name .. "_win"] = api.nvim_open_win(state[name], false, config)
	end

	api.nvim_set_current_win(state[name .. "_win"])
	api.nvim_win_set_buf(state[name .. "_win"], state[name])

	for _, option in ipairs({ "number", "relativenumber" }) do
		vim.wo[state[name .. "_win"]][option] = state.config.ui.panes[name][option]
	end

	state.active_pane = name

	if name == "query" then
		query_header(state)
	end
end

local function navigation(state, buf)
	state.navigation_buffers[buf] = true
	local directions = {
		h = { query = "sidebar", results = "sidebar" },
		j = { query = "results" },
		k = { results = "query" },
		l = { sidebar = "query" },
	}

	local function move(direction)
		if state.disposed then
			return
		end

		local pane = state.active_pane

		for _, name in ipairs({ "sidebar", "query", "results" }) do
			if api.nvim_get_current_win() == state[name .. "_win"] then
				pane = name
			end
		end

		local target = directions[direction] and directions[direction][pane]

		if direction == "w" then
			target = ({ sidebar = "query", query = "results", results = "sidebar" })[pane]
		elseif direction == "p" then
			target = state.previous_pane
		end

		if target then
			state.previous_pane = pane
			focus(state, target)
		end
	end

	for _, key in ipairs({ "h", "j", "k", "l", "w", "p" }) do
		local callback = function()
			move(key)
		end

		local directional = key ~= "w" and key ~= "p"
		local window_callback = directional
				and function()
					require("dbc.resize").start(key, function(direction)
						resize(state, direction)
					end)
				end
			or callback
		local description = directional and "Resize dbc pane" or "Navigate dbc panes"
		vim.keymap.set("n", "<C-w>" .. key, window_callback, { buffer = buf, desc = description })
		vim.keymap.set("n", "<C-w><C-" .. key .. ">", window_callback, { buffer = buf, desc = description })

		if key ~= "w" then
			vim.keymap.set("n", "<C-" .. key .. ">", callback, { buffer = buf, desc = "Navigate dbc panes" })
		end
	end
end

local function display(value)
	if value == vim.NIL then
		return "NULL"
	end

	if value == "" then
		return '""'
	end

	return tostring(value):gsub("\\", "\\\\"):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t"):gsub("%z", "\\0")
end

local function render_results(state, result, binding)
	local lines =
		{ string.format("%s / %s · %.0f ms", binding.profile.name, binding.database or "(default)", result.duration) }
	table.insert(lines, "Fetched: " .. os.date("%Y-%m-%d %H:%M:%S %Z") .. " · Rerun query for the latest data.")
	state.cells = {}

	if result.error or result.code ~= 0 then
		vim.list_extend(lines, { "ERROR: " .. (result.error or "Client exited " .. result.code), result.stderr })
	else
		local sets = result.sets

		if result.decode_error then
			table.insert(lines, "Decode error: " .. result.decode_error)
		else
			local remaining = state.config.execution.max_rows

			for index, set in ipairs(sets) do
				table.insert(lines, "")
				table.insert(lines, string.format("Result %d · %d returned rows", index, #set.rows))
				local widths = {}
				local function markdown(value)
					return display(value)
						:gsub("&", "&amp;")
						:gsub("<", "&lt;")
						:gsub(">", "&gt;")
						:gsub("|", "&#124;")
						:gsub("`", "&#96;")
						:gsub("%*", "&#42;")
						:gsub("_", "&#95;")
				end

				for column, name in ipairs(set.columns) do
					widths[column] = math.max(3, vim.fn.strdisplaywidth(markdown(name)))
				end

				for _, row in ipairs(set.rows) do
					for column, value in ipairs(row) do
						widths[column] = math.max(widths[column] or 3, vim.fn.strdisplaywidth(markdown(value)))
					end
				end
				local headers, separators = {}, {}

				for column, name in ipairs(set.columns) do
					local text = markdown(name)
					headers[column] = text .. string.rep(" ", widths[column] - vim.fn.strdisplaywidth(text))
					separators[column] = string.rep("-", widths[column])
				end

				if #headers > 0 then
					table.insert(lines, "| " .. table.concat(headers, " | ") .. " |")
					table.insert(lines, "| " .. table.concat(separators, " | ") .. " |")
				end

				for _, row in ipairs(set.rows) do
					if remaining == 0 then
						table.insert(lines, "Display row limit reached; additional rows omitted")
						break
					end

					local cells, starts, offset = {}, {}, 3

					for column, value in ipairs(row) do
						local text = markdown(value)
						starts[column] = offset
						cells[column] = text
							.. string.rep(" ", math.max(0, widths[column] - vim.fn.strdisplaywidth(text)))
						offset = offset + #cells[column] + 3
					end

					table.insert(lines, "| " .. table.concat(cells, " | ") .. " |")
					state.cells[#lines] = { values = row, starts = starts, columns = set.columns }
					remaining = remaining - 1
				end
			end

			if #sets == 0 then
				table.insert(lines, "Completed (client supplied no result set or affected-row count)")
			end

			if result.stderr ~= "" then
				table.insert(lines, result.stderr)
			end
		end
	end

	lines = vim.split(table.concat(lines, "\n"), "\n", { plain = true })
	local cells = {}

	for row, cell in pairs(state.cells) do
		table.insert(cells, { row = row, values = cell.values, starts = cell.starts, columns = cell.columns })
	end

	state.snapshot = { lines = lines, cells = cells, source = state.source, binding = binding }
	write(state.results, lines)
end

local function execute(state, binding, sql, callback)
	return state.runner:run(binding, sql, callback)
end

local function load_node(state, node, on_complete)
	if node.loading then
		if on_complete then
			table.insert(node.load_callbacks, on_complete)
		end

		return true
	end

	if next(state.metadata_jobs) then
		vim.notify("Metadata is loading; retry when it finishes", vim.log.levels.INFO)
		return false
	end

	local adapter = adapters.get(node.profile)
	local sql = adapter.metadata(node)
	local binding = { profile = node.profile, database = node.database }

	if not sql then
		return false
	end

	node.loading = true
	node.error = nil
	node.expanded = true
	local callbacks = on_complete and { on_complete } or {}
	node.load_callbacks = callbacks

	local function complete()
		if node.load_callbacks == callbacks then
			node.load_callbacks = nil
		end

		for _, callback in ipairs(callbacks) do
			callback()
		end
	end

	state.metadata_id = state.metadata_id + 1
	local id = state.metadata_id
	local ok, cancel = pcall(execute, state, binding, sql, function(result)
		state.metadata_jobs[id] = nil

		if current ~= state or node.generation ~= id then
			return
		end

		node.loading = false
		if result.error or result.code ~= 0 or result.decode_error then
			node.error = result.error or (result.code ~= 0 and result.stderr) or result.decode_error
		else
			local converted, children = pcall(adapter.children, node, result.sets)

			if converted then
				node.children = children

				for _, child in ipairs(children) do
					child.profile = node.profile
				end
			else
				node.error = tostring(children)
			end
		end

		render_tree(state)

		complete()
	end)
	node.generation = id

	if ok then
		state.metadata_jobs[id] = cancel
	else
		node.loading = false
		node.error = tostring(cancel)
	end

	render_tree(state)

	if not ok then
		complete()
	end

	return true
end

render_tree = function(state)
	local lines = {
		"a: add connection/table/record · d: remove connection · Enter: DB",
		"ga: default · u: update · A: actions · n: query · p: preview",
		"",
	}
	state.nodes = {}
	local selected = api.nvim_win_is_valid(state.sidebar_win) and api.nvim_win_get_cursor(state.sidebar_win)[1] or 1
	local selected_node = state.previous_nodes and state.previous_nodes[selected]
	local selected_line = selected

	local function visit(nodes, depth)
		for _, node in ipairs(nodes) do
			local prefix = node.kind == "column" and "  " or (node.expanded and "- " or "+ ")
			local binding = state.bindings[state.query]
			local selected_database = node.kind == "database"
				and binding
				and binding.profile.name == node.profile.name
				and binding.database == node.database
			table.insert(
				lines,
				string.rep("  ", depth)
					.. prefix
					.. node.name
					.. (selected_database and " [query]" or "")
					.. (node.detail and " (" .. node.detail .. ")" or "")
			)
			state.nodes[#lines] = node

			if node == selected_node then
				selected_line = #lines
			end

			if node.loading or node.error then
				table.insert(
					lines,
					string.rep("  ", depth + 1)
						.. (node.loading and "Loading…" or ("Error: " .. node.error:gsub("\n", " ")))
				)
			end

			if node.expanded and node.children then
				visit(node.children, depth + 1)

				if #node.children == 0 and not node.loading and not node.error then
					table.insert(lines, string.rep("  ", depth + 1) .. "(No items)")
				end
			end
		end
	end

	visit(state.roots, 0)
	state.previous_nodes = state.nodes
	write(state.sidebar, lines)

	if api.nvim_win_is_valid(state.sidebar_win) then
		api.nvim_win_set_cursor(state.sidebar_win, { math.min(selected_line, #lines), 0 })
	end
end

local function selected_node(state)
	return state.nodes[api.nvim_win_get_cursor(state.sidebar_win)[1]]
end

activate_query = function(state, tab)
	state.query = tab.buf
	state.results = tab.results
	state.cells = tab.cells

	if api.nvim_win_is_valid(state.results_win) then
		api.nvim_win_set_buf(state.results_win, state.results)
	end

	focus(state, "query")
	render_tree(state)
	save_queries(state)
end

function M.goto_query(index)
	local state = require_workspace()
	assert(type(index) == "number" and index == math.floor(index) and state.queries[index], "Invalid query tab index")
	activate_query(state, state.queries[index])
end

function M.pick_query()
	local state = require_workspace()
	require("dbc.picker").open({
		items = function()
			local items = {}

			for index, tab in ipairs(state.queries) do
				local binding = state.bindings[tab.buf]
				local sql = table.concat(api.nvim_buf_get_lines(tab.buf, 0, -1, false), " ")
				local label = string.format(
					"%s %d:Query %d · %s · %s · %s",
					tab.buf == state.query and "*" or " ",
					index,
					tab.id,
					binding and binding.profile.name or "No connection",
					binding and binding.database or "(default)",
					sql:match("%S") and sql or "(empty query)"
				)
				table.insert(items, { key = tab.buf, label = label, search = label, tab = tab })
			end

			return items
		end,
		select = function(item)
			if not state.disposed and vim.tbl_contains(state.queries, item.tab) then
				activate_query(state, item.tab)
			end
		end,
	})
end

function M.next_query(direction)
	local state = require_workspace()

	for index, tab in ipairs(state.queries) do
		if tab.buf == state.query then
			activate_query(state, state.queries[(index - 1 + (direction or 1)) % #state.queries + 1])
			return
		end
	end
end

function M.previous_query()
	M.next_query(-1)
end

function M.close_query()
	local state = require_workspace()

	if #state.queries <= 1 then
		return
	end

	for index, tab in ipairs(state.queries) do
		if tab.buf == state.query then
			table.remove(state.queries, index)
			activate_query(state, state.queries[math.min(index, #state.queries)])
			return
		end
	end
end

function M.query(binding, text)
	local state = require_workspace()
	binding = binding or state.binding
	local buf = api.nvim_create_buf(true, false)
	api.nvim_buf_set_name(buf, "dbc://query/" .. buf .. ".sql")
	vim.bo[buf].filetype = "sql"
	vim.bo[buf].bufhidden = "hide"
	state.bindings[buf] = binding and vim.deepcopy(binding) or nil
	state.query_serial = state.query_serial + 1
	local tab = { buf = buf, id = state.query_serial, results = scratch("results"), config = state.config }
	table.insert(state.queries, tab)
	table.insert(state.result_buffers, tab.results)
	write(tab.results, { "Run SQL with :Dbc run. Each execution uses a new database session." })
	navigation(state, buf)
	navigation(state, tab.results)

	if state.configure_results then
		state.configure_results(tab.results)
	end

	if text then
		api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
	end

	activate_query(state, tab)
	vim.keymap.set({ "n", "x" }, state.config.mappings.run, ":Dbc run<CR>", { buffer = buf, silent = true })
	vim.keymap.set("n", state.config.mappings.cancel, M.cancel, { buffer = buf })
	vim.keymap.set("n", "gt", function()
		if vim.v.count > 0 then
			M.goto_query(vim.v.count)
		else
			M.next_query()
		end
	end, { buffer = buf, desc = "Next query tab or jump to indexed query tab" })
	vim.keymap.set("n", "gT", M.previous_query, { buffer = buf, desc = "Previous query tab" })
	vim.keymap.set("n", "<localleader>t", function()
		M.query(state.bindings[state.query])
	end, { buffer = buf, desc = "New query tab" })
	vim.keymap.set("n", "<localleader>x", M.close_query, { buffer = buf, desc = "Close query tab (preserve buffer)" })
	api.nvim_buf_attach(buf, false, {
		on_lines = function()
			vim.schedule(function()
				save_queries(state)
			end)
		end,
	})
	api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
		buffer = buf,
		once = true,
		callback = function()
			if state.disposed then
				return
			end

			for index, query in ipairs(state.queries) do
				if query.buf == buf then
					table.remove(state.queries, index)
					break
				end
			end

			save_queries(state)
			vim.schedule(function()
				if state.disposed then
					return
				end

				if #state.queries == 0 then
					M.query()
				elseif state.query == buf then
					activate_query(state, state.queries[1])
				end
			end)
		end,
	})
	return buf
end

local function run_action(state, action, ctx)
	if current ~= state or state.disposed then
		return
	end

	ctx.timeout_ms = state.config.execution.timeout_ms
	ctx.fetch_children = function(done)
		local node = ctx.node

		if node.children then
			done(nil, node.children)
		elseif next(state.metadata_jobs) and not node.loading then
			done("Metadata is busy")
		elseif not load_node(state, node, function()
			done(node.error, node.children)
		end) then
			done("Child metadata is unavailable for this item")
		end
	end
	local job = {}
	state.action_jobs[job] = true
	local cancel = actions.prepare(action, ctx, function(err)
		state.action_jobs[job] = nil

		if current ~= state or state.disposed then
			return
		end

		if err then
			vim.notify("dbc action " .. action.id .. ": " .. err, vim.log.levels.ERROR)
			return
		end

		local ok, result = pcall(actions.generate, action, ctx)

		if not ok then
			vim.notify("dbc action " .. action.id .. ": " .. tostring(result), vim.log.levels.ERROR)
			return
		end

		if not result then
			return
		end

		local buf = M.query({ profile = ctx.profile, database = ctx.database }, result.sql)

		if result.cursor then
			api.nvim_win_set_cursor(state.query_win, result.cursor)
			return
		end

		for row, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
			local column = line:find("<[%a_][%w_]*>")

			if column then
				api.nvim_win_set_cursor(state.query_win, { row, column - 1 })
				break
			end
		end
	end)
	job.cancel = function()
		state.action_jobs[job] = nil
		cancel()
	end
end

local function action_context(state)
	if not api.nvim_win_is_valid(state.sidebar_win) then
		return
	end

	local node = selected_node(state)

	if node then
		return actions.context(node)
	end
end

local function choose_action(state, ctx, choices)
	if #choices == 0 then
		vim.notify("dbc: no query actions available for this item", vim.log.levels.INFO)
		return
	end

	vim.ui.select(choices, {
		prompt = "Database query action",
		format_item = function(action)
			return action.label
		end,
	}, function(action)
		if action then
			run_action(state, action, ctx)
		end
	end)
end

function M.action(id)
	local state = require_workspace()

	if id == "update" and api.nvim_get_current_buf() == state.results then
		return M.update()
	end

	local ctx = action_context(state)

	if not ctx then
		return
	end

	local ok, choices = pcall(actions.list, ctx)

	if not ok then
		vim.notify("dbc actions: " .. tostring(choices), vim.log.levels.ERROR)
		return
	end

	for _, action in ipairs(choices) do
		if (id and action.id == id) or (not id and action.default) then
			run_action(state, action, ctx)
			return
		end
	end

	if id then
		vim.notify("dbc: action is unknown or unavailable here: " .. id, vim.log.levels.INFO)
	else
		choose_action(state, ctx, choices)
	end
end

function M.update(first, last)
	local state = require_workspace()
	assert(api.nvim_get_current_buf() == state.results, "Select a row in the results pane")
	local line = first or api.nvim_win_get_cursor(0)[1]
	assert(not last or last == line, "Select exactly one result row")
	local row = state.cells and state.cells[line]
	assert(row and row.columns, "Select a result data row; rerun older saved results first")
	local snapshot

	for _, tab in ipairs(state.queries) do
		if tab.results == state.results then
			snapshot = tab.snapshot
		end
	end

	assert(snapshot and snapshot.source and snapshot.binding, "Rerun this query before updating a row")
	local ctx = actions.context(require("dbc.row_update").source(snapshot.source, snapshot.binding))
	run_action(state, {
		id = "update",
		requires = { "columns" },
		generate = function(context)
			return require("dbc.row_update").generate(context, row)
		end,
	}, ctx)
end

function M.add_query()
	M.action()
end

function M.actions()
	local state = require_workspace()
	local ctx = action_context(state)

	if not ctx then
		return
	end

	local ok, choices = pcall(actions.list, ctx)

	if ok then
		choose_action(state, ctx, choices)
	else
		vim.notify("dbc actions: " .. tostring(choices), vim.log.levels.ERROR)
	end
end

function M.reload_connections()
	local state = require_workspace()
	local config = require("dbc.connection_store").resolve(state.connection_config)
	local roots = {}

	for _, profile in ipairs(config.connections) do
		local root = { name = profile.name, kind = "connection", profile = profile }

		for _, existing in ipairs(state.roots) do
			if vim.deep_equal(existing.profile, profile) then
				root = existing
				break
			end
		end

		table.insert(roots, root)
	end

	state.config.connections = config.connections
	state.roots = roots
	render_tree(state)
end

function M.add_connection()
	local state = require_workspace()
	return require("dbc.connection_form").open(function(profile)
		if current ~= state or state.disposed then
			return false
		end

		local ok, err = pcall(function()
			require("dbc.connection_store").add(state.connection_config, profile)
			M.reload_connections()
			M.query({ profile = profile, database = profile.database })
		end)

		if not ok then
			vim.notify("dbc: " .. tostring(err), vim.log.levels.ERROR)
		end

		return ok
	end)
end

function M.remove_connection()
	local state = require_workspace()
	local node = selected_node(state)

	if not node or node.kind ~= "connection" then
		vim.notify("dbc: select a connection row to remove it", vim.log.levels.INFO)
		return
	end

	for _, profile in ipairs(state.connection_config.connections or {}) do
		if profile.name == node.profile.name then
			vim.notify("dbc: remove this connection from setup().connections in your Lua config", vim.log.levels.INFO)
			return
		end
	end

	local profile = vim.deepcopy(node.profile)
	return require("dbc.connection_confirm").open(profile.name, function()
		if current ~= state or state.disposed then
			return
		end

		local ok, err = pcall(function()
			require("dbc.connection_store").remove(state.connection_config, profile)
			local removed = {}

			if state.binding and state.binding.profile.name == profile.name then
				state.binding = nil
			end

			for buf, binding in pairs(state.bindings) do
				if binding.profile.name == profile.name then
					removed[buf] = true
					if state.running_query == buf and state.cancel then
						state.execution = state.execution + 1
						state.cancel()
						state.cancel = nil
						state.running_query = nil
					end

					state.bindings[buf] = nil
				end
			end

			for index = #state.queries, 1, -1 do
				local tab = state.queries[index]

				if removed[tab.buf] then
					table.remove(state.queries, index)
				end
			end

			if #state.queries == 0 then
				M.query()
			elseif removed[state.query] then
				activate_query(state, state.queries[1])
			else
				save_queries(state)
			end

			M.reload_connections()
		end)

		if not ok then
			vim.notify("dbc: " .. tostring(err), vim.log.levels.ERROR)
		end
	end)
end

function M.connect()
	local state = require_workspace()
	vim.ui.select(state.config.connections, {
		prompt = "Database connection",
		format_item = function(profile)
			return profile.name
		end,
	}, function(profile)
		if profile and current == state then
			state.binding = { profile = profile, database = profile.database }
			M.query()
		end
	end)
end

function M.cancel()
	local state = require_workspace()

	if state.cancel then
		state.cancel()
	end
end

local function refresh_schema(state, binding)
	local targets = {}

	local function visit(nodes)
		for _, node in ipairs(nodes or {}) do
			if node.profile.name == binding.profile.name then
				if node.kind == "connection" and not binding.database then
					table.insert(targets, node)
				elseif node.database == binding.database and node.expanded then
					if node.kind == "schema" or (node.kind == "database" and binding.profile.adapter ~= "postgres") then
						table.insert(targets, node)
					else
						visit(node.children)
					end
				else
					visit(node.children)
				end
			end
		end
	end

	visit(state.roots)
	local index = 0
	local function next_node()
		index = index + 1

		if current == state and targets[index] then
			load_node(state, targets[index], next_node)
		end
	end

	next_node()
end

function M.run(first, last)
	local state = require_workspace()
	local buf = api.nvim_get_current_buf()
	local binding = state.bindings[buf]
	assert(binding, "Run from a dbc query buffer; create one with :Dbc query")
	assert(not state.cancel, "A query is running; cancel it or wait for completion")
	local sql = table.concat(api.nvim_buf_get_lines(buf, first and first - 1 or 0, last or -1, false), "\n")
	assert(sql:match("%S"), "Query is empty")
	local changes_schema = false
	local upper = sql:upper()

	for _, keyword in ipairs({ "CREATE", "ALTER", "DROP", "RENAME" }) do
		if upper:match("%f[%a]" .. keyword .. "%f[%A]") then
			changes_schema = true
		end
	end

	state.execution = state.execution + 1
	local id = state.execution
	local target

	for _, tab in ipairs(state.queries) do
		if tab.buf == buf then
			target = tab
		end
	end

	assert(target, "Reopen this query in a query tab before running")
	target.source = sql
	target.cells = nil
	state.cells = nil
	write(target.results, { "Running · " .. binding.profile.name .. " / " .. (binding.database or "(default)") })
	state.running_query = buf
	state.cancel = execute(state, binding, sql, function(result)
		if current == state and state.execution == id then
			state.cancel = nil
			state.running_query = nil
			render_results(target, result, binding)
			save_queries(state)

			if state.query == buf then
				state.cells = target.cells
			end

			if changes_schema and not result.error and result.code == 0 and not result.decode_error then
				refresh_schema(state, binding)
			end
		end
	end)
end

function M.refresh()
	local state = require_workspace()
	local node = selected_node(state)

	if node then
		load_node(state, node)
	end
end

local function dispose(state)
	if state.disposed then
		return
	end

	save_queries(state)
	state.disposed = true
	require("dbc.resize").stop()

	for job in pairs(state.action_jobs) do
		job.cancel()
	end

	for buf in pairs(state.navigation_buffers) do
		if api.nvim_buf_is_valid(buf) then
			for _, key in ipairs({ "h", "j", "k", "l", "w", "p" }) do
				vim.keymap.del("n", "<C-w>" .. key, { buffer = buf })
				vim.keymap.del("n", "<C-w><C-" .. key .. ">", { buffer = buf })

				if key ~= "w" then
					vim.keymap.del("n", "<C-" .. key .. ">", { buffer = buf })
				end
			end
		end
	end

	if current == state then
		current = nil
	end

	state.runner:close()
	if state.cancel then
		state.cancel()
	end

	for _, cancel in pairs(state.metadata_jobs) do
		cancel()
	end

	for _, name in ipairs({ "sidebar", "query", "results" }) do
		if api.nvim_win_is_valid(state[name .. "_win"]) then
			api.nvim_win_close(state[name .. "_win"], true)
		end
	end

	for _, buf in ipairs(vim.list_extend({ state.sidebar }, state.result_buffers)) do
		if api.nvim_buf_is_valid(buf) then
			api.nvim_buf_delete(buf, { force = true })
		end
	end
end

function M.close()
	local state = require_workspace()
	dispose(state)

	if api.nvim_win_is_valid(state.previous_win) then
		api.nvim_set_current_win(state.previous_win)
	end
end

function M.open(config)
	assert(vim.fn.has("nvim-0.10") == 1, "dbc requires Neovim 0.10+")

	if current and api.nvim_tabpage_is_valid(current.tab) then
		M.reload_connections()
		focus(current, "results")
		focus(current, "sidebar")
		focus(current, "query")
		return current
	end

	local store = require("dbc.connection_store")
	local connection_config = vim.deepcopy(config)
	connection_config.connections_file = store.path(config)
	config = store.resolve(connection_config)
	serial = serial + 1
	local state = {
		storage = vim.fn.stdpath("data") .. "/dbc/queries-" .. vim.fn.sha256(vim.fn.getcwd()) .. ".json",
		restoring = true,
		config = vim.deepcopy(config),
		connection_config = vim.deepcopy(connection_config),
		runner = require("dbc.execution").new(config.execution),
		tab = api.nvim_get_current_tabpage(),
		previous_win = api.nvim_get_current_win(),
		query_win = -1,
		sidebar_win = -1,
		results_win = -1,
		query = api.nvim_create_buf(true, false),
		sidebar = scratch("sidebar"),
		results = scratch("results"),
		bindings = {},
		queries = {},
		query_serial = 0,
		result_buffers = {},
		navigation_buffers = {},
		roots = {},
		metadata_jobs = {},
		action_jobs = {},
		metadata_id = 0,
		execution = 0,
	}
	current = state
	table.insert(state.result_buffers, state.results)

	for _, profile in ipairs(config.connections) do
		table.insert(state.roots, { name = profile.name, kind = "connection", profile = profile })
	end

	focus(state, "results")
	focus(state, "sidebar")
	focus(state, "query")

	for _, buf in ipairs({ state.sidebar, state.query, state.results }) do
		navigation(state, buf)
	end

	for _, win in ipairs({ state.sidebar_win, state.results_win }) do
		vim.wo[win].wrap = false
	end

	local function map(key, callback)
		vim.keymap.set("n", key, callback, { buffer = state.sidebar, silent = true })
	end

	map("<CR>", function()
		local node = selected_node(state)

		if node then
			if node.kind == "database" or node.kind == "schema" then
				state.binding = { profile = node.profile, database = node.database }
				state.bindings[state.query] = vim.deepcopy(state.binding)
				query_header(state)
				save_queries(state)
			end

			if node.children then
				node.expanded = not node.expanded
				render_tree(state)
			else
				load_node(state, node)
			end
		end
	end)
	map("n", function()
		local node = selected_node(state)

		if node and node.database then
			M.query({ profile = node.profile, database = node.database })
			render_tree(state)
		else
			vim.notify("dbc: select a database, then press n to create a query", vim.log.levels.INFO)
		end
	end)
	map("ga", M.add_query)
	map("u", function()
		M.action("update")
	end)
	map("A", M.actions)
	map("r", function()
		M.action("preview")
	end)
	map("p", function()
		M.action("preview")
	end)
	map("R", M.refresh)
	map("c", M.connect)
	map("a", function()
		local node = selected_node(state)

		if not node or node.kind == "connection" then
			return M.add_connection()
		elseif node.kind == "database" or node.kind == "schema" then
			M.action("create_table")
		elseif node.kind == "table" then
			M.action("insert")
		end
	end)
	map("d", M.remove_connection)
	map("q", M.close)
	state.configure_results = function(buf)
		vim.keymap.set("n", "u", M.update, { buffer = buf, desc = "Open UPDATE for result row" })
		vim.keymap.set(
			"x",
			"u",
			":Dbc update<CR>",
			{ buffer = buf, silent = true, desc = "Open UPDATE for selected row" }
		)
		vim.keymap.set("n", "q", function()
			vim.cmd("close")
		end, { buffer = buf })
		vim.keymap.set("n", "yr", function()
			local row = state.cells and state.cells[api.nvim_win_get_cursor(0)[1]]

			if row then
				local values = vim.tbl_map(display, row.values)
				vim.fn.setreg('"', table.concat(values, "\t"))
			end
		end, { buffer = buf, desc = "Yank result row as escaped TSV" })
		vim.keymap.set("n", "yc", function()
			local cursor = api.nvim_win_get_cursor(0)
			local row = state.cells and state.cells[cursor[1]]

			if row then
				local column = 1

				for index, start in ipairs(row.starts) do
					if cursor[2] + 1 >= start then
						column = index
					end
				end

				local value = row.values[column]
				vim.fn.setreg('"', value == vim.NIL and "NULL" or value)
			end
		end, { buffer = buf, desc = "Yank raw result cell" })
	end
	state.configure_results(state.results)
	api.nvim_create_autocmd("TabClosed", {
		group = api.nvim_create_augroup("DbcWorkspace" .. serial, { clear = true }),
		callback = function(event)
			if not api.nvim_tabpage_is_valid(state.tab) then
				dispose(state)
				api.nvim_del_augroup_by_id(event.group)
			end
		end,
	})
	api.nvim_create_autocmd("VimLeavePre", {
		group = "DbcWorkspace" .. serial,
		callback = function()
			dispose(state)
		end,
	})
	api.nvim_create_autocmd("VimResized", {
		group = "DbcWorkspace" .. serial,
		callback = function()
			if state.disposed then
				return
			end

			for name, geometry in pairs(layout(state)) do
				if api.nvim_win_is_valid(state[name .. "_win"]) then
					geometry.relative = "editor"
					api.nvim_win_set_config(state[name .. "_win"], geometry)
				end
			end
		end,
	})
	api.nvim_create_autocmd("WinEnter", {
		group = "DbcWorkspace" .. serial,
		callback = function()
			if state.disposed or api.nvim_get_current_tabpage() ~= state.tab then
				return
			end

			local win = api.nvim_get_current_win()

			for _, name in ipairs({ "sidebar", "query", "results" }) do
				if win == state[name .. "_win"] then
					state.active_pane = name
					return
				end
			end

			if api.nvim_win_get_config(win).relative == "" then
				focus(state, state.active_pane or "query")
			end
		end,
	})
	api.nvim_create_autocmd("BufWinEnter", {
		group = "DbcWorkspace" .. serial,
		callback = function(event)
			if
				not state.disposed
				and api.nvim_win_is_valid(state.query_win)
				and api.nvim_win_get_buf(state.query_win) == event.buf
			then
				local buf = api.nvim_win_get_buf(state.query_win)

				for _, tab in ipairs(state.queries) do
					if tab.buf == buf and state.query ~= buf then
						activate_query(state, tab)
					end
				end

				query_header(state)
			end
		end,
	})
	render_tree(state)
	write(state.results, { "Run SQL with :Dbc run. Each execution uses a new database session." })

	local restored, saved = pcall(function()
		if vim.fn.filereadable(state.storage) == 0 then
			return {}
		end

		return vim.json.decode(table.concat(vim.fn.readfile(state.storage), "\n"))
	end)
	local active

	if restored and type(saved) == "table" then
		for _, query in ipairs(saved) do
			local binding

			for _, profile in ipairs(config.connections) do
				if profile.name == query.connection then
					binding = { profile = profile, database = query.database }
				end
			end

			M.query(binding, table.concat(query.lines, "\n"))
			local tab = state.queries[#state.queries]

			if query.snapshot then
				tab.snapshot = query.snapshot
				tab.cells = {}

				for _, cell in ipairs(query.snapshot.cells) do
					tab.cells[cell.row] = { values = cell.values, starts = cell.starts, columns = cell.columns }
				end

				write(tab.results, query.snapshot.lines)
				state.cells = tab.cells
			end

			if query.active then
				active = state.queries[#state.queries]
			end
		end
	elseif not restored then
		vim.notify("dbc: could not restore query tabs: " .. tostring(saved), vim.log.levels.ERROR)
	end

	if active then
		activate_query(state, active)
	end

	if #state.queries > 0 then
		state.binding = state.bindings[state.query]
	elseif config.connections[1] then
		state.binding = { profile = config.connections[1], database = config.connections[1].database }
		M.query()
	else
		M.query()
		vim.notify("dbc: press a in the sidebar or use :Dbc add_connection to add a connection", vim.log.levels.INFO)
	end
	state.restoring = false
	save_queries(state)

	return state
end

return M

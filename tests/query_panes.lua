local M = {}

function M.run()
	local api = vim.api
	local plugin = require("dbc")
	local workspace = require("dbc.workspace")
	local columns, lines = vim.o.columns, vim.o.lines
	vim.o.columns = 180
	vim.o.lines = 60
	plugin.setup({ connections = {}, ui = { results_height = 12, sidebar_width = 25 } })
	local state = plugin.open()
	local first = state.query
	local first_win = state.query_win
	local second = workspace.query(nil, "SELECT 2")
	local second_results = state.results
	workspace.goto_query(1)
	workspace.vsplit_query()
	local second_win = state.query_win

	assert(state.query == second and state.results == second_results)
	assert(api.nvim_win_get_buf(first_win) == first)
	assert(api.nvim_win_get_buf(second_win) == second)
	assert(api.nvim_win_get_config(second_win).col > api.nvim_win_get_config(first_win).col)

	local completed
	state.bindings[second] = { profile = { name = "pane-test" }, database = "test" }
	state.runner.run = function(_, _, _, callback)
		completed = callback
		return function() end
	end
	workspace.run()
	vim.fn.maparg("<C-h>", "n", false, true).callback()
	completed({ duration = 1, code = 0, stderr = "", sets = { { columns = { "value" }, rows = { { "second" } } } } })

	assert(state.query_win == first_win and state.query == first)
	assert(api.nvim_win_get_buf(state.results_win) == state.queries[1].results)
	assert(table.concat(api.nvim_buf_get_lines(second_results, 0, -1, false), "\n"):match("second"))
	assert(state.cells == nil, "Background completion must not change the focused query's cells")

	workspace.next_query()

	assert(api.nvim_win_get_buf(first_win) == second and api.nvim_win_get_buf(second_win) == second)
	assert(state.cells == state.queries[2].cells and next(state.cells))

	workspace.goto_query(1)
	workspace.split_query()
	local third = state.query
	local third_win = state.query_win

	assert(third ~= first and third ~= second)
	assert(#state.query_panes == 3)
	assert(api.nvim_win_get_config(third_win).row > api.nvim_win_get_config(first_win).row)
	assert(api.nvim_win_get_buf(first_win) == first)

	workspace.hide()

	for _, pane in ipairs(state.query_panes) do
		assert(not api.nvim_win_is_valid(pane.win))
	end

	plugin.open()

	assert(state.query == third)

	for _, pane in ipairs(state.query_panes) do
		assert(api.nvim_win_is_valid(pane.win))
		assert(api.nvim_win_get_buf(pane.win) == pane.buf)
	end

	workspace.close_query_pane()

	assert(#state.query_panes == 2 and #state.queries == 3)
	assert(api.nvim_buf_is_valid(third))

	workspace.close_query()

	for _, pane in ipairs(state.query_panes) do
		assert(pane.buf ~= first)
	end

	api.nvim_buf_delete(second, { force = true })
	vim.wait(100, function()
		return state.query == third
	end)

	for _, pane in ipairs(state.query_panes) do
		assert(pane.buf == third and api.nvim_win_get_buf(pane.win) == third)
	end

	workspace.close_query_pane()
	workspace.close_query_pane()

	assert(#state.query_panes == 1 and state.query == third)

	workspace.close()

	for _, pane in ipairs(state.query_panes) do
		assert(not api.nvim_win_is_valid(pane.win))
	end

	vim.fn.delete(state.storage)
	vim.o.columns = columns
	vim.o.lines = lines
end

return M

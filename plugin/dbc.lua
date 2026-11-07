if vim.g.loaded_dbc then
	return
end

vim.g.loaded_dbc = true

vim.api.nvim_create_user_command("Dbc", function(args)
	local ok, err = pcall(require("dbc").command, args)

	if not ok then
		vim.notify(tostring(err), vim.log.levels.ERROR, { title = "dbc" })
	end
end, {
	desc = "Database workspace",
	nargs = "?",
	range = true,
	complete = function()
		return {
			"open",
			"connect",
			"query",
			"next_query",
			"previous_query",
			"pick_query",
			"close_query",
			"actions",
			"run",
			"cancel",
			"refresh",
			"close",
		}
	end,
})

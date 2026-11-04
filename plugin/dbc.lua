if vim.g.loaded_dbc then
	return
end

vim.g.loaded_dbc = true

-- Rename dbc and Dbc when adapting this template.
vim.api.nvim_create_user_command("Dbc", function()
	require("dbc").greet()
end, { desc = "Show the plugin greeting" })

local M = {}
local defaults = {
	message = "Hello from dbc!",
}
M.config = vim.deepcopy(defaults)

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

function M.greet()
	vim.notify(M.config.message, vim.log.levels.INFO, { title = "dbc" })
end

return M

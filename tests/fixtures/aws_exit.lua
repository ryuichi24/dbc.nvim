-- Leave the native AWS provider open; VimLeavePre must stop its process group.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local profile = vim.json.decode(vim.env.DBC_AWS_CONFIG)
local runner = require("dbc.execution").new({ timeout_ms = 8000, max_output_bytes = 10000 })
local finished
runner:run({ profile = profile, database = "app" }, "SELECT 1", function(result)
	assert(not result.error and result.code == 0, vim.inspect(result))

	finished = true
end)

assert(vim.wait(10000, function()
	return finished
end))

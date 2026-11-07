-- Leave a provider session open to exercise the real VimLeavePre lifecycle.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local runner = require("dbc.execution").new({ timeout_ms = 3000, max_output_bytes = 10000 })
local finished
runner:run(
	{
		profile = {
			name = "exit-test",
			executable = vim.env.DBC_TEST_CLIENT,
			provider = {
				name = "command",
				command = {
					vim.v.progpath,
					"--headless",
					"-u",
					"NONE",
					"-i",
					"NONE",
					"-l",
					"tests/fixtures/provider_helper.lua",
				},
				options = { log = vim.env.DBC_TEST_LOG },
			},
		},
		database = "app",
	},
	"SELECT 1",
	function(result)
		assert(not result.error and result.code == 0, vim.inspect(result))

		finished = true
	end
)

assert(vim.wait(5000, function()
	return finished
end))

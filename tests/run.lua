-- Run from the repository root with make test.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local original_notify = vim.notify
local ok, err = xpcall(function()
	local plugin = require("dbc")
	plugin.setup({ message = "Test greeting" })
	local notification
	vim.notify = function(message, level, opts)
		notification = { message = message, level = level, title = opts.title }
	end
	vim.cmd("runtime plugin/dbc.lua")
	vim.cmd("Dbc")

	assert(notification, "Dbc should send a notification")
	assert(notification.message == "Test greeting", "The command should use the configured greeting")
	assert(notification.level == vim.log.levels.INFO, "The greeting should use INFO level")
	assert(notification.title == "dbc", "The greeting should have the plugin title")

	-- A second load must leave the existing command intact.
	vim.cmd("runtime plugin/dbc.lua")
	plugin.setup()
	vim.cmd("Dbc")

	assert(notification.message == "Hello from dbc!", "setup() should restore the default greeting")
end, debug.traceback)
vim.notify = original_notify

if not ok then
	io.stderr:write(err .. "\n")
	vim.cmd("cquit 1")
end

print("All plugin tests passed.")

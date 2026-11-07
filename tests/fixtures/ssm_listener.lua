-- A child of the fake AWS process; group cleanup must close this listener too.
local server = vim.uv.new_tcp()
assert(server:bind("127.0.0.1", tonumber(arg[1])))
assert(server:listen(16, function(err)
	assert(not err, err)

	local client = vim.uv.new_tcp()
	server:accept(client)
	client:close()
end))

vim.wait(60000, function()
	return false
end)

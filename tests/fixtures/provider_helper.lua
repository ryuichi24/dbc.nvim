-- Noninteractive helper fixture; executed in a separate Neovim process.
local input = vim.json.decode(io.read("*a"))
local action = arg[1]

if input.options.delay then
	vim.uv.sleep(input.options.delay)
end

if input.options.invalid and action ~= "close" then
	io.write("not json")
	return
end

if input.options.fail then
	io.stderr:write("helper failed")
	vim.cmd("cquit 1")
end

assert(input.id and input.options.log)

vim.fn.writefile({ action .. ":" .. input.id }, input.options.log, "a")

if action == "open" then
	io.write(vim.json.encode({ session = { owner = input.id } }))
elseif action == "resolve" then
	assert(input.session.owner == input.id)
	assert(input.database == "app")

	io.write(vim.json.encode({
		connection = { host = "127.0.0.1", port = 13360, user = "iam_user", enable_cleartext_plugin = true },
		credentials = { password = "fresh-iam-token" },
		env = { DBC_PROVIDER_TEST = "yes" },
	}))
elseif action == "close" then
	io.write("{}")
else
	error("Unexpected helper action")
end

-- Fake AWS CLI: only local processes/sockets, never cloud requests.
local service, action = arg[1], arg[2]
local mode = vim.env.DBC_AWS_MODE
local log = vim.env.DBC_AWS_LOG
vim.fn.writefile({ vim.json.encode(vim.list_slice(arg)) }, log, "a")

local function option(name)
	for index, value in ipairs(arg) do
		if value == name then
			return arg[index + 1]
		end
	end
end

local function emit(value)
	io.write(vim.json.encode(value))
end

if service == "sts" then
	if mode == "expired" then
		io.stderr:write("SSO session expired")
		vim.cmd("cquit 1")
	end

	emit({ Account = "test-account" })
elseif action == "describe-db-clusters" then
	if mode == "malformed" then
		io.write("not JSON")
		return
	end

	emit({
		DBClusters = {
			{
				Endpoint = "writer.rds.test",
				ReaderEndpoint = mode ~= "missing_reader" and "reader.rds.test" or vim.NIL,
			},
		},
	})
elseif action == "describe-db-instances" then
	emit({ DBInstances = { { Endpoint = { Address = "instance.rds.test" } } } })
elseif action == "list-tasks" then
	emit({ taskArns = mode == "missing_task" and {} or { "arn:aws:ecs:test:task/test-cluster/task-id" } })
elseif action == "describe-tasks" then
	emit({
		tasks = {
			{
				containers = {
					{ name = "bastion", runtimeId = mode == "missing_container" and vim.NIL or "runtime-id" },
				},
			},
		},
	})
elseif action == "generate-db-auth-token" then
	if mode == "token_error" then
		io.stderr:write("token generation denied")
		vim.cmd("cquit 1")
	end

	local count = 0

	for _, line in ipairs(vim.fn.readfile(log)) do
		local entry = vim.json.decode(line)

		if entry[2] == "generate-db-auth-token" then
			count = count + 1
		end
	end

	io.write("fresh-token-" .. count .. "\n")
elseif service == "ssm" and action == "start-session" then
	if mode == "early_exit" then
		vim.cmd("cquit 1")
	end

	local child

	if mode ~= "no_port" then
		local parameters = vim.json.decode(option("--parameters"))
		child = vim.system({
			vim.v.progpath,
			"--headless",
			"-u",
			"NONE",
			"-i",
			"NONE",
			"-l",
			"tests/fixtures/ssm_listener.lua",
			parameters.localPortNumber[1],
		})
	end

	vim.fn.writefile(
		{ vim.json.encode({ parent = vim.fn.getpid(), child = child and child.pid }) },
		vim.env.DBC_AWS_PID
	)
	vim.wait(60000, function()
		return false
	end)
else
	error("Unexpected fake AWS operation: " .. tostring(service) .. " " .. tostring(action))
end

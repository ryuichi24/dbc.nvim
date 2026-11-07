local M = {}
local uv = vim.uv

local function wait(predicate)
	assert(vim.wait(10000, predicate), "AWS provider operation did not complete")
end

local function free_port()
	local tcp = uv.new_tcp()
	assert(tcp:bind("127.0.0.1", 0))

	local port = tcp:getsockname().port
	local closed
	tcp:close(function()
		closed = true
	end)
	wait(function()
		return closed
	end)
	return port
end

function M.run()
	local directory = vim.fn.tempname()
	vim.fn.mkdir(directory)
	local saved = {
		PATH = vim.env.PATH,
		DBC_AWS_LOG = vim.env.DBC_AWS_LOG,
		DBC_AWS_PID = vim.env.DBC_AWS_PID,
		DBC_AWS_MODE = vim.env.DBC_AWS_MODE,
	}
	local sessions, listeners = {}, {}
	local ok, err = xpcall(function()
		local executable = directory .. "/aws"
		local log = directory .. "/aws.log"
		local pid_file = directory .. "/pid.json"
		local ca = directory .. "/ca.pem"
		vim.fn.writefile({ "test CA" }, ca)
		vim.fn.writefile({
			"#!/bin/sh",
			"exec "
				.. vim.fn.shellescape(vim.v.progpath)
				.. ' --headless -u NONE -i NONE -l tests/fixtures/aws.lua "$@"',
		}, executable)
		vim.fn.writefile({ "#!/bin/sh", "exit 0" }, directory .. "/session-manager-plugin")
		vim.fn.setfperm(executable, "rwx------")
		vim.fn.setfperm(directory .. "/session-manager-plugin", "rwx------")
		vim.env.PATH = directory .. ":" .. saved.PATH
		vim.env.DBC_AWS_LOG, vim.env.DBC_AWS_PID = log, pid_file
		local provider = require("dbc.providers").get({ provider = "aws_ssm_rds_iam" })
		local context = { limits = { timeout_ms = 8000, max_output_bytes = 10000 }, on_error = function() end }

		local function profile(overrides, adapter)
			return {
				name = "rds",
				adapter = adapter or "mysql",
				provider = vim.tbl_extend("force", {
					name = "aws_ssm_rds_iam",
					aws_executable = executable,
					aws_profile = "core_dev",
					region = "ap-northeast-1",
					db_user = "test_read",
					ssl_ca = ca,
					local_port = free_port(),
					rds_identifier = "test-cluster",
					ecs_cluster = "test-cluster",
					ecs_service = "test-bastion",
					endpoint = "reader",
					ready_timeout_ms = 3000,
				}, overrides or {}),
			}
		end

		local function connect(config, mode)
			vim.env.DBC_AWS_MODE = mode or "healthy"
			local session = provider.create(config, context)
			table.insert(sessions, session)
			local finished, problem
			local cancel = session.connect(function(value)
				problem, finished = value, true
			end)
			return session,
				function()
					wait(function()
						return finished
					end)
					return problem
				end,
				cancel
		end

		local function close(session)
			local finished
			session.close(function(problem)
				assert(not problem, problem)

				finished = true
			end)
			wait(function()
				return finished
			end)
		end

		local config = profile()
		local session, completed = connect(config)

		assert(not completed())

		local first_token

		for index = 1, 2 do
			local resolution
			session.resolve("app", function(problem, value)
				assert(not problem, problem)

				resolution = value
			end)
			wait(function()
				return resolution ~= nil
			end)

			assert(resolution.connection.host == "127.0.0.1")
			assert(resolution.connection.port == config.provider.local_port)
			assert(resolution.connection.ssl_mode == "VERIFY_CA" and resolution.connection.enable_cleartext_plugin)
			assert(resolution.connection.user == "test_read")
			assert(resolution.credentials.password == "fresh-token-" .. index)

			if index == 1 then
				first_token = resolution.credentials.password
			end
		end

		local calls = vim.tbl_map(vim.json.decode, vim.fn.readfile(log))
		local starts = 0

		for _, call in ipairs(calls) do
			local function option(key)
				for index, value in ipairs(call) do
					if value == key then
						return call[index + 1]
					end
				end
			end

			assert(option("--profile") == "core_dev" and option("--region") == "ap-northeast-1")
			assert(not table.concat(call, " "):find(first_token, 1, true), "Tokens must not be in argv")

			if call[2] == "generate-db-auth-token" then
				assert(option("--hostname") == "reader.rds.test")
				assert(option("--port") == "3306")
			elseif call[2] == "start-session" then
				starts = starts + 1

				assert(option("--target") == "ecs:test-cluster_task-id_runtime-id")

				local parameters = vim.json.decode(option("--parameters"))

				assert(
					parameters.host[1] == "reader.rds.test"
						and parameters.localPortNumber[1] == tostring(config.provider.local_port)
				)
			end
		end

		assert(starts == 1, "Token refresh must reuse the existing tunnel")

		vim.env.DBC_AWS_MODE = "token_error"
		local token_error
		session.resolve("app", function(problem)
			token_error = problem
		end)
		wait(function()
			return token_error ~= nil
		end)

		assert(token_error:match("token generation denied"))

		close(session)
		local port_released
		wait(function()
			local probe = uv.new_tcp()
			port_released = probe:bind("127.0.0.1", config.provider.local_port) and probe:listen(1, function() end)
			probe:close()
			return port_released
		end)

		-- Existing unrelated listeners are never killed or reused as an SSM tunnel.
		local occupied = uv.new_tcp()
		table.insert(listeners, occupied)

		assert(occupied:bind("127.0.0.1", 0))
		assert(occupied:listen(1, function() end))

		local busy, busy_done = connect(profile({ local_port = occupied:getsockname().port }))

		assert(busy_done():match("already in use"))
		assert(not occupied:is_closing())

		close(busy)

		for mode, expected in pairs({
			expired = "aws sso login",
			missing_task = "No running ECS",
			missing_container = "runtime ID",
			missing_reader = "endpoint was not found",
			malformed = "invalid AWS JSON",
			no_port = "Timed out waiting",
			early_exit = "SSM tunnel exited",
		}) do
			local failed, failed_done = connect(profile({ ready_timeout_ms = mode == "no_port" and 100 or 3000 }), mode)

			assert(failed_done():find(expected, 1, true), mode)

			close(failed)
		end

		-- PostgreSQL retains the real hostname for TLS identity and uses hostaddr
		-- for the forwarded TCP destination; IAM signs the remote database port.
		local pg, pg_done = connect(profile({ rds_host = "pg.rds.test", target = "ecs:explicit-target" }, "postgres"))

		assert(not pg_done())

		local pg_result
		pg.resolve("app", function(problem, value)
			assert(not problem, problem)

			pg_result = value
		end)
		wait(function()
			return pg_result ~= nil
		end)

		assert(pg_result.connection.host == "pg.rds.test" and pg_result.env.PGHOSTADDR == "127.0.0.1")
		assert(pg_result.connection.sslmode == "verify-full" and pg_result.env.PGSSLROOTCERT == ca)

		local pg_call = vim.json.decode(vim.fn.readfile(log)[#vim.fn.readfile(log)])

		assert(pg_call[2] == "generate-db-auth-token")
		assert(table.concat(pg_call, " "):find("--hostname pg.rds.test --port 5432", 1, true))

		close(pg)

		for _, variant in ipairs({ { endpoint = "writer" }, { rds_type = "instance", endpoint = "writer" } }) do
			local alternative, alternative_done = connect(profile(variant))

			assert(not alternative_done())

			local value
			alternative.resolve("app", function(problem, resolution)
				assert(not problem, problem)

				value = resolution
			end)
			wait(function()
				return value ~= nil
			end)
			local last = vim.json.decode(vim.fn.readfile(log)[#vim.fn.readfile(log)])

			assert(table.concat(last, " "):find(variant.rds_type and "instance.rds.test" or "writer.rds.test", 1, true))

			close(alternative)
		end

		local missing_ca, missing_ca_done = connect(profile({ ssl_ca = directory .. "/missing.pem" }))

		assert(missing_ca_done():match("CA file is not readable"))

		close(missing_ca)

		-- Losing the AWS parent must fail further resolutions, then close the
		-- still-owned plugin child rather than leaving its listening port behind.
		local dead, dead_done = connect(profile({ rds_host = "fixed.rds.test", target = "ecs:fixed" }))

		assert(not dead_done())

		local owner = vim.json.decode(vim.fn.readfile(pid_file)[1])

		assert(uv.kill(owner.parent, 9))

		wait(function()
			return not uv.kill(owner.parent, 0)
		end)
		local dead_error
		dead.resolve("app", function(problem)
			dead_error = problem
		end)

		assert(dead_error:match("SSM tunnel exited"))

		close(dead)

		-- Cancellation while the forwarding process is starting also closes its group.
		local pending, _, cancel = connect(profile({ rds_host = "fixed.rds.test", target = "ecs:fixed" }), "no_port")
		local previous = vim.fn.readfile(pid_file)[1]
		wait(function()
			return vim.fn.readfile(pid_file)[1] ~= previous
		end)
		cancel()
		close(pending)

		-- Exercise the native provider through the real runner and editor exit.
		local client = directory .. "/mysql"
		vim.fn.writefile({
			"#!/bin/sh",
			'[ -n "$MYSQL_PWD" ] || exit 1',
			"cat >/dev/null",
			"printf '%s' '<resultset statement=\"select\"><row><field name=\"id\">1</field></row></resultset>'",
		}, client)
		vim.fn.setfperm(client, "rwx------")
		local exit_profile = profile({ rds_host = "fixed.rds.test", target = "ecs:fixed" })
		exit_profile.executable = client
		local exited = vim.system(
			{ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", "tests/fixtures/aws_exit.lua" },
			{
				env = { DBC_AWS_CONFIG = vim.json.encode(exit_profile), DBC_AWS_MODE = "healthy" },
				timeout = 20000,
			}
		):wait()

		assert(exited.code == 0, exited.stderr)

		local probe = uv.new_tcp()

		assert(probe:bind("127.0.0.1", exit_profile.provider.local_port))
		assert(probe:listen(1, function() end), "Native SSM listener must be gone after editor exit")

		probe:close()
	end, debug.traceback)
	local closing = #sessions

	for _, session in ipairs(sessions) do
		session.close(function()
			closing = closing - 1
		end)
	end

	vim.wait(10000, function()
		return closing == 0
	end)

	for _, listener in ipairs(listeners) do
		listener:close()
	end

	for _, key in ipairs({ "PATH", "DBC_AWS_LOG", "DBC_AWS_PID", "DBC_AWS_MODE" }) do
		vim.env[key] = saved[key]
	end

	vim.fn.delete(directory, "rf")

	if not ok then
		error(err)
	end
end

return M

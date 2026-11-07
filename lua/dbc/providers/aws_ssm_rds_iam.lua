local M = {}
local uv = vim.uv

local function dispose(handle)
	if handle and not handle:is_closing() then
		handle:close()
	end
end

local function string_option(spec, key)
	assert(type(spec[key]) == "string" and spec[key] ~= "", "SSM provider requires " .. key)
end

function M.validate(profile)
	local spec = profile.provider
	assert(type(spec) == "table", "SSM provider requires a configuration table")
	assert(
		not profile.adapter or profile.adapter == "mysql" or profile.adapter == "postgres",
		"SSM IAM supports mysql or postgres"
	)

	for _, key in ipairs({ "aws_profile", "region", "db_user", "ssl_ca" }) do
		string_option(spec, key)
	end

	if not spec.rds_host then
		string_option(spec, "rds_identifier")
	else
		string_option(spec, "rds_host")
	end

	if not spec.target then
		string_option(spec, "ecs_cluster")
		string_option(spec, "ecs_service")
	else
		string_option(spec, "target")
	end

	for _, key in ipairs({ "local_port", "remote_port" }) do
		local value = spec[key]

		if key == "local_port" or value ~= nil then
			assert(
				type(value) == "number" and value % 1 == 0 and value >= 1 and value <= 65535,
				key .. " must be a port number"
			)
		end
	end

	assert(
		not spec.rds_type or spec.rds_type == "cluster" or spec.rds_type == "instance",
		"rds_type must be cluster or instance"
	)
	assert(
		not spec.endpoint or spec.endpoint == "reader" or spec.endpoint == "writer",
		"endpoint must be reader or writer"
	)
	assert(not (spec.rds_type == "instance" and spec.endpoint == "reader"), "Reader endpoints require an RDS cluster")
	assert(
		not spec.ready_timeout_ms or (type(spec.ready_timeout_ms) == "number" and spec.ready_timeout_ms > 0),
		"ready_timeout_ms must be positive"
	)
end

function M.create(profile, context)
	M.validate(profile)
	local spec = profile.provider
	local remote_port = spec.remote_port or (profile.adapter == "postgres" and 5432 or 3306)
	local ca_file = vim.fn.expand(spec.ssl_ca)
	local state = { jobs = {}, host = spec.rds_host, target = spec.target }
	local session = {}

	local function signal(number)
		if state.tunnel then
			-- detach=true creates an owned process group on Unix, including the
			-- session-manager-plugin child. Never discover processes by local port.
			local ok = uv.kill(-state.tunnel.pid, number)

			if not ok and not state.exited then
				state.tunnel:kill(number)
			end
		end
	end

	local function cancel_jobs()
		for job in pairs(state.jobs) do
			job.cancel()
		end
	end

	local function finish_connect(err)
		if state.connect_done then
			local done = state.connect_done
			state.connect_done = nil
			dispose(state.poll)
			dispose(state.probe)
			state.poll, state.probe = nil, nil
			state.connected = not err
			done(err)
		end
	end

	local function aws(args, label, json, done)
		local argv = { spec.aws_executable or "aws" }
		vim.list_extend(argv, args)
		vim.list_extend(
			argv,
			{ "--profile", spec.aws_profile, "--region", spec.region, "--no-cli-pager", "--output", "json" }
		)
		local job = {}
		state.jobs[job] = true
		local ok, cancel = pcall(require("dbc.process").run, argv, nil, context.limits, function(result)
			state.jobs[job] = nil

			if state.closed then
				return
			end

			if result.error or result.code ~= 0 then
				local message = label .. ": " .. (result.error or result.stderr)

				if label == "AWS authentication" then
					message = message .. "; run aws sso login --profile " .. spec.aws_profile
				end

				done(message)
			elseif json then
				local decoded, value = pcall(vim.json.decode, result.stdout)

				if decoded and type(value) == "table" then
					done(nil, value)
				else
					done(label .. ": invalid AWS JSON response")
				end
			else
				done(nil, result.stdout:gsub("[\r\n]+$", ""))
			end
		end, { AWS_PAGER = "", AWS_CLI_AUTO_PROMPT = "off" })

		if ok then
			job.cancel = cancel
		else
			state.jobs[job] = nil
			done(label .. ": " .. tostring(cancel))
		end

		return ok and cancel or nil
	end

	local function start_tunnel()
		if state.closed then
			return
		end

		local parameters = vim.json.encode({
			host = { state.host },
			portNumber = { tostring(remote_port) },
			localPortNumber = { tostring(spec.local_port) },
		})
		local argv = {
			spec.aws_executable or "aws",
			"ssm",
			"start-session",
			"--target",
			state.target,
			"--document-name",
			"AWS-StartPortForwardingSessionToRemoteHost",
			"--parameters",
			parameters,
			"--profile",
			spec.aws_profile,
			"--region",
			spec.region,
			"--no-cli-pager",
		}
		local bytes = 0
		local diagnostics = {}
		local function output(err, data)
			bytes = bytes + (data and #data or 0)

			if err or bytes > context.limits.max_output_bytes then
				state.dead = "SSM tunnel diagnostic output failed or exceeded the byte limit"
				signal(9)
			end
		end

		local ok, tunnel = pcall(vim.system, argv, {
			detach = true,
			env = { AWS_PAGER = "", AWS_CLI_AUTO_PROMPT = "off" },
			stdout = output,
			stderr = function(err, data)
				output(err, data)

				if data and bytes <= context.limits.max_output_bytes then
					table.insert(diagnostics, data)
				end
			end,
		}, function(result)
			vim.schedule(function()
				state.exited = true

				if not state.closed then
					state.dead = state.dead
						or (
							"SSM tunnel exited (code "
							.. result.code
							.. "): "
							.. table.concat(diagnostics)
							.. "; reopen the dashboard to reconnect"
						)

					if state.connect_done then
						finish_connect(state.dead)
					else
						context.on_error(state.dead)
					end
				end
			end)
		end)

		if not ok then
			finish_connect("Cannot start SSM tunnel: " .. tostring(tunnel))
			return
		end

		state.tunnel = tunnel
		local deadline = uv.hrtime() / 1e6 + (spec.ready_timeout_ms or 15000)
		state.poll = uv.new_timer()
		state.poll:start(
			0,
			100,
			vim.schedule_wrap(function()
				if state.closed or not state.connect_done then
					return
				end

				if not uv.kill(state.tunnel.pid, 0) then
					state.dead = state.dead or "SSM tunnel exited before becoming ready"
				end

				if state.dead or uv.hrtime() / 1e6 >= deadline then
					finish_connect(state.dead or "Timed out waiting for the SSM local forwarding port")
					return
				end

				if state.probe then
					return
				end

				local probe = uv.new_tcp()
				state.probe = probe
				probe:connect(
					"127.0.0.1",
					spec.local_port,
					vim.schedule_wrap(function(err)
						dispose(probe)
						state.probe = nil

						if not err and not state.closed and not state.dead then
							finish_connect(nil)
						end
					end)
				)
			end)
		)
	end

	local function discover_target()
		if state.target then
			start_tunnel()
			return
		end

		aws(
			{ "ecs", "list-tasks", "--cluster", spec.ecs_cluster, "--service-name", spec.ecs_service },
			"ECS task discovery",
			true,
			function(err, value)
				local task = not err and type(value.taskArns) == "table" and value.taskArns[1]

				if type(task) ~= "string" or task == "" then
					finish_connect(err or "No running ECS bastion task found")
					return
				end

				aws(
					{ "ecs", "describe-tasks", "--cluster", spec.ecs_cluster, "--tasks", task },
					"ECS container discovery",
					true,
					function(problem, tasks)
						local details = not problem and type(tasks.tasks) == "table" and tasks.tasks[1]
						local containers = type(details) == "table" and details.containers

						for _, container in ipairs(type(containers) == "table" and containers or {}) do
							if
								type(container) == "table"
								and container.name == (spec.container or "bastion")
								and type(container.runtimeId) == "string"
								and container.runtimeId ~= ""
							then
								local task_id = task:match("([^/]+)$")
								state.target = "ecs:"
									.. spec.ecs_cluster
									.. "_"
									.. task_id
									.. "_"
									.. container.runtimeId
								start_tunnel()
								return
							end
						end

						finish_connect(problem or "ECS bastion container runtime ID was not found")
					end
				)
			end
		)
	end

	local function discover_host()
		if state.host then
			discover_target()
			return
		end

		local instance = spec.rds_type == "instance"
		local args = instance and { "rds", "describe-db-instances", "--db-instance-identifier", spec.rds_identifier }
			or { "rds", "describe-db-clusters", "--db-cluster-identifier", spec.rds_identifier }
		aws(args, "RDS endpoint discovery", true, function(err, value)
			local record = not err and (instance and value.DBInstances or value.DBClusters)
			record = type(record) == "table" and record[1]
			local host

			if type(record) == "table" then
				if instance then
					host = type(record.Endpoint) == "table" and record.Endpoint.Address
				elseif spec.endpoint == "reader" then
					host = record.ReaderEndpoint
				else
					host = record.Endpoint
				end
			end

			if type(host) ~= "string" or host == "" then
				finish_connect(err or "RDS endpoint was not found")
				return
			end

			state.host = host
			discover_target()
		end)
	end

	function session.connect(done)
		if state.closed or state.connected or state.connect_done then
			done("SSM session is closed or already connecting/connected")
			return
		end

		state.connect_done = done

		if vim.fn.has("win32") == 1 then
			finish_connect("SSM provider currently requires Unix process-group support")
			return
		end

		if vim.fn.executable(spec.aws_executable or "aws") ~= 1 or vim.fn.executable("session-manager-plugin") ~= 1 then
			finish_connect("Install the AWS CLI and session-manager-plugin before connecting")
			return
		end

		if vim.fn.filereadable(ca_file) ~= 1 then
			finish_connect("RDS CA file is not readable: " .. ca_file)
			return
		end

		local reservation = uv.new_tcp()
		local bound = reservation:bind("127.0.0.1", spec.local_port)
		local listening = bound and reservation:listen(1, function() end)
		dispose(reservation)

		if not listening then
			finish_connect("Local forwarding port is already in use: " .. spec.local_port)
			return
		end

		aws({ "sts", "get-caller-identity" }, "AWS authentication", true, function(err)
			if err then
				finish_connect(err)
			else
				discover_host()
			end
		end)
		return function()
			cancel_jobs()
			finish_connect("SSM connection preparation cancelled")
		end
	end

	function session.resolve(_, done)
		if state.tunnel and not uv.kill(state.tunnel.pid, 0) then
			state.dead = state.dead or "SSM tunnel exited; reopen the dashboard to reconnect"
		end

		if state.closed or not state.connected or state.dead or state.exited then
			done(state.dead or "SSM tunnel is not connected")
			return
		end

		return aws(
			{
				"rds",
				"generate-db-auth-token",
				"--hostname",
				state.host,
				"--port",
				tostring(remote_port),
				"--username",
				spec.db_user,
			},
			"RDS IAM token generation",
			false,
			function(err, token)
				if err or token == "" or state.dead then
					done(err or state.dead or "AWS returned an empty IAM token")
					return
				end

				local postgres = profile.adapter == "postgres"
				done(nil, {
					connection = postgres and {
						host = state.host,
						port = spec.local_port,
						user = spec.db_user,
						sslmode = "verify-full",
					} or {
						host = "127.0.0.1",
						port = spec.local_port,
						user = spec.db_user,
						protocol = "TCP",
						ssl_ca = ca_file,
						ssl_mode = "VERIFY_CA",
						enable_cleartext_plugin = true,
					},
					credentials = { password = token },
					env = postgres and { PGHOSTADDR = "127.0.0.1", PGSSLROOTCERT = ca_file } or nil,
				})
			end
		)
	end

	function session.close(done)
		if state.closed then
			if state.close_done then
				done(state.close_error)
			else
				table.insert(state.close_waiters, done)
			end

			return
		end

		state.closed = true
		state.close_waiters = { done }

		local function finished(err)
			state.close_done, state.close_error = true, err

			for _, callback in ipairs(state.close_waiters) do
				callback(err)
			end

			state.close_waiters = {}
		end

		finish_connect("SSM session closed")
		cancel_jobs()
		dispose(state.poll)
		dispose(state.probe)

		if not state.tunnel then
			finished(nil)
			return
		end

		signal(15)
		local started = uv.hrtime() / 1e6
		local grace = math.min(250, context.limits.timeout_ms / 4)
		local killed_at
		local timer = uv.new_timer()
		timer:start(
			25,
			25,
			vim.schedule_wrap(function()
				local elapsed = uv.hrtime() / 1e6 - started

				if elapsed >= grace and not killed_at then
					signal(9)
					killed_at = elapsed
				end

				-- A killed descendant can remain a zombie until its new parent reaps
				-- it. Allow signal delivery before treating such groups as cleaned up.
				if
					state.exited and (not uv.kill(-state.tunnel.pid, 0) or (killed_at and elapsed - killed_at >= 50))
				then
					dispose(timer)
					finished(nil)
				elseif elapsed >= context.limits.timeout_ms then
					signal(9)
					dispose(timer)
					finished("Timed out stopping the owned SSM process group")
				end
			end)
		)
	end

	return session
end

return M

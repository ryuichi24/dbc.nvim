local M = {}
local runners = {}
local draining = {}

vim.api.nvim_create_autocmd("VimLeavePre", {
	group = vim.api.nvim_create_augroup("DbcExecutionCleanup", { clear = true }),
	callback = function()
		for runner in pairs(runners) do
			runner:close()
		end

		local deadline = vim.uv.hrtime() / 1e6

		for _, expires in pairs(draining) do
			deadline = math.max(deadline, expires)
		end

		local completed = vim.wait(math.max(1, math.ceil(deadline - vim.uv.hrtime() / 1e6)), function()
			return not next(draining)
		end)

		if not completed then
			vim.notify("dbc: request cleanup timed out", vim.log.levels.ERROR)
		end

		require("dbc.connections").wait_for_cleanup()
	end,
})

local function release(value)
	if value and value.release then
		local ok, err = pcall(value.release)

		if not ok then
			vim.notify("dbc request cleanup: " .. tostring(err), vim.log.levels.ERROR)
		end
	end
end

function M.new(limits)
	local runner = { connections = require("dbc.connections").new(limits), jobs = {}, closed = false }
	runners[runner] = true

	function runner:run(binding, sql, callback)
		assert(not self.closed, "Execution runner is closed")
		local job = { started = vim.uv.hrtime() }
		self.jobs[job] = true
		local timer

		local function finish(result)
			if job.finished then
				return
			end

			job.finished = true
			self.jobs[job] = nil

			if timer and not timer:is_closing() then
				timer:stop()
				timer:close()
			end

			release(job.resolution)
			job.resolution = nil

			if self.closed and not next(self.jobs) then
				draining[self] = nil
			end

			result.error = job.reason or result.error
			result.duration = (vim.uv.hrtime() - job.started) / 1e6
			callback(result)
		end

		local function cancel(reason)
			if job.finished then
				return
			end

			job.reason = job.reason or reason

			if job.cancel_process then
				job.cancel_process()
			else
				finish({ code = -1, stdout = "", stderr = "" })

				if job.cancel_prepare then
					job.cancel_prepare()
				end
			end
		end

		job.cancel = function()
			cancel("Cancelled; server-side cancellation or rollback is not guaranteed")
		end
		timer = vim.defer_fn(function()
			cancel("Connection preparation or query timed out")
		end, limits.timeout_ms)
		job.cancel_prepare = self.connections:resolve(binding.profile, binding.database, function(err, resolution)
			if job.finished then
				release(resolution)
				return
			end

			if err then
				finish({ code = -1, error = err, stdout = "", stderr = "" })
				return
			end

			job.resolution = resolution
			local ok, request = pcall(function()
				local overrides = resolution.connection or {}

				for _, key in ipairs({ "name", "adapter", "provider", "executable", "password" }) do
					assert(overrides[key] == nil, "Provider cannot override connection field: " .. key)
				end

				local profile = vim.tbl_deep_extend("force", vim.deepcopy(binding.profile), overrides)
				local adapter = require("dbc.adapters").get(binding.profile)
				local built = adapter.request(profile, binding.database, sql, resolution.credentials)
				assert(vim.fn.executable(built.argv[1]) == 1, "Client executable not found: " .. built.argv[1])
				built.env = vim.tbl_extend("force", built.env or {}, resolution.env or {})
				return built
			end)

			if not ok then
				finish({ code = -1, error = tostring(request), stdout = "", stderr = "" })
				return
			end

			local spawned, stop = pcall(
				require("dbc.process").run,
				request.argv,
				request.stdin,
				limits,
				function(result)
					if not result.error and result.code == 0 and not job.reason then
						local decoded, sets = pcall(request.decode, result.stdout)

						if decoded then
							result.sets = sets
						else
							result.decode_error = tostring(sets)
						end
					end

					finish(result)
				end,
				request.env
			)

			if spawned then
				job.cancel_process = stop
			else
				finish({ code = -1, error = tostring(stop), stdout = "", stderr = "" })
			end
		end)
		return job.cancel
	end

	function runner:close()
		if self.closed then
			return
		end

		self.closed = true
		runners[self] = nil

		for job in pairs(self.jobs) do
			job.cancel()
		end

		if next(self.jobs) then
			draining[self] = vim.uv.hrtime() / 1e6 + limits.timeout_ms
		end

		self.connections:close()
	end

	return runner
end

return M

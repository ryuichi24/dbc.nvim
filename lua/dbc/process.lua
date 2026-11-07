local M = {}

function M.run(argv, sql, limits, callback, env)
	local state = { bytes = 0, stdout = {}, stderr = {}, started = vim.uv.hrtime() }
	local process

	local function stop(reason)
		state.reason = state.reason or reason

		if process then
			process:kill(9)
		end
	end

	local function collect(target)
		return function(err, data)
			if err then
				stop(tostring(err))
			end

			if data and not state.reason then
				state.bytes = state.bytes + #data

				if state.bytes > limits.max_output_bytes then
					stop("Output byte limit exceeded; results are incomplete")
				else
					table.insert(target, data)
				end
			end
		end
	end

	process = vim.system(argv, {
		stdin = sql,
		env = env,
		stdout = collect(state.stdout),
		stderr = collect(state.stderr),
		timeout = limits.timeout_ms,
	}, function(result)
		vim.schedule(function()
			callback({
				code = result.code,
				stdout = table.concat(state.stdout),
				stderr = table.concat(state.stderr),
				error = state.reason or (result.code == 124 and "Query timed out" or nil),
				duration = (vim.uv.hrtime() - state.started) / 1e6,
			})
		end)
	end)
	return function()
		stop("Cancelled; server-side cancellation or rollback is not guaranteed")
	end
end

return M

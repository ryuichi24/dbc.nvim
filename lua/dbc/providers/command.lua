local M = {}

function M.validate(profile)
	local spec = profile.provider
	assert(
		type(spec) == "table" and type(spec.command) == "table" and #spec.command > 0,
		"Command provider requires command argv"
	)

	for _, arg in ipairs(spec.command) do
		assert(type(arg) == "string", "Provider command arguments must be strings")
	end
end

function M.create(profile, context)
	M.validate(profile)
	local spec = profile.provider
	local id = vim.fn.sha256(tostring(vim.uv.hrtime()) .. tostring({}))
	local session, closed

	local function call(action, database, done)
		local argv = vim.list_extend(vim.deepcopy(spec.command), { action })
		local input = vim.json.encode({ id = id, options = spec.options or {}, session = session, database = database })
		local ok, cancel = pcall(require("dbc.process").run, argv, input, context.limits, function(result)
			if result.error or result.code ~= 0 then
				done(result.error or ("Connection helper " .. action .. " failed: " .. result.stderr))
				return
			end

			local decoded, value = pcall(vim.json.decode, result.stdout == "" and "{}" or result.stdout)

			if not decoded or type(value) ~= "table" then
				done("Connection helper " .. action .. " returned invalid JSON")
			else
				done(nil, value)
			end
		end, spec.env)

		if not ok then
			done(tostring(cancel))
			return
		end

		return cancel
	end

	return {
		connect = function(done)
			return call("open", nil, function(err, value)
				if not closed and not err then
					session = value.session
				end

				done(err)
			end)
		end,
		resolve = function(database, done)
			return call("resolve", database, done)
		end,
		close = function(done)
			if closed then
				done(nil)
				return
			end

			closed = true
			call("close", nil, done)
		end,
	}
end

return M

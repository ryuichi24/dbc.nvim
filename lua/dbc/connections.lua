local M = {}
local closing = {}

local function safely(fn, ...)
	if fn then
		local ok, err = pcall(fn, ...)

		if not ok then
			vim.notify("dbc provider cleanup: " .. tostring(err), vim.log.levels.ERROR)
		end
	end
end

local function release(value)
	if type(value) == "table" then
		safely(value.release)
	end
end

function M.new(limits)
	local manager = { entries = {}, operations = {}, closed = false }
	local context = {
		limits = vim.deepcopy(limits),
		on_error = function(err)
			vim.notify("dbc provider: " .. tostring(err), vim.log.levels.ERROR)
		end,
	}

	local function retire(entry)
		if entry.closed then
			return
		end

		entry.closed = true
		manager.entries[entry] = nil
		safely(entry.cancel_connect)

		if entry.session and type(entry.session.close) == "function" then
			closing[entry] = vim.uv.hrtime() / 1e6 + limits.timeout_ms
			local completed = false
			local function done(err)
				if completed then
					return
				end

				completed = true
				closing[entry] = nil

				if err then
					context.on_error(err)
				end
			end
			local ok, err = pcall(entry.session.close, done)

			if not ok then
				done(tostring(err))
			end
		end
	end

	function manager:resolve(profile, database, callback)
		assert(not self.closed, "Connection manager is closed")
		local operation = {}
		self.operations[operation] = true
		local entry

		local function finish(err, value)
			if operation.finished then
				release(value)
				return
			end

			operation.finished = true
			self.operations[operation] = nil

			if entry then
				entry.waiters[operation] = nil
			end

			if err then
				release(value)
				callback(tostring(err))
			else
				callback(nil, value)
			end
		end

		local function resolve()
			if operation.finished or entry.closed then
				return
			end

			local ok, cancel = pcall(entry.session.resolve, database, function(err, value)
				vim.schedule(function()
					if not err and type(value) ~= "table" then
						err = "Provider resolve() must return a resolution table"
					end

					finish(err, value)
				end)
			end)

			if ok then
				operation.cancel_prepare = cancel
			else
				finish(cancel)
			end
		end

		operation.cancel = function()
			if operation.finished then
				return
			end

			safely(operation.cancel_prepare)
			finish("Connection preparation cancelled")

			if entry and not entry.ready and not next(entry.waiters) then
				retire(entry)
			end
		end

		-- All provider callbacks, including synchronous implementations, enter the
		-- workspace asynchronously so cancellation handles are installed first.
		vim.schedule(function()
			if operation.finished then
				return
			end

			for _, candidate in pairs(self.entries) do
				if vim.deep_equal(candidate.profile, profile) then
					entry = candidate
					break
				end
			end

			if entry then
				entry.waiters[operation] = resolve

				if entry.ready then
					resolve()
				end

				return
			end

			entry = { name = profile.name, profile = vim.deepcopy(profile), waiters = { [operation] = resolve } }
			local ok, session = pcall(function()
				local provider = require("dbc.providers").get(profile)
				local instance = provider.create(vim.deepcopy(profile), context)
				assert(type(instance) == "table", "Provider create() must return a session")
				entry.session = instance

				for _, method in ipairs({ "connect", "resolve", "close" }) do
					assert(type(instance[method]) == "function", "Provider session requires " .. method .. "()")
				end

				return instance
			end)

			if not ok then
				retire(entry)
				finish(session)
				return
			end

			self.entries[entry] = entry
			local connected = false
			local opened, cancel = pcall(session.connect, function(err)
				vim.schedule(function()
					if connected or entry.closed then
						return
					end

					connected = true
					entry.cancel_connect = nil

					if err then
						retire(entry)

						for waiter in pairs(entry.waiters) do
							waiter.fail(err)
						end
					else
						entry.ready = true

						for _, prepare in pairs(entry.waiters) do
							prepare()
						end
					end
				end)
			end)

			if opened then
				entry.cancel_connect = cancel
			else
				retire(entry)
				finish(cancel)
			end
		end)
		operation.fail = finish
		return operation.cancel
	end

	function manager:close()
		if self.closed then
			return
		end

		self.closed = true

		for operation in pairs(self.operations) do
			operation.cancel()
		end

		for _, entry in pairs(self.entries) do
			retire(entry)
		end
	end

	return manager
end

function M.wait_for_cleanup()
	local deadline = vim.uv.hrtime() / 1e6

	for _, expires in pairs(closing) do
		deadline = math.max(deadline, expires)
	end

	local timeout = math.max(1, math.ceil(deadline - vim.uv.hrtime() / 1e6))
	local ok = vim.wait(timeout, function()
		return not next(closing)
	end)

	if not ok then
		vim.notify("dbc: provider cleanup timed out", vim.log.levels.ERROR)
	end

	return ok
end

return M

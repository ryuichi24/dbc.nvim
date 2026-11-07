local M = {}
local loaders = {}

function M.register(name, loader, opts)
	assert(type(name) == "string" and name ~= "", "Metadata loader requires a name")
	assert(type(loader) == "function", "Metadata loader must be a function")
	assert(not loaders[name] or (opts and opts.replace), "Metadata loader already registered: " .. name)
	loaders[name] = loader
end

function M.unregister(name)
	loaders[name] = nil
end

M.register("columns", function(ctx, done)
	return ctx.fetch_children(function(err, children)
		if err then
			done(err)
			return
		end

		local columns = {}

		for _, child in ipairs(children or {}) do
			if child.kind == "column" then
				table.insert(columns, child)
			end
		end

		done(nil, columns)
	end)
end)

local function cancel_loader(cancel)
	if cancel then
		local ok, err = pcall(cancel)

		if not ok then
			vim.notify("dbc action metadata cleanup: " .. tostring(err), vim.log.levels.ERROR)
		end
	end
end

function M.prepare(action, ctx, done)
	local stopped, cancel, timer
	ctx.metadata = {}
	ctx.metadata_errors = {}

	local function stop()
		stopped = true

		if timer and not timer:is_closing() then
			timer:stop()
			timer:close()
		end
	end

	local function finish(err)
		if stopped then
			return
		end

		stop()
		done(err)
	end

	if ctx.timeout_ms then
		timer = vim.defer_fn(function()
			local pending = cancel
			finish("Action metadata preparation timed out")
			cancel_loader(pending)
		end, ctx.timeout_ms)
	end

	vim.schedule(function()
		if stopped then
			return
		end

		local ok, requirements = pcall(function()
			local value = type(action.requires) == "function" and action.requires(ctx) or (action.requires or {})
			assert(type(value) == "table" and vim.islist(value), "Action requires must resolve to a list")
			return value
		end)

		if not ok then
			finish(tostring(requirements))
			return
		end

		local index = 0
		local function next_requirement()
			if stopped then
				return
			end

			index = index + 1
			local name = requirements[index]

			if not name then
				finish(nil)
				return
			end

			local loader = loaders[name]

			if not loader then
				finish("Unknown action metadata requirement: " .. tostring(name))
				return
			end

			local called = false
			local function loaded(err, value)
				vim.schedule(function()
					if stopped or called then
						return
					end

					called = true
					cancel = nil

					if err then
						ctx.metadata_errors[name] = tostring(err)

						if not action.allow_missing_metadata then
							finish(tostring(err))
							return
						end
					else
						ctx.metadata[name] = value
					end

					next_requirement()
				end)
			end
			local success, pending = pcall(loader, ctx, loaded)

			if success then
				cancel = pending
			else
				loaded(tostring(pending))
			end
		end

		next_requirement()
	end)
	return function()
		if not stopped then
			stop()
			cancel_loader(cancel)
		end
	end
end

return M

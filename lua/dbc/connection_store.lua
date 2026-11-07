local M = {}

function M.path(config)
	local path = config.connections_file or (vim.fn.stdpath("data") .. "/dbc/connections.json")
	assert(type(path) == "string" and path ~= "", "connections_file must be a file path")
	return vim.fn.fnamemodify(vim.fn.expand(path), ":p")
end

function M.validate(profiles)
	assert(type(profiles) == "table" and vim.islist(profiles), "Connections must be a JSON array/list")
	local names = {}

	for _, profile in ipairs(profiles) do
		assert(type(profile) == "table" and profile ~= vim.NIL, "Connection must be an object")
		assert(type(profile.name) == "string" and profile.name:match("%S"), "Connection requires a name")
		assert(not names[profile.name], "Connection names must be unique: " .. profile.name)
		names[profile.name] = true
		require("dbc.adapters").get(profile)
		require("dbc.providers").validate(profile)
		assert(not profile.password, "Use client-native authentication or a connection provider instead of a password")

		if profile.adapter == "sqlite" then
			assert(
				type(profile.database) == "string" and profile.database ~= "",
				"SQLite requires a database file path"
			)
		end
	end
end

function M.load(config)
	local path = M.path(config)

	if not vim.uv.fs_stat(path) then
		return {}
	end

	local ok, profiles = pcall(function()
		return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
	end)
	assert(ok, "Could not read connections file " .. path .. ": " .. tostring(profiles))
	M.validate(profiles)
	return profiles
end

function M.resolve(config)
	local resolved = vim.deepcopy(config)
	resolved.connections = vim.list_extend(vim.deepcopy(config.connections or {}), M.load(config))
	M.validate(resolved.connections)
	return resolved
end

local function write(config, profiles)
	local path = M.path(config)
	local lines = { "[" }

	for index, profile in ipairs(profiles) do
		table.insert(lines, "  " .. vim.json.encode(profile) .. (index < #profiles and "," or ""))
	end

	table.insert(lines, "]")
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p", 448)
	local temporary = path .. ".tmp-" .. tostring(vim.uv.hrtime())
	local fd = assert(vim.uv.fs_open(temporary, "wx", 384))
	local text = table.concat(lines, "\n") .. "\n"
	local written, err = vim.uv.fs_write(fd, text, 0)
	vim.uv.fs_close(fd)

	if written ~= #text then
		vim.uv.fs_unlink(temporary)
		error("Could not write connections file: " .. tostring(err))
	end

	local renamed, rename_error = vim.uv.fs_rename(temporary, path)

	if not renamed then
		vim.uv.fs_unlink(temporary)
		error("Could not save connections file: " .. tostring(rename_error))
	end
end

function M.ensure(config)
	if not vim.uv.fs_stat(M.path(config)) then
		write(config, {})
	end
end

function M.add(config, profile)
	local stored = M.load(config)
	table.insert(stored, vim.deepcopy(profile))
	M.validate(vim.list_extend(vim.deepcopy(config.connections or {}), stored))
	write(config, stored)
end

function M.remove(config, profile)
	local stored = M.load(config)

	for index, existing in ipairs(stored) do
		if existing.name == profile.name then
			assert(
				vim.deep_equal(existing, profile),
				"Connection changed on disk; reload connections before removing it"
			)
			table.remove(stored, index)
			M.validate(vim.list_extend(vim.deepcopy(config.connections or {}), stored))
			write(config, stored)
			return
		end
	end

	error("Connection is no longer in the JSON file; reload connections")
end

return M

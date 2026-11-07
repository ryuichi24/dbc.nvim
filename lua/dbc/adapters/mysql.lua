local M = { capabilities = { create_database = true, create_table = true, insert = true, update = true } }

function M.quote(value)
	return "`" .. value:gsub("`", "``") .. "`"
end

function M.argv(profile, database)
	local args = { profile.executable or "mysql" }

	if profile.defaults_file then
		table.insert(args, "--defaults-extra-file=" .. profile.defaults_file)
	end

	if profile.login_path then
		table.insert(args, "--login-path=" .. profile.login_path)
	end

	vim.list_extend(
		args,
		{ "--xml", "--batch", "--binary-mode", "--skip-reconnect", "--default-character-set=utf8mb4" }
	)

	for _, key in ipairs({ "host", "port", "user", "socket" }) do
		if profile[key] then
			table.insert(args, "--" .. key .. "=" .. tostring(profile[key]))
		end
	end

	for key, flag in pairs({ ssl_ca = "ssl-ca", ssl_mode = "ssl-mode", protocol = "protocol" }) do
		if profile[key] then
			table.insert(args, "--" .. flag .. "=" .. profile[key])
		end
	end

	if profile.enable_cleartext_plugin then
		table.insert(args, "--enable-cleartext-plugin")
	end

	if database then
		table.insert(args, "--database=" .. database)
	end

	return args
end

local function unescape(value)
	return (
		value:gsub("&(#?[%w]+);", function(entity)
			local named = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }

			if named[entity] then
				return named[entity]
			end

			local number = entity:match("^#x(%x+)$")
			local code = number and tonumber(number, 16) or tonumber(entity:match("^#(%d+)$"))

			if code then
				return vim.fn.nr2char(code)
			end

			error("Unsupported XML entity: " .. entity)
		end)
	)
end

-- MySQL XML carries field names on every row, and xsi:nil distinguishes NULL.
function M.decode(text)
	local sets = {}

	for body in text:gmatch("<resultset%s.-</resultset>") do
		local result = { columns = {}, rows = {} }

		for row in body:gmatch("<row>(.-)</row>") do
			local values, names = {}, {}
			local position = 1

			while true do
				local first, last, attributes = row:find("<field%s+([^>]-)>", position)

				if not first then
					break
				end

				local value

				if attributes:match("/%s*$") then
					value = attributes:match('xsi:nil="true"') and vim.NIL or ""
					position = last + 1
				else
					local ending, finish = row:find("</field>", last + 1, true)
					assert(ending, "Incomplete MySQL XML field")
					value = unescape(row:sub(last + 1, ending - 1))
					position = finish + 1
				end

				table.insert(names, unescape(assert(attributes:match('name="(.-)"'), "Missing field name")))
				table.insert(values, value)
			end

			if #result.columns == 0 then
				result.columns = names
			end

			table.insert(result.rows, values)
		end

		table.insert(sets, result)
	end

	local remainder = text:gsub("<%?xml.-%?>", ""):gsub("<resultset%s.-</resultset>", "")
	assert(not remainder:match("%S"), "Unexpected or incomplete MySQL XML output")
	return sets
end

function M.metadata(node)
	if node.kind == "connection" then
		return "SHOW DATABASES"
	elseif node.kind == "database" then
		return "SHOW FULL TABLES"
	elseif node.kind == "table" then
		return "SHOW COLUMNS FROM " .. M.quote(node.name)
	end
end

function M.request(profile, database, sql, credentials)
	return {
		argv = M.argv(profile, database),
		stdin = sql,
		decode = M.decode,
		env = credentials and credentials.password and { MYSQL_PWD = credentials.password } or nil,
	}
end

function M.children(node, sets)
	local children = {}

	for _, row in ipairs(sets[1] and sets[1].rows or {}) do
		local kind = ({ connection = "database", database = "table", table = "column" })[node.kind]
		table.insert(children, {
			name = row[1],
			kind = kind,
			primary_key = kind == "column" and row[4] == "PRI" or nil,
			generated = kind == "column" and row[6] and row[6]:match("GENERATED") ~= nil or nil,
			database = node.kind == "connection" and row[1] or node.database,
			detail = kind == "column" and (row[2] .. (row[4] and row[4] ~= "" and " " .. row[4] or ""))
				or (row[2] == "VIEW" and "view" or nil),
		})
	end

	return children
end

function M.preview(node)
	if node.kind == "table" then
		return "SELECT * FROM " .. M.quote(node.name) .. " LIMIT 100;"
	end
end

function M.qualify(node, name)
	local database = node.database and (M.quote(node.database) .. ".") or ""
	return database .. M.quote(name or node.name)
end

return M

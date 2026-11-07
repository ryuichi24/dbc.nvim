local M = { capabilities = { create_database = true, create_table = true, insert = true, update = true } }

function M.quote(value)
	return '"' .. value:gsub('"', '""') .. '"'
end

local function literal(value)
	return "E'" .. value:gsub("\\", "\\\\"):gsub("'", "''") .. "'"
end

-- Parse CSV records, not lines: quoted fields can contain CR/LF and commas.
function M.decode(text, null, dialect)
	dialect = dialect or "PostgreSQL"
	if text == "" then
		return {}
	end

	local records, row, position = {}, {}, 1

	while position <= #text do
		local value

		if text:sub(position, position) == '"' then
			local parts = {}
			position = position + 1

			while true do
				local ending = assert(text:find('"', position, true), "Unterminated " .. dialect .. " CSV field")
				table.insert(parts, text:sub(position, ending - 1))
				position = ending + 1

				if text:sub(position, position) ~= '"' then
					break
				end

				table.insert(parts, '"')
				position = position + 1
			end

			value = table.concat(parts)
		else
			local ending = text:find("[,\r\n]", position) or (#text + 1)
			value = text:sub(position, ending - 1)
			assert(not value:find('"', 1, true), "Unexpected quote in " .. dialect .. " CSV")
			position = ending
		end

		table.insert(row, value)
		local separator = text:sub(position, position)
		assert(separator == "" or separator == "," or separator == "\n" or separator == "\r", "Invalid CSV separator")
		position = position + 1

		if separator ~= "," then
			table.insert(records, row)
			row = {}

			if separator == "\r" and text:sub(position, position) == "\n" then
				position = position + 1
			end
		elseif position > #text then
			table.insert(row, "")
			table.insert(records, row)
		end
	end

	local columns = table.remove(records, 1)

	for _, values in ipairs(records) do
		assert(
			#values == #columns,
			"Unexpected " .. dialect .. " CSV width; execute one result-producing statement at a time"
		)

		for index, value in ipairs(values) do
			if value == null then
				values[index] = vim.NIL
			end
		end
	end

	return { { columns = columns, rows = records } }
end

function M.request(profile, database, sql, credentials)
	-- psql prints NULL as ordinary text. A fresh marker avoids a fixed reserved
	-- value such as "NULL" or "\N" colliding with application data.
	local null = "dbc_null_" .. vim.fn.sha256(tostring(vim.uv.hrtime()) .. tostring({}))
	local argv = {
		profile.executable or "psql",
		"--no-psqlrc",
		"--no-password",
		"--quiet",
		"--csv",
		"--set=ON_ERROR_STOP=1",
		"--pset=pager=off",
		"--pset=null=" .. null,
	}

	for key, flag in pairs({ host = "host", port = "port", user = "username" }) do
		if profile[key] then
			table.insert(argv, "--" .. flag .. "=" .. tostring(profile[key]))
		end
	end

	if database or profile.database then
		table.insert(argv, "--dbname=" .. (database or profile.database))
	end

	local env = { PGCLIENTENCODING = "UTF8" }

	if credentials and credentials.password then
		env.PGPASSWORD = credentials.password
	end

	for key, variable in pairs({ service = "PGSERVICE", passfile = "PGPASSFILE", sslmode = "PGSSLMODE" }) do
		if profile[key] then
			env[variable] = profile[key]
		end
	end

	return {
		argv = argv,
		stdin = sql,
		env = env,
		decode = function(text)
			return M.decode(text, null)
		end,
	}
end

function M.metadata(node)
	if node.kind == "connection" then
		return "SELECT datname FROM pg_catalog.pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname"
	elseif node.kind == "database" then
		return "SELECT nspname FROM pg_catalog.pg_namespace WHERE nspname !~ '^pg_' AND nspname <> 'information_schema' ORDER BY nspname"
	elseif node.kind == "schema" then
		return "SELECT c.relname, c.relkind FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = "
			.. literal(node.schema)
			.. " AND c.relkind IN ('r', 'p', 'v', 'm', 'f') ORDER BY c.relname"
	elseif node.kind == "table" then
		return "SELECT a.attname, pg_catalog.format_type(a.atttypid, a.atttypmod), EXISTS (SELECT 1 FROM pg_catalog.pg_index i WHERE i.indrelid = c.oid AND i.indisprimary AND a.attnum = ANY(i.indkey)), a.attgenerated FROM pg_catalog.pg_attribute a JOIN pg_catalog.pg_class c ON c.oid = a.attrelid JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = "
			.. literal(node.schema)
			.. " AND c.relname = "
			.. literal(node.name)
			.. " AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum"
	end
end

function M.children(node, sets)
	local children = {}

	for _, row in ipairs(sets[1] and sets[1].rows or {}) do
		local kind = ({ connection = "database", database = "schema", schema = "table", table = "column" })[node.kind]
		table.insert(children, {
			name = row[1],
			kind = kind,
			primary_key = kind == "column" and row[3] == "t" or nil,
			generated = kind == "column" and row[4] ~= nil and row[4] ~= "" or nil,
			database = node.kind == "connection" and row[1] or node.database,
			schema = node.kind == "database" and row[1] or node.schema,
			detail = kind == "column" and row[2]
				or (row[2] == "v" and "view" or row[2] == "m" and "materialized view" or nil),
		})
	end

	return children
end

function M.preview(node)
	if node.kind == "table" then
		return "SELECT * FROM " .. M.quote(node.schema) .. "." .. M.quote(node.name) .. " LIMIT 100;"
	end
end

function M.qualify(node, name)
	return M.quote(node.schema or "<schema_name>") .. "." .. M.quote(name or node.name)
end

return M

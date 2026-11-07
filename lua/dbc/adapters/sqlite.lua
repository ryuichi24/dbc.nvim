local M = { capabilities = { create_table = true, insert = true, update = true } }

function M.quote(value)
	return '"' .. value:gsub('"', '""') .. '"'
end

local function literal(value)
	return "'" .. value:gsub("'", "''") .. "'"
end

function M.request(profile, database, sql)
	local path = database or profile.database
	assert(type(path) == "string" and path ~= "", "SQLite requires a database file path")
	local null = "dbc_null_" .. vim.fn.sha256(tostring(vim.uv.hrtime()) .. tostring({}))
	return {
		argv = {
			profile.executable or "sqlite3",
			"-batch",
			"-bail",
			"-init",
			"/dev/null",
			"-csv",
			"-header",
			"-nullvalue",
			null,
			"--",
			path,
		},
		stdin = sql,
		decode = function(text)
			return require("dbc.adapters.postgres").decode(text, null, "SQLite")
		end,
	}
end

function M.metadata(node)
	if node.kind == "connection" then
		return "SELECT " .. literal(node.profile.database) .. " AS database_file"
	elseif node.kind == "database" then
		return "SELECT name, type FROM sqlite_schema WHERE type IN ('table', 'view') AND substr(name, 1, 7) <> 'sqlite_' ORDER BY name"
	elseif node.kind == "table" then
		return "SELECT name, type, pk, hidden FROM pragma_table_xinfo(" .. literal(node.name) .. ") ORDER BY cid"
	end
end

function M.children(node, sets)
	local children = {}

	for _, row in ipairs(sets[1] and sets[1].rows or {}) do
		local kind = ({ connection = "database", database = "table", table = "column" })[node.kind]
		table.insert(children, {
			name = row[1],
			kind = kind,
			primary_key = kind == "column" and tonumber(row[3] or 0) > 0 or nil,
			generated = kind == "column" and tonumber(row[4] or 0) > 0 or nil,
			database = node.kind == "connection" and row[1] or node.database,
			detail = kind == "column" and row[2] or (row[2] == "view" and "view" or nil),
		})
	end

	return children
end

function M.qualify(node, name)
	return M.quote(name or node.name)
end

function M.preview(node)
	if node.kind == "table" then
		return "SELECT * FROM " .. M.qualify(node) .. " LIMIT 100;"
	end
end

return M

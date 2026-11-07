local M = {}

function M.source(sql, binding)
	local target = sql:match("^%s*[Ss][Ee][Ll][Ee][Cc][Tt]%s+%*%s+[Ff][Rr][Oo][Mm]%s+(.+)$")
	assert(target, "Row update requires SELECT * FROM a single table")
	target = target:gsub(";%s*$", ""):gsub("%s+[Ll][Ii][Mm][Ii][Tt]%s+%d+%s*$", "")
	local names = {}

	while target ~= "" do
		target = target:gsub("^%s+", "")
		local quote = target:sub(1, 1)
		local name

		if quote == '"' or quote == "`" then
			local parts, position = {}, 2

			while true do
				local ending = assert(target:find(quote, position, true), "Unterminated table identifier")
				table.insert(parts, target:sub(position, ending - 1))
				position = ending + 1

				if target:sub(position, position) ~= quote then
					break
				end

				table.insert(parts, quote)
				position = position + 1
			end

			name = table.concat(parts)
			target = target:sub(position)
		else
			name = assert(target:match("^[%a_][%w_$]*"), "Unsupported source table")
			target = target:sub(#name + 1)
		end

		table.insert(names, name)
		target = target:gsub("^%s+", "")

		if target == "" then
			break
		end

		assert(
			target:sub(1, 1) == "." and #names < 2,
			"Row update requires one source table without joins or expressions"
		)
		target = target:sub(2)
		assert(target:match("%S"), "Missing table name")
	end

	assert(
		binding.profile.adapter ~= "postgres" or #names == 2,
		"Use a schema-qualified PostgreSQL table for row updates"
	)
	assert(binding.profile.adapter ~= "sqlite" or #names == 1, "Use an unqualified SQLite table for row updates")
	return {
		kind = "table",
		name = names[#names],
		schema = binding.profile.adapter == "postgres" and (#names == 2 and names[1] or "public") or nil,
		database = (binding.profile.adapter or "mysql") == "mysql" and (#names == 2 and names[1] or binding.database)
			or binding.database,
		profile = binding.profile,
	}
end

function M.literal(value, dialect)
	if value == vim.NIL then
		return "NULL"
	end

	local text = tostring(value)
	assert(not text:find("%z"), "NUL-containing values are not supported for row updates")

	if dialect == "mysql" or dialect == "postgres" then
		text = text:gsub("\\", "\\\\")
	end

	return (dialect == "postgres" and "E'" or "'") .. text:gsub("'", "''") .. "'"
end

function M.generate(ctx, row)
	local values, assignments, conditions = {}, {}, {}

	for index, name in ipairs(row.columns) do
		assert(values[name] == nil, "Duplicate result column: " .. name)
		values[name] = assert(row.values[index], "Missing result value")
	end

	for _, column in ipairs(ctx.metadata.columns or {}) do
		local value = values[column.name]

		if column.primary_key then
			assert(value ~= nil and value ~= vim.NIL, "Result must include every primary-key column")
			table.insert(conditions, ctx.quote(column.name) .. " = " .. M.literal(value, ctx.adapter_name))
		elseif value ~= nil and not column.generated then
			table.insert(assignments, ctx.quote(column.name) .. " = " .. M.literal(value, ctx.adapter_name))
		end

		values[column.name] = nil
	end

	assert(next(values) == nil, "Result contains columns absent from the source table")
	assert(#conditions > 0, "Row update requires a primary key")
	assert(#assignments > 0, "Result has no editable columns")
	return "UPDATE "
		.. ctx.qualify()
		.. "\nSET\n    "
		.. table.concat(assignments, ",\n    ")
		.. "\nWHERE "
		.. table.concat(conditions, " AND ")
		.. ";"
end

return M

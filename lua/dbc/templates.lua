local M = {}

function M.create(target, quote)
	return "CREATE TABLE " .. target .. " (\n    " .. quote("<column_name>") .. " <data_type>\n);"
end

function M.insert(target, quote, children)
	local columns, values = {}, {}

	for _, child in ipairs(children or {}) do
		if child.kind == "column" then
			table.insert(columns, quote(child.name))
			table.insert(values, "<value_" .. #columns .. ">")
		end
	end

	if #columns == 0 then
		columns = { quote("<column_name>") }
		values = { "<value_1>" }
	end

	return "INSERT INTO "
		.. target
		.. " (\n    "
		.. table.concat(columns, ",\n    ")
		.. "\n) VALUES (\n    "
		.. table.concat(values, ",\n    ")
		.. "\n);"
end

function M.update(target, quote, children)
	local assignments = {}

	for _, child in ipairs(children or {}) do
		if child.kind == "column" then
			table.insert(assignments, quote(child.name) .. " = <value_" .. (#assignments + 1) .. ">")
		end
	end

	if #assignments == 0 then
		assignments = { quote("<column_name>") .. " = <value_1>" }
	end

	return "UPDATE " .. target .. "\nSET\n    " .. table.concat(assignments, ",\n    ") .. "\nWHERE <condition>;"
end

return M

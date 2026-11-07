local M = {}

function M.run()
	local plugin = require("dbc")
	local workspace = require("dbc.workspace")
	local actions = require("dbc.actions")
	local function generate(id, adapter, node)
		node.profile = { name = "unit", adapter = adapter }
		local ctx = actions.context(node)
		ctx.metadata = {}
		return actions.generate(actions.get(id), ctx).sql
	end

	assert(generate("create_database", "mysql", { kind = "connection" }) == "CREATE DATABASE `<database_name>`;")
	assert(generate("create_database", "postgres", { kind = "connection" }) == 'CREATE DATABASE "<database_name>";')
	assert(
		generate("insert", "mysql", { kind = "table", name = "empty", database = "db" }):find(
			"`<column_name>`",
			1,
			true
		)
	)
	assert(
		generate("create_table", "postgres", { kind = "database", database = "app" }):find(
			'"<schema_name>"."<table_name>"',
			1,
			true
		)
	)

	plugin.setup({
		connections = {
			{ name = "template-mysql", adapter = "mysql", database = "original" },
			{ name = "template-postgres", adapter = "postgres", database = "app" },
		},
	})
	local state = plugin.open()
	local original = state.query
	vim.api.nvim_buf_set_lines(original, 0, -1, false, { "SELECT keep_this_query;" })
	local calls = {}
	local fail_columns = false
	state.runner.run = function(_, _, sql, done)
		table.insert(calls, sql)
		local rows
		local columns_query = false

		if sql == "SHOW DATABASES" then
			rows = { { "my`db" } }
		elseif sql == "SHOW FULL TABLES" then
			rows = { { "ta`ble", "BASE TABLE" } }
		elseif sql:find("SHOW COLUMNS", 1, true) then
			columns_query = true
			rows = { { "id", "int", "NO", "PRI" }, { "na`me", "text", "YES", "" } }
		elseif sql:find("pg_catalog.pg_attribute", 1, true) then
			columns_query = true
			rows = { { "id", "integer" }, { 'na"me', "text" } }
		elseif sql:find("pg_catalog.pg_class", 1, true) then
			rows = { { 'ta"ble', "r" } }
		elseif sql:find("pg_catalog.pg_namespace", 1, true) then
			rows = { { 'my"schema' } }
		elseif sql:find("pg_catalog.pg_database", 1, true) then
			rows = { { "app" } }
		else
			error("Template creation must never execute user SQL: " .. sql)
		end

		local cancelled
		vim.schedule(function()
			if not cancelled then
				done({
					code = 0,
					duration = 0,
					stdout = "",
					stderr = "",
					error = columns_query and fail_columns and "No column access" or nil,
					sets = { { columns = {}, rows = rows } },
				})
			end
		end)
		return function()
			cancelled = true
		end
	end

	local function select(node)
		vim.api.nvim_set_current_win(state.sidebar_win)

		for line, value in pairs(state.nodes) do
			if value == node then
				vim.api.nvim_win_set_cursor(0, { line, 0 })
				return
			end
		end

		error("Test node is not visible")
	end

	local function wait()
		assert(vim.wait(1000, function()
			return not next(state.metadata_jobs) and not next(state.action_jobs)
		end))
	end

	local function expand(node)
		select(node)
		workspace.refresh()
		wait()
	end

	local function add(node, key)
		select(node)
		key = key or "a"
		local mapping = vim.fn.maparg(key, "n", false, true)

		assert(mapping.buffer == 1, key .. " must be sidebar-local")

		mapping.callback()
		wait()
	end

	local function text()
		return table.concat(vim.api.nvim_buf_get_lines(state.query, 0, -1, false), "\n")
	end

	local function placeholder()
		local cursor = vim.api.nvim_win_get_cursor(state.query_win)
		return vim.api.nvim_buf_get_lines(state.query, cursor[1] - 1, cursor[1], false)[1]:sub(cursor[2] + 1)
	end

	local function read_query(node, sql)
		select(node)
		local mapping = vim.fn.maparg("r", "n", false, true)
		local count = #state.queries
		local metadata_count = #calls
		local previous = state.query
		local previous_lines = vim.api.nvim_buf_get_lines(previous, 0, -1, false)

		assert(mapping.buffer == 1, "r must be sidebar-local")

		mapping.callback()
		wait()

		assert(#state.queries == count + 1 and state.query ~= previous)
		assert(vim.api.nvim_get_current_win() == state.query_win)
		assert(text() == sql)
		assert(state.bindings[state.query].profile.name == node.profile.name)
		assert(state.bindings[state.query].database == node.database)
		assert(vim.deep_equal(vim.api.nvim_buf_get_lines(previous, 0, -1, false), previous_lines))
		assert(#calls == metadata_count and state.cancel == nil, "Read query creation performs no SQL")
	end

	add(state.roots[1])

	assert(#state.queries == 2 and #calls == 0)
	assert(text() == "CREATE DATABASE `<database_name>`;")
	assert(placeholder():find("<database_name>", 1, true) == 1)
	assert(state.bindings[state.query].profile.name == "template-mysql")
	assert(
		state.bindings[state.query].database == nil,
		"Connection templates must not inherit another query's database"
	)

	expand(state.roots[1])
	local database = state.roots[1].children[1]
	local count = #state.queries
	local metadata_count = #calls
	add(database)

	assert(#state.queries == count + 1)
	assert(state.query ~= original and vim.api.nvim_get_current_win() == state.query_win)
	assert(text():find("CREATE TABLE `my``db`.`<table_name>`", 1, true))
	assert(text():find("`<column_name>` <data_type>", 1, true))
	assert(placeholder():find("<table_name>", 1, true) == 1)
	assert(state.bindings[state.query].database == "my`db")
	assert(vim.api.nvim_buf_get_lines(original, 0, -1, false)[1] == "SELECT keep_this_query;")
	assert(state.bindings[original].database == "original")
	assert(#calls == metadata_count and state.cancel == nil, "CREATE template performs no SQL")

	expand(database)
	local relation = database.children[1]
	read_query(relation, "SELECT * FROM `ta``ble` LIMIT 100;")
	metadata_count = #calls
	count = #state.queries
	add(relation)
	wait()

	assert(#state.queries == count + 1 and #calls == metadata_count + 1)
	assert(text():find("INSERT INTO `my``db`.`ta``ble`", 1, true))
	assert(text():find("`id`,\n    `na``me`", 1, true))
	assert(text():find("<value_1>,\n    <value_2>", 1, true))
	assert(placeholder():find("<value_1>", 1, true) == 1)

	count = #state.queries
	metadata_count = #calls
	local previous = state.query
	local previous_sql = text()
	add(relation, "u")

	assert(#state.queries == count + 1 and state.query ~= previous)
	assert(vim.api.nvim_get_current_win() == state.query_win)
	assert(
		text() == "UPDATE `my``db`.`ta``ble`\nSET\n    `id` = <value_1>,\n    `na``me` = <value_2>\nWHERE <condition>;"
	)
	assert(placeholder():find("<value_1>", 1, true) == 1)
	assert(state.bindings[state.query].database == relation.database)
	assert(state.bindings[state.query].profile.name == relation.profile.name)
	assert(table.concat(vim.api.nvim_buf_get_lines(previous, 0, -1, false), "\n") == previous_sql)
	assert(#calls == metadata_count and state.cancel == nil, "UPDATE creation performs no SQL with cached columns")

	metadata_count = #calls
	add(relation)

	assert(#calls == metadata_count, "Cached columns do not need another query")

	-- Pressing a while columns are already loading joins that metadata request.
	relation.children = nil
	select(relation)
	workspace.refresh()
	count = #state.queries
	metadata_count = #calls
	add(relation)
	wait()

	assert(#calls == metadata_count and #state.queries == count + 1)
	assert(text():find("`na``me`", 1, true))

	-- Without column access, still produce an editable generic INSERT template.
	relation.children = nil
	fail_columns = true
	add(relation)
	wait()

	assert(text():find("`<column_name>`", 1, true) and text():find("<value_1>", 1, true))
	assert(relation.error == "No column access")

	add(relation, "u")

	assert(text() == "UPDATE `my``db`.`ta``ble`\nSET\n    `<column_name>` = <value_1>\nWHERE <condition>;")

	fail_columns = false
	metadata_count = #calls
	add(state.roots[2])

	assert(text() == 'CREATE DATABASE "<database_name>";')
	assert(placeholder():find("<database_name>", 1, true) == 1)
	assert(state.bindings[state.query].profile.name == "template-postgres")
	assert(state.bindings[state.query].database == nil)
	assert(#calls == metadata_count and state.cancel == nil)

	expand(state.roots[2])
	database = state.roots[2].children[1]
	add(database)

	assert(text():find('CREATE TABLE "<schema_name>"."<table_name>"', 1, true))
	assert(placeholder():find("<schema_name>", 1, true) == 1)
	assert(state.bindings[state.query].profile.name == "template-postgres")

	expand(database)
	local schema = database.children[1]
	add(schema)

	assert(text():find('CREATE TABLE "my""schema"."<table_name>"', 1, true))

	expand(schema)
	relation = schema.children[1]
	read_query(relation, 'SELECT * FROM "my""schema"."ta""ble" LIMIT 100;')
	add(relation)
	wait()

	assert(text():find('INSERT INTO "my""schema"."ta""ble"', 1, true))
	assert(text():find('"id",\n    "na""me"', 1, true))
	assert(state.bindings[state.query].database == "app")
	assert(state.cancel == nil)

	add(relation, "u")

	assert(
		text()
			== 'UPDATE "my""schema"."ta""ble"\nSET\n    "id" = <value_1>,\n    "na""me" = <value_2>\nWHERE <condition>;'
	)

	count = #state.queries
	add(relation.children[1])

	assert(#state.queries == count, "Column nodes do not create templates")

	workspace.close()
end

return M

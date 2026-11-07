-- Run from the repository root with make test.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local temporary = vim.fn.tempname()
local pg_temporary = vim.fn.tempname()
local data_home = vim.fn.tempname()
vim.env.XDG_DATA_HOME = data_home
local ok, err = xpcall(function()
	local adapters = require("dbc.adapters")
	dofile("tests/sqlite.lua")
	dofile("tests/row_update.lua")
	local postgres = adapters.get({ adapter = "postgres" })
	local csv = 'a,a,empty,value\r\n"one,two",NULL_MARKER,"","line 1\nline ""2"""\r\n'
	local pg_sets = postgres.decode(csv, "NULL_MARKER")

	assert(pg_sets[1].columns[1] == pg_sets[1].columns[2])
	assert(pg_sets[1].rows[1][1] == "one,two")
	assert(pg_sets[1].rows[1][2] == vim.NIL)
	assert(pg_sets[1].rows[1][3] == "")
	assert(pg_sets[1].rows[1][4] == 'line 1\nline "2"')
	assert(#postgres.decode("a,b\n", "NULL_MARKER")[1].rows == 0)
	assert(postgres.decode("a,b\nlast,", "NULL_MARKER")[1].rows[1][2] == "")
	assert(not pcall(postgres.decode, 'a\n"unfinished', "NULL_MARKER"))
	assert(not pcall(postgres.decode, "a,b\none\n", "NULL_MARKER"))
	assert(
		postgres.preview({ kind = "table", schema = 'my"schema', name = 'a"b' })
			== 'SELECT * FROM "my""schema"."a""b" LIMIT 100;'
	)
	assert(postgres.metadata({ kind = "table", schema = "a'b\\c", name = "users" }):find("E'a''b\\\\c'", 1, true))
	assert(not pcall(adapters.get, { adapter = "missing" }))
	assert(not pcall(adapters.register, "invalid", {}))

	adapters.register("custom-postgres", postgres)

	assert(adapters.get({ adapter = "custom-postgres" }) == postgres)

	local request = postgres.request({ service = "dev", host = "/a b", passfile = "/a b/pass" }, "test", "SELECT 1")
	local other_request = postgres.request({}, "test", "SELECT 1")
	local marker

	for _, arg in ipairs(request.argv) do
		marker = arg:match("^%-%-pset=null=(.+)$") or marker
	end

	assert(request.env.PGSERVICE == "dev" and request.env.PGPASSFILE == "/a b/pass")
	assert(vim.tbl_contains(request.argv, "--host=/a b"))
	assert(request.decode("value\n" .. marker .. "\n")[1].rows[1][1] == vim.NIL)
	assert(other_request.decode("value\n" .. marker .. "\n")[1].rows[1][1] == marker)

	local mysql = require("dbc.mysql")
	local xml = [[<?xml version="1.0"?>
<resultset statement="SELECT" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<row><field name="a">one&#9;two&#10;&amp;&lt;</field><field name="a" xsi:nil="true" /><field name="empty"></field></row>
</resultset>]]
	local sets = mysql.decode(xml)

	assert(sets[1].rows[1][1] == "one\ttwo\n&<")
	assert(sets[1].rows[1][2] == vim.NIL)
	assert(sets[1].rows[1][3] == "")
	assert(sets[1].columns[1] == sets[1].columns[2])
	assert(#mysql.decode(xml .. xml) == 2)
	assert(not pcall(mysql.decode, "<resultset broken"))
	assert(mysql.quote("a`b") == "`a``b`")

	local argv = mysql.argv({ defaults_file = "/a b", login_path = "dev", user = "u" }, "a; b")

	assert(argv[2] == "--defaults-extra-file=/a b")
	assert(argv[#argv] == "--database=a; b")

	assert(vim.tbl_contains(mysql.argv({ host = "localhost", port = 33062 }), "--protocol=TCP"))
	assert(not vim.tbl_contains(mysql.argv({ socket = "/tmp/mysql.sock", port = 33062 }), "--protocol=TCP"))
	assert(not vim.tbl_contains(mysql.argv({ protocol = "SOCKET", port = 33062 }), "--protocol=TCP"))

	-- A deterministic executable exercises real pipes without needing a database.
	vim.fn.writefile({
		"#!/bin/sh",
		"sql=$(cat)",
		'case "$sql" in',
		"*SLOW*) exec sleep 5 ;;",
		"*FAIL*) printf 'SQL failure' >&2; exit 1 ;;",
		"*BIG*) printf '123456789012345678901234567890'; exit 0 ;;",
		"*'SHOW DATABASES'*) printf '%s' '<resultset statement=\"show\"><row><field name=\"Database\">test</field></row></resultset>'; exit 0 ;;",
		"*'SHOW FULL TABLES'*) printf '%s' '<resultset statement=\"show\"><row><field name=\"Table\">users</field><field name=\"Type\">BASE TABLE</field></row></resultset>'; exit 0 ;;",
		'*\'SHOW COLUMNS\'*) printf \'%s\' \'<resultset statement="show"><row><field name="Field">id</field><field name="Type">int</field><field name="Null">NO</field><field name="Key">PRI</field></row></resultset>\'; exit 0 ;;',
		"esac",
		"printf '%s' '" .. xml .. "'",
	}, temporary)
	vim.fn.setfperm(temporary, "rwx------")
	local process = require("dbc.process")
	local limits = { timeout_ms = 1000, max_output_bytes = 10000 }
	local response
	process.run({ temporary }, "FAIL", limits, function(result)
		response = result
	end)

	assert(vim.wait(3000, function()
		return response ~= nil
	end))
	assert(response.code == 1 and response.stderr == "SQL failure")

	response = nil
	process.run({ temporary }, "BIG", { timeout_ms = 1000, max_output_bytes = 10 }, function(result)
		response = result
	end)

	assert(vim.wait(3000, function()
		return response ~= nil
	end))
	assert(response.error:match("limit"))
	assert(#response.stdout <= 10)

	response = nil
	local cancel = process.run({ temporary }, "SLOW", limits, function(result)
		response = result
	end)
	vim.defer_fn(cancel, 50)

	assert(vim.wait(3000, function()
		return response ~= nil
	end))
	assert(response.error:match("Cancelled"))

	response = nil
	process.run({ temporary }, "SLOW", { timeout_ms = 30, max_output_bytes = 100 }, function(result)
		response = result
	end)

	assert(vim.wait(3000, function()
		return response ~= nil
	end))
	assert(response.error == "Query timed out")

	local plugin = require("dbc")
	assert(not pcall(plugin.setup, { ui = { panes = { query = { height = 0 } } } }))
	assert(not pcall(plugin.setup, { ui = { panes = { results = { width = 1.5 } } } }))
	assert(not pcall(plugin.setup, { ui = { resize_step = 0 } }))
	assert(not pcall(plugin.setup, { ui = { resize_step = 1.5 } }))

	plugin.setup({
		connections = { { name = "fake", executable = temporary, database = "test" } },
		ui = {
			resize_step = 2,
			panes = {
				sidebar = { width = 20, number = true },
				query = { height = 8, number = true, relativenumber = true },
				results = { relativenumber = true },
			},
		},
	})
	vim.cmd("runtime plugin/dbc.lua")
	local original_win = vim.api.nvim_get_current_win()
	local original_buf = vim.api.nvim_get_current_buf()
	local original_tabs = #vim.api.nvim_list_tabpages()
	local state = plugin.open()
	local query = state.query

	assert(vim.api.nvim_win_get_width(state.sidebar_win) == 20)
	assert(vim.api.nvim_win_get_height(state.query_win) == 8)
	assert(vim.api.nvim_win_get_width(state.query_win) == vim.api.nvim_win_get_width(state.results_win))
	assert(plugin.open() == state)
	assert(vim.bo[state.results].buftype == "nofile" and not vim.bo[state.results].modifiable)
	assert(vim.bo[query].filetype == "sql" and vim.bo[query].modifiable)
	assert(vim.wo[state.sidebar_win].number and not vim.wo[state.sidebar_win].relativenumber)
	assert(vim.wo[state.query_win].number and vim.wo[state.query_win].relativenumber)
	assert(vim.wo[state.query_win].winbar:find("Connection: fake · Database: test", 1, true))
	assert(not vim.wo[state.results_win].number and vim.wo[state.results_win].relativenumber)

	vim.fn.maparg("<C-h>", "n", false, true).callback()

	assert(vim.api.nvim_get_current_win() == state.sidebar_win)

	vim.fn.maparg("<C-l>", "n", false, true).callback()
	local height = vim.api.nvim_win_get_height(state.query_win)
	local restored = function() end
	vim.keymap.set("n", "j", restored, { buffer = query })
	vim.fn.maparg("<C-w>j", "n", false, true).callback()

	assert(vim.api.nvim_get_current_win() == state.query_win)
	assert(vim.api.nvim_win_get_height(state.query_win) == height - 2)

	vim.fn.maparg("j", "n", false, true).callback()

	assert(vim.api.nvim_win_get_height(state.query_win) == height - 4)

	vim.fn.maparg("<C-j>", "n", false, true).callback()

	assert(vim.api.nvim_get_current_win() == state.results_win)

	vim.api.nvim_buf_call(query, function()
		assert(vim.fn.maparg("j", "n", false, true).callback == restored)
	end)
	local width = vim.api.nvim_win_get_width(state.results_win)
	vim.fn.maparg("<C-w>l", "n", false, true).callback()

	assert(vim.api.nvim_win_get_width(state.results_win) == width + 2)
	assert(vim.api.nvim_win_get_width(state.query_win) == width + 2)

	require("dbc.resize").stop()

	vim.api.nvim_set_current_win(original_win)

	assert(vim.api.nvim_get_current_win() == state.results_win, "Normal windows stay outside dashboard navigation")

	vim.fn.maparg("<C-k>", "n", false, true).callback()

	assert(vim.api.nvim_get_current_win() == state.query_win)
	assert(#vim.api.nvim_list_tabpages() == original_tabs)
	assert(vim.api.nvim_win_get_buf(original_win) == original_buf)

	for _, name in ipairs({ "sidebar", "query", "results" }) do
		assert(vim.api.nvim_win_get_config(state[name .. "_win"]).relative == "editor")
	end

	vim.api.nvim_buf_set_lines(query, 0, -1, false, { "FAIL", "SELECT 1" })
	vim.cmd("2Dbc run")
	local workspace = require("dbc.workspace")
	local running_results = state.results
	workspace.query(nil, "SELECT another_query")
	local idle_results = state.results

	assert(vim.wait(3000, function()
		return state.cancel == nil
	end))
	assert(not table.concat(vim.api.nvim_buf_get_lines(idle_results, 0, -1, false), "\n"):match("returned rows"))

	workspace.close_query()

	assert(state.query == query and state.results == running_results)

	local serial = state.query_serial
	workspace.close_query()

	assert(#state.queries == 1 and state.query == query and state.results == running_results)
	assert(state.query_serial == serial, "Closing the last query must not create a replacement")
	assert(vim.api.nvim_buf_get_lines(query, 0, 1, false)[1] == "FAIL")

	local saved = vim.json.decode(table.concat(vim.fn.readfile(state.storage), "\n"))

	assert(#saved == 1 and saved[1].lines[1] == "FAIL")
	assert(saved[1].connection == "fake" and saved[1].database == "test")

	local rendered = table.concat(vim.api.nvim_buf_get_lines(state.results, 0, -1, false), "\n")

	assert(rendered:match("returned rows") and rendered:match("NULL"), rendered)
	assert(vim.bo[state.results].filetype == "markdown")
	assert(rendered:match("\n| %-+ |"), "Results include a Markdown table separator")

	for line, cell in pairs(state.cells) do
		local text = vim.api.nvim_buf_get_lines(state.results, line - 1, line, false)[1]

		assert(text:sub(1, 2) == "| " and text:sub(-2) == " |")
		assert(cell.starts[1] == 3, "Cell copy offsets account for the Markdown border")
	end

	assert(not rendered:match("SQL failure"), "Range must exclude the first line")

	-- Load schema nodes through actual CLI calls, then insert a bound preview.
	vim.api.nvim_set_current_win(state.sidebar_win)
	vim.api.nvim_win_set_cursor(0, { 4, 0 })
	require("dbc.workspace").refresh()

	assert(vim.wait(3000, function()
		return not next(state.metadata_jobs)
	end))
	assert(state.roots[1].children[1].name == "test")

	vim.api.nvim_win_set_cursor(0, { 5, 0 })
	require("dbc.workspace").refresh()

	assert(vim.wait(3000, function()
		return not next(state.metadata_jobs)
	end))
	assert(state.roots[1].children[1].children[1].name == "users")

	-- Selecting a database immediately binds the displayed query, preserving SQL.
	state.bindings[query].database = nil
	vim.fn.maparg("<CR>", "n", false, true).callback()

	assert(state.bindings[query].database == "test")
	assert(vim.wo[state.query_win].winbar:find("Connection: fake · Database: test", 1, true))
	assert(vim.api.nvim_buf_get_lines(query, 0, 1, false)[1] == "FAIL")
	assert(table.concat(vim.api.nvim_buf_get_lines(state.sidebar, 0, -1, false), "\n"):match("test %[query%]"))

	-- Reopen the database after selection toggled it closed.
	vim.fn.maparg("<CR>", "n", false, true).callback()

	vim.api.nvim_win_set_cursor(0, { 6, 0 })
	require("dbc.workspace").refresh()

	assert(vim.wait(3000, function()
		return not next(state.metadata_jobs)
	end))
	assert(state.roots[1].children[1].children[1].children[1].detail == "int PRI")

	-- Successful DDL reloads an expanded database's table list automatically.
	state.roots[1].children[1].children = {}
	vim.api.nvim_set_current_win(state.query_win)
	vim.api.nvim_buf_set_lines(query, 0, -1, false, { "CREATE TABLE users (id INT)" })
	plugin.run()

	assert(vim.wait(3000, function()
		return state.cancel == nil and not next(state.metadata_jobs) and #state.roots[1].children[1].children == 1
	end))
	assert(state.roots[1].children[1].children[1].name == "users")
	assert(table.concat(vim.api.nvim_buf_get_lines(state.sidebar, 0, -1, false), "\n"):match("users"))

	-- Close a split manually, then reopen without using an invalid window handle.
	vim.api.nvim_win_close(state.query_win, true)
	plugin.open()

	assert(vim.api.nvim_get_current_buf() == query)
	assert(vim.wo[state.query_win].number and vim.wo[state.query_win].relativenumber)
	assert(vim.wo[state.query_win].winbar:find("Connection: fake · Database: test", 1, true))

	vim.bo[query].modified = false
	local expected_results = vim.api.nvim_buf_get_lines(state.results, 0, -1, false)
	require("dbc.workspace").close()

	assert(vim.api.nvim_buf_is_valid(query), "Closing preserves query buffers")
	assert(not vim.api.nvim_buf_is_valid(state.results), "Scratch results are cleaned up")
	assert(vim.api.nvim_get_current_win() == original_win)
	assert(vim.api.nvim_win_get_buf(original_win) == original_buf)
	assert(not vim.api.nvim_win_is_valid(state.query_win))

	vim.api.nvim_buf_call(query, function()
		assert(vim.fn.maparg("<C-h>", "n", false, true).buffer == nil, "Dashboard mappings are removed on close")
	end)

	local expected = vim.api.nvim_buf_get_lines(query, 0, -1, false)
	state = plugin.open()

	assert(vim.deep_equal(vim.api.nvim_buf_get_lines(state.query, 0, -1, false), expected))
	assert(state.bindings[state.query].profile.name == "fake")
	assert(vim.deep_equal(vim.api.nvim_buf_get_lines(state.results, 0, -1, false), expected_results))
	assert(table.concat(expected_results, "\n"):match("Fetched: %d%d%d%d%-%d%d%-%d%d"))
	assert(table.concat(expected_results, "\n"):find("Rerun query for the latest data.", 1, true))
	assert(next(state.cells), "Restored results retain row/cell copying data")

	workspace.close()
	vim.fn.delete(state.storage)

	-- A second client exercises PostgreSQL routing through the same dashboard.
	vim.fn.writefile({
		"#!/bin/sh",
		'[ "$PGCLIENTENCODING" = UTF8 ] || exit 9',
		'for arg do case "$arg" in --pset=null=*) null=${arg#--pset=null=} ;; esac; done',
		"sql=$(cat)",
		'case "$sql" in',
		"*pg_catalog.pg_database*) printf 'datname\\napp\\n' ;;",
		"*pg_catalog.pg_attribute*) printf 'attname,type\\nid,integer\\n' ;;",
		"*pg_catalog.pg_class*) printf 'relname,relkind\\nusers,r\\n' ;;",
		"*pg_catalog.pg_namespace*) printf 'nspname\\npublic\\n' ;;",
		"*FAIL*) printf 'postgres failure' >&2; exit 1 ;;",
		"*BADCSV*) printf 'a,b\\none\\n' ;;",
		"*WRITE*) exit 0 ;;",
		"*SLOW*) exec sleep 5 ;;",
		'*) printf \'value,empty,null\\n"a,b","",%s\\n\' "$null" ;;',
		"esac",
	}, pg_temporary)
	vim.fn.setfperm(pg_temporary, "rwx------")
	plugin.setup({
		connections = {
			{ name = "postgres-test", adapter = "postgres", executable = pg_temporary, database = "app" },
			{ name = "mysql-test", adapter = "mysql", executable = temporary, database = "test" },
		},
	})
	state = plugin.open()
	query = state.query
	vim.api.nvim_buf_set_lines(query, 0, -1, false, { "SELECT 1" })
	plugin.run()

	assert(vim.wait(3000, function()
		return state.cancel == nil
	end))

	rendered = table.concat(vim.api.nvim_buf_get_lines(state.results, 0, -1, false), "\n")

	assert(rendered:match("a,b") and rendered:match("NULL"), rendered)

	vim.api.nvim_set_current_win(state.sidebar_win)

	for line = 4, 7 do
		vim.api.nvim_win_set_cursor(0, { line, 0 })
		require("dbc.workspace").refresh()

		assert(vim.wait(3000, function()
			return not next(state.metadata_jobs)
		end))
	end

	local database = state.roots[1].children[1]
	local schema = database.children[1]
	local relation = schema.children[1]

	assert(database.name == "app" and schema.name == "public")
	assert(relation.name == "users" and relation.schema == "public")
	assert(relation.children[1].detail == "integer")

	vim.api.nvim_win_set_cursor(0, { 7, 0 })
	local preview_mapping = vim.fn.maparg("p", "n", false, true)
	preview_mapping.callback()

	assert(vim.wait(3000, function()
		return not next(state.action_jobs)
	end))

	assert(vim.api.nvim_get_current_line() == 'SELECT * FROM "public"."users" LIMIT 100;')
	assert(state.bindings[state.query].database == "app")

	-- Changing the default connection must not retarget an existing query.
	state.binding = { profile = state.config.connections[2], database = "test" }

	assert(vim.wo[state.query_win].winbar:find("Connection: postgres-test · Database: app", 1, true))

	local preview = state.query
	local named_query
	local naming_autocmd = vim.api.nvim_create_autocmd({ "BufEnter", "BufFilePost" }, {
		pattern = "dbc://query/*",
		callback = function(event)
			named_query = event.buf
			vim.keymap.set("n", "<leader>fq", workspace.pick_query, { buffer = event.buf })
		end,
	})
	local other = require("dbc.workspace").query(nil, "SELECT 1")

	assert(named_query == other, "Filename autocmd matches dbc query buffers")
	assert(vim.api.nvim_buf_get_name(other) == "dbc://query/" .. other .. ".sql")
	assert(vim.bo[other].filetype == "sql")
	assert(vim.fn.maparg("<leader>fq", "n", false, true).buffer == 1)
	assert(vim.api.nvim_buf_get_name(preview) ~= vim.api.nvim_buf_get_name(other))

	vim.api.nvim_del_autocmd(naming_autocmd)

	assert(vim.wo[state.query_win].winbar:find("Connection: mysql-test · Database: test", 1, true))

	vim.api.nvim_win_set_buf(state.query_win, preview)

	assert(state.query == preview)
	assert(vim.wo[state.query_win].winbar:find("Connection: postgres-test · Database: app", 1, true))

	local preview_results = state.results
	workspace.next_query()

	assert(state.query == other and state.results ~= preview_results)
	assert(vim.api.nvim_get_current_line() == "SELECT 1")

	workspace.previous_query()

	assert(state.query == preview and state.results == preview_results)
	assert(vim.api.nvim_get_current_line() == 'SELECT * FROM "public"."users" LIMIT 100;')

	-- Counts select absolute query positions and restore their paired results.
	vim.cmd("normal 1gt")

	assert(state.query == state.queries[1].buf)
	assert(state.results == state.queries[1].results)

	vim.cmd("normal " .. #state.queries .. "gt")

	assert(state.query == other)
	assert(not pcall(workspace.goto_query, #state.queries + 1))
	assert(not pcall(workspace.goto_query, 0))
	assert(state.query == other)

	-- Filtering searches SQL and binding metadata; selection restores paired results.
	workspace.pick_query()
	local search = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_set_lines(search, 0, -1, false, { "postgres-test USERS" })
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = search })
	local select_query = vim.fn.maparg("<CR>", "n", false, true).callback
	select_query()

	assert(state.query == preview and state.results == preview_results)
	assert(not vim.api.nvim_buf_is_valid(search))

	workspace.pick_query()
	search = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_set_lines(search, 0, -1, false, { "no-such-query-tab" })
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = search })
	vim.fn.maparg("<CR>", "n", false, true).callback()

	assert(vim.api.nvim_get_current_buf() == search)
	assert(state.query == preview)

	vim.fn.maparg("q", "n", false, true).callback()

	assert(vim.api.nvim_get_current_win() == state.query_win)
	assert(not vim.api.nvim_buf_is_valid(search))

	workspace.next_query()
	workspace.previous_query()
	workspace.next_query()
	workspace.close_query()

	assert(state.query == preview and vim.api.nvim_buf_is_valid(other))

	vim.bo[other].modified = false
	vim.api.nvim_buf_set_lines(state.query, 0, -1, false, { "FAIL" })
	plugin.run()

	assert(vim.wait(3000, function()
		return state.cancel == nil
	end))

	rendered = table.concat(vim.api.nvim_buf_get_lines(state.results, 0, -1, false), "\n")

	assert(rendered:match("postgres failure"), rendered)

	vim.api.nvim_buf_set_lines(state.query, 0, -1, false, { "BADCSV" })
	plugin.run()

	assert(vim.wait(3000, function()
		return state.cancel == nil
	end))

	rendered = table.concat(vim.api.nvim_buf_get_lines(state.results, 0, -1, false), "\n")

	assert(rendered:match("Decode error"), rendered)

	vim.bo[state.query].modified = false
	vim.bo[query].modified = false
	require("dbc.workspace").close()
	vim.fn.delete(state.storage)
	require("tests.templates").run()
	vim.fn.delete(state.storage)
	require("tests.actions").run()
	vim.fn.delete(state.storage)
	require("tests.providers").run()
	require("tests.aws_provider").run()
	require("tests.connection_store").run()
end, debug.traceback)
vim.fn.delete(temporary)
vim.fn.delete(pg_temporary)
vim.fn.delete(data_home, "rf")

if not ok then
	io.stderr:write(err .. "\n")
	vim.cmd("cquit 1")
end

print("All plugin tests passed.")

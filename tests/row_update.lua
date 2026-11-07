local update = require("dbc.row_update")
local binding = { profile = { adapter = "sqlite" }, database = "test.db" }
local node = update.source('SELECT * FROM "a""b" LIMIT 100;', binding)
local ctx = require("dbc.actions").context(node)
ctx.metadata = {
	columns = {
		{ name = "id", primary_key = true },
		{ name = "tenant", primary_key = true },
		{ name = "text" },
		{ name = "empty" },
		{ name = "missing" },
		{ name = "computed", generated = true },
	},
}
local row = {
	columns = { "id", "tenant", "text", "empty", "missing", "computed" },
	values = { "42", "7", "O'Brien\n雪\\", "", vim.NIL, "ignore" },
}
local sql = update.generate(ctx, row)

assert(node.name == 'a"b')
assert(sql:find('UPDATE "a""b"', 1, true))
assert(sql:find("\"text\" = 'O''Brien\n雪\\'", 1, true))
assert(sql:find("\"empty\" = ''", 1, true))
assert(sql:find('"missing" = NULL', 1, true))
assert(sql:find("WHERE \"id\" = '42' AND \"tenant\" = '7';", 1, true))
assert(not sql:find('"computed"', 1, true))
assert(not pcall(update.source, "SELECT * FROM users JOIN other ON 1=1", binding))
assert(not pcall(update.source, "SELECT * FROM users; DELETE FROM users", binding))
assert(not pcall(update.source, "SELECT count(*) FROM users", binding))
assert(not pcall(update.generate, ctx, { columns = { "id", "text" }, values = { "1", "x" } }))
assert(not pcall(update.generate, ctx, { columns = { "id", "id" }, values = { "1", "1" } }))
assert(update.literal("a\\b'c", "postgres") == "E'a\\\\b''c'")
assert(update.literal("a\\b'c", "mysql") == "'a\\\\b''c'")

local sqlite = require("dbc.adapters").get(binding.profile)
local columns = sqlite.children(
	{ kind = "table" },
	{ { rows = { { "id", "INTEGER", "1", "0" }, { "v", "TEXT", "0", "2" } } } }
)

assert(columns[1].primary_key and not columns[1].generated)
assert(columns[2].generated and not columns[2].primary_key)

if vim.fn.executable("sqlite3") == 1 then
	local database = vim.fn.tempname()
	local setup = vim.system({ "sqlite3", database }, {
		stdin = "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO users VALUES (42, 'Alice');",
	}):wait()

	assert(setup.code == 0, setup.stderr)

	local plugin = require("dbc")
	local workspace = require("dbc.workspace")
	plugin.setup({ connections = { { name = "row-update", adapter = "sqlite", database = database } } })
	local state = plugin.open()
	local original = state.query
	vim.api.nvim_buf_set_lines(original, 0, -1, false, { "SELECT * FROM users;" })
	plugin.run()

	assert(vim.wait(3000, function()
		return state.cancel == nil
	end))

	local line = assert(next(state.cells))
	vim.api.nvim_set_current_win(state.results_win)
	vim.api.nvim_win_set_cursor(0, { line, 0 })

	assert(not pcall(workspace.update, line, line + 1))

	plugin.command({ fargs = { "update" }, range = 2, line1 = line, line2 = line })

	assert(vim.wait(3000, function()
		return state.query ~= original
	end))
	assert(#state.queries == 2)
	assert(state.bindings[state.query].database == database)
	assert(
		table.concat(vim.api.nvim_buf_get_lines(state.query, 0, -1, false), "\n")
			== 'UPDATE "users"\nSET\n    "name" = \'Alice\'\nWHERE "id" = \'42\';'
	)
	assert(vim.api.nvim_get_current_win() == state.query_win)
	assert(state.cancel == nil)

	workspace.close()
	vim.fn.delete(state.storage)
	vim.fn.delete(database)
end

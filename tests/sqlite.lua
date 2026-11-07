local sqlite = require("dbc.adapters").get({ adapter = "sqlite" })
local profile = { adapter = "sqlite", database = "/a b/test's.db" }
local request = sqlite.request(profile, nil, "SELECT 1")
local marker = request.argv[#request.argv - 2]

assert(request.argv[#request.argv] == profile.database)
assert(request.stdin == "SELECT 1")
assert(sqlite.request(profile, "/other.db", "SELECT 2").argv[#request.argv] == "/other.db")
assert(not pcall(sqlite.request, {}, nil, "SELECT 1"))
assert(sqlite.metadata({ kind = "connection", profile = profile }):find("test''s.db", 1, true))
assert(sqlite.metadata({ kind = "table", name = "it's" }):find("'it''s'", 1, true))
assert(sqlite.preview({ kind = "table", name = 'a"b' }) == 'SELECT * FROM "a""b" LIMIT 100;')
assert(not sqlite.capabilities.create_database)

local sets = request.decode("a,a,empty,text\n1," .. marker .. ',"","雪,one\n""two"""\n')

assert(sets[1].columns[1] == sets[1].columns[2])
assert(sets[1].rows[1][2] == vim.NIL)
assert(sets[1].rows[1][3] == "")
assert(sets[1].rows[1][4] == '雪,one\n"two"')
assert(#request.decode("") == 0)
assert(not pcall(request.decode, 'a\n"unfinished'))

local databases = sqlite.children({ kind = "connection" }, { { rows = { { profile.database } } } })
local tables = sqlite.children(databases[1], { { rows = { { "users", "view" } } } })
local columns = sqlite.children(tables[1], { { rows = { { "id", "INTEGER" } } } })

assert(databases[1].kind == "database" and databases[1].database == profile.database)
assert(tables[1].kind == "table" and tables[1].detail == "view")
assert(columns[1].kind == "column" and columns[1].detail == "INTEGER")
assert(columns[1].database == profile.database)

-- Exercise the actual CLI when available; the rest of the suite needs no client.
if vim.fn.executable("sqlite3") == 1 then
	local live = sqlite.request(
		{ database = ":memory:" },
		nil,
		[[
CREATE TABLE "a'b" (id INTEGER, value TEXT);
INSERT INTO "a'b" VALUES (1, '雪,"quoted"' || char(10) || 'next');
SELECT id AS a, id AS a, NULL AS n, '' AS e, value FROM "a'b";
]]
	)
	local result = vim.system(live.argv, { stdin = live.stdin, text = true }):wait()

	assert(result.code == 0, result.stderr)

	local decoded = live.decode(result.stdout)[1]

	assert(decoded.columns[1] == decoded.columns[2])
	assert(decoded.rows[1][3] == vim.NIL and decoded.rows[1][4] == "")
	assert(decoded.rows[1][5] == '雪,"quoted"\nnext')

	local function discover(node, setup)
		local discovery = sqlite.request({ database = ":memory:" }, nil, setup .. "\n" .. sqlite.metadata(node))
		local output = vim.system(discovery.argv, { stdin = discovery.stdin, text = true }):wait()

		assert(output.code == 0, output.stderr)

		return sqlite.children(node, discovery.decode(output.stdout))
	end

	local discovered = discover({ kind = "connection", profile = profile }, "")

	assert(discovered[1].database == profile.database)

	local setup = [[CREATE TABLE "a'b" ("a""b" INTEGER); CREATE VIEW v AS SELECT * FROM "a'b";]]
	local relations = discover({ kind = "database", database = profile.database }, setup)
	local fields = discover({ kind = "table", name = "a'b", database = profile.database }, setup)

	assert(#relations == 2 and relations[2].detail == "view")
	assert(fields[1].name == 'a"b' and fields[1].detail == "INTEGER")
	assert(fields[1].database == profile.database)

	local failure = sqlite.request({ database = ":memory:" }, nil, "SELECT * FROM missing; SELECT 1;")
	local failed = vim.system(failure.argv, { stdin = failure.stdin, text = true }):wait()

	assert(failed.code ~= 0 and failed.stdout == "")
end

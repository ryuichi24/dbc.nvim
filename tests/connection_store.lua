local M = {}

function M.run()
	local store = require("dbc.connection_store")
	local plugin = require("dbc")
	local workspace = require("dbc.workspace")
	local directory = vim.fn.tempname()
	local path = directory .. "/connections.json"
	local config = { connections_file = path, connections = { { name = "lua-dev", adapter = "mysql" } } }
	local original_select, original_input, original_notify = vim.ui.select, vim.ui.input, vim.notify
	local notices = {}
	vim.notify = function(message)
		table.insert(notices, message)
	end
	local state
	local function edit(form, values)
		local lines = vim.api.nvim_buf_get_lines(form.buf, 0, -1, false)

		for index, line in ipairs(lines) do
			local key = line:match("^([%w_]+):")

			if values[key] ~= nil then
				lines[index] = key .. ": " .. values[key]
			end
		end

		vim.api.nvim_buf_set_lines(form.buf, 0, -1, false, lines)
	end

	local function submit(form, mode)
		vim.api.nvim_set_current_win(form.win)

		for index, line in ipairs(vim.api.nvim_buf_get_lines(form.buf, 0, -1, false)) do
			if vim.trim(line) == "Add" then
				vim.api.nvim_win_set_cursor(form.win, { index, 0 })
				vim.fn.maparg("<CR>", mode or "n", false, true).callback()
				return
			end
		end

		error("Form is missing its Add action")
	end

	local ok, err = xpcall(function()
		local created, closed = 0, 0
		require("dbc.providers").register("connection-store-test", {
			create = function(profile)
				created = created + 1
				return {
					connect = function(done)
						done()
					end,
					resolve = function(_, done)
						done(nil, { profile = { host = profile.host } })
					end,
					close = function(done)
						closed = closed + 1
						done()
					end,
				}
			end,
		})
		local manager = require("dbc.connections").new({ timeout_ms = 1000 })
		local function resolve(host)
			local resolved
			manager:resolve(
				{ name = "same-name", provider = "connection-store-test", host = host },
				nil,
				function(failure, value)
					assert(not failure, failure)
					resolved = value
				end
			)

			assert(vim.wait(1000, function()
				return resolved ~= nil
			end))
			assert(resolved.profile.host == host)
		end

		-- Reloaded settings must not reuse the old provider's endpoint. Old query
		-- bindings can still use their original session until the workspace closes.
		resolve("old-host")
		resolve("new-host")
		resolve("old-host")

		assert(created == 2)

		manager:close()

		assert(closed == 2)
		assert(#store.load(config) == 0)
		assert(#store.resolve(config).connections == 1)

		store.ensure(config)

		assert(vim.fn.filereadable(path) == 1)
		assert(vim.json.decode(table.concat(vim.fn.readfile(path), "\n")))

		local sqlite = { name = "file-dev", adapter = "sqlite", database = "/a b/data.db" }
		store.add(config, sqlite)

		assert(vim.deep_equal(store.load(config), { sqlite }))
		assert(#store.resolve(config).connections == 2)
		assert(#config.connections == 1)
		assert(vim.fn.getfperm(path) == "rw-------")
		assert(not pcall(store.add, config, sqlite))
		assert(not pcall(store.add, config, config.connections[1]))
		assert(#store.load(config) == 1)

		local removable = { name = "removable", adapter = "postgres", database = "app" }
		store.add(config, removable)

		assert(not pcall(store.remove, config, { name = "removable", adapter = "postgres", database = "changed" }))
		assert(#store.load(config) == 2)

		store.remove(config, removable)

		assert(vim.deep_equal(store.load(config), { sqlite }))
		assert(not pcall(store.remove, config, removable))

		vim.fn.writefile({ "{ broken" }, path)
		local invalid = vim.fn.readfile(path)

		assert(not pcall(store.load, config))
		assert(not pcall(store.add, config, sqlite))
		assert(not pcall(store.remove, config, sqlite))
		assert(vim.deep_equal(vim.fn.readfile(path), invalid))

		for _, text in ipairs({
			"null",
			"{}",
			"[1]",
			'[{"name":"unknown","adapter":"missing"}]',
			'[{"name":"bad","password":"secret"}]',
			'[{"name":"bad","adapter":"sqlite"}]',
		}) do
			vim.fn.writefile({ text }, path)

			assert(not pcall(store.load, config), text)
		end

		-- A hand-written file is sufficient; setup only needs its path.
		vim.fn.writefile({ vim.json.encode({ sqlite }) }, path)
		plugin.setup(config)
		state = plugin.open()

		assert(#state.roots == 2 and state.roots[2].name == sqlite.name)

		vim.api.nvim_set_current_win(state.sidebar_win)
		vim.api.nvim_win_set_cursor(state.sidebar_win, { 4, 0 })

		assert(workspace.remove_connection() == nil)
		assert(notices[#notices]:find("Lua config", 1, true))
		assert(#state.roots == 2 and #store.load(config) == 1)

		plugin.command({ fargs = { "edit_connections" } })

		assert(vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)) == vim.uv.fs_realpath(path))

		plugin.open()

		assert(vim.api.nvim_get_current_win() == state.query_win)

		local original = state.roots[1]
		local query, binding = state.query, vim.deepcopy(state.bindings[state.query])
		vim.fn.writefile({ vim.json.encode({ { name = "manual", adapter = "postgres", database = "app" } }) }, path)
		workspace.reload_connections()

		assert(state.roots[1] == original)
		assert(#state.roots == 2 and state.roots[2].name == "manual")
		assert(state.query == query and vim.deep_equal(state.bindings[query], binding))

		vim.fn.writefile({ "invalid" }, path)

		assert(not pcall(workspace.reload_connections))
		assert(state.roots[2].name == "manual")

		vim.fn.writefile({ "[]" }, path)
		workspace.reload_connections()
		local form = workspace.add_connection()

		assert(vim.bo[form.buf].modifiable and vim.bo[form.buf].buftype == "nofile")
		assert(vim.api.nvim_get_current_buf() == form.buf)

		-- Enter on a field navigates normally and cannot submit the form.
		vim.fn.maparg("<CR>", "n", false, true).callback()

		assert(vim.api.nvim_buf_is_valid(form.buf) and #store.load(config) == 0)

		submit(form)

		assert(vim.api.nvim_buf_is_valid(form.buf) and #store.load(config) == 0)
		assert(notices[#notices]:find("name", 1, true))

		edit(form, { name = "dashboard", database = directory .. "/my database.db", port = "invalid" })
		submit(form)

		assert(vim.api.nvim_buf_is_valid(form.buf))
		assert(notices[#notices]:find("Port", 1, true))

		edit(form, { port = "" })
		submit(form)

		assert(#state.roots == 2 and state.roots[2].name == "dashboard")
		assert(store.load(config)[1].database == directory .. "/my database.db")
		assert(state.bindings[state.query].profile.name == "dashboard")
		assert(not vim.api.nvim_buf_is_valid(form.buf) and not vim.api.nvim_win_is_valid(form.win))

		-- Duplicate names fail without changing the file or workspace.
		form = workspace.add_connection()
		edit(form, { name = "dashboard", database = directory .. "/other.db" })
		local unchanged = vim.api.nvim_buf_get_lines(form.buf, 0, -1, false)
		submit(form)

		assert(#store.load(config) == 1 and #state.roots == 2)
		assert(notices[#notices]:find("unique", 1, true))
		assert(vim.api.nvim_buf_is_valid(form.buf))
		assert(vim.deep_equal(unchanged, vim.api.nvim_buf_get_lines(form.buf, 0, -1, false)))

		vim.fn.maparg("q", "n", false, true).callback()

		assert(#store.load(config) == 1)
		assert(not vim.api.nvim_buf_is_valid(form.buf))

		for _, adapter in ipairs({ "mysql", "postgres" }) do
			local profile
			form = require("dbc.connection_form").open(function(value)
				profile = value
			end)
			edit(form, {
				name = adapter .. "-form",
				adapter = adapter,
				database = "app",
				host = "localhost",
				port = "5432",
				user = "dev",
				[adapter == "mysql" and "login_path" or "service"] = "native-auth",
			})
			submit(form, adapter == "postgres" and "i" or "n")

			assert(profile.adapter == adapter and profile.database == "app")
			assert(profile.host == "localhost" and profile.port == 5432 and profile.user == "dev")
			assert(profile[adapter == "mysql" and "login_path" or "service"] == "native-auth")
		end

		-- Credential setup must finish successfully before the profile is saved.
		local editor = directory .. "/mysql_config_editor"
		vim.fn.writefile({ "#!/bin/sh", "exit 1" }, editor)
		vim.fn.setfperm(editor, "rwx------")
		local credential_profile
		form = require("dbc.connection_form").open(function(profile)
			credential_profile = profile
		end)
		edit(form, {
			name = "credentials",
			adapter = "mysql",
			host = "127.0.0.1",
			port = "33062",
			user = "dev",
			executable = directory .. "/mysql",
			save_password = "yes",
		})
		submit(form)

		assert(vim.wait(2000, function()
			return notices[#notices]:find("credential setup failed", 1, true) ~= nil
		end))
		assert(not credential_profile and vim.api.nvim_buf_is_valid(form.buf))

		vim.cmd.stopinsert()
		vim.cmd("bwipeout!")
		vim.fn.writefile({ "#!/bin/sh", 'test "$2" = "--login-path=credentials"' }, editor)
		submit(form)

		assert(vim.wait(2000, function()
			return credential_profile ~= nil
		end))
		assert(credential_profile.login_path == "credentials" and credential_profile.save_password == nil)
		assert(not vim.api.nvim_buf_is_valid(form.buf))

		local submitted
		form = require("dbc.connection_form").open(function(profile)
			submitted = profile
		end)
		vim.api.nvim_buf_set_lines(form.buf, 0, -1, false, {
			"# Fields can be reordered and optional fields removed.",
			"database: " .. directory .. "/reordered.db",
			"adapter: sqlite",
			"name: reordered",
			"name: duplicate",
			"",
			"  Add  ",
		})
		submit(form)

		assert(not submitted and vim.api.nvim_buf_is_valid(form.buf))
		assert(notices[#notices]:find("Duplicate field", 1, true))

		vim.api.nvim_buf_set_lines(form.buf, 4, 5, false, {})
		submit(form)

		assert(submitted.name == "reordered" and submitted.database == directory .. "/reordered.db")
		assert(not vim.api.nvim_buf_is_valid(form.buf))

		workspace.close()
		state = plugin.open()

		assert(#state.roots == 2 and state.roots[2].name == "dashboard")
		assert(state.bindings[state.query].profile.name == "dashboard")

		workspace.close()
		vim.fn.delete(state.storage)
		vim.fn.writefile({ "[]" }, path)
		plugin.setup({ connections_file = path })
		state = plugin.open()

		assert(#state.roots == 0 and state.bindings[state.query] == nil)

		vim.api.nvim_set_current_win(state.sidebar_win)
		form = vim.fn.maparg("a", "n", false, true).callback()
		edit(form, { name = "first", database = directory .. "/first.db" })
		submit(form)

		assert(#state.roots == 1 and state.bindings[state.query].profile.name == "first")
		assert(store.load({ connections_file = path })[1].name == "first")

		local function select_connection(name)
			vim.api.nvim_set_current_win(state.sidebar_win)

			for line, node in pairs(state.nodes) do
				if node.kind == "connection" and node.name == name then
					vim.api.nvim_win_set_cursor(state.sidebar_win, { line, 0 })
					return
				end
			end

			error("Missing connection: " .. name)
		end

		select_connection("first")
		local popup = vim.fn.maparg("d", "n", false, true).callback()

		assert(vim.api.nvim_win_get_cursor(popup.win)[1] == 4, "Cancel is selected by default")
		assert(#store.load({ connections_file = path }) == 1)

		vim.fn.maparg("<CR>", "n", false, true).callback()

		assert(not vim.api.nvim_buf_is_valid(popup.buf))
		assert(#state.roots == 1 and #store.load({ connections_file = path }) == 1)

		for _, key in ipairs({ "q", "<Esc>" }) do
			select_connection("first")
			popup = workspace.remove_connection()
			vim.fn.maparg(key, "n", false, true).callback()

			assert(not vim.api.nvim_buf_is_valid(popup.buf) and #state.roots == 1)
		end

		-- A connection changed while confirmation is open must not be deleted.
		select_connection("first")
		popup = workspace.remove_connection()
		local changed = { name = "first", adapter = "sqlite", database = directory .. "/changed.db" }
		vim.fn.writefile({ vim.json.encode({ changed }) }, path)
		vim.api.nvim_win_set_cursor(popup.win, { 5, 0 })
		vim.fn.maparg("<CR>", "n", false, true).callback()

		assert(#state.roots == 1 and #store.load({ connections_file = path }) == 1)
		assert(notices[#notices]:find("changed on disk", 1, true))

		store.add({ connections_file = path }, { name = "keep", adapter = "mysql" })
		workspace.reload_connections()
		local removed_query = state.query
		workspace.query({ profile = state.roots[1].profile, database = "another" })
		local another_query = state.query
		local kept_query = workspace.query({ profile = state.roots[2].profile })
		workspace.goto_query(2)
		select_connection("first")
		popup = workspace.remove_connection()
		vim.api.nvim_win_set_cursor(popup.win, { 5, 0 })
		vim.fn.maparg("<CR>", "n", false, true).callback()

		assert(#state.roots == 1 and state.roots[1].name == "keep")
		assert(store.load({ connections_file = path })[1].name == "keep")
		assert(state.bindings[removed_query] == nil and state.bindings[another_query] == nil)
		assert(state.bindings[kept_query].profile.name == "keep")

		for _, tab in ipairs(state.queries) do
			assert(tab.buf ~= removed_query and tab.buf ~= another_query)
		end

		assert(vim.api.nvim_buf_is_valid(state.query))

		workspace.close()
		state = plugin.open()

		assert(#state.roots == 1 and state.roots[1].name == "keep")
	end, debug.traceback)
	vim.ui.select, vim.ui.input, vim.notify = original_select, original_input, original_notify

	if state and not state.disposed then
		workspace.close()
	end

	if state then
		vim.fn.delete(state.storage)
	end

	vim.fn.delete(directory, "rf")
	assert(ok, err)
end

return M

local M = {}

function M.run()
	local actions = require("dbc.actions")
	local workspace = require("dbc.workspace")
	local plugin = require("dbc")
	local registered, metadata_names = {}, {}
	local original_select, original_notify = vim.ui.select, vim.notify
	local notices = {}
	vim.notify = function(message)
		table.insert(notices, message)
	end
	local function register(action)
		actions.register(action)
		table.insert(registered, action.id)
	end

	local function metadata(name, loader)
		actions.register_metadata(name, loader)
		table.insert(metadata_names, name)
	end

	local state
	local ok, err = xpcall(function()
		local update = require("tests.fixtures.custom_action")
		register(update)

		assert(not pcall(actions.register, update), "Duplicate IDs must not silently replace installed actions")
		assert(not pcall(actions.register, { id = "invalid", label = "Invalid", node_kinds = { "table" } }))

		local copy = actions.get(update.id)
		copy.label = "Changed externally"

		assert(actions.get(update.id).label == "UPDATE row", "Registry owns its action definitions")

		actions.register(copy, { replace = true })

		assert(actions.get(update.id).label == "Changed externally")

		actions.register(update, { replace = true })

		plugin.setup({ connections = { { name = "action-test", adapter = "mysql", database = "db" } } })
		state = plugin.open()
		local original_query = state.query
		local metadata_calls = 0
		state.runner.run = function(_, _, sql, done)
			metadata_calls = metadata_calls + 1
			local rows

			if sql == "SHOW DATABASES" then
				rows = { { "db" } }
			elseif sql == "SHOW FULL TABLES" then
				rows = { { "users", "BASE TABLE" } }
			elseif sql == "SHOW COLUMNS FROM `users`" then
				rows = { { "id", "int", "NO", "PRI" } }
			else
				error("Actions must not execute generated SQL: " .. sql)
			end

			vim.schedule(function()
				done({ code = 0, duration = 0, stdout = "", stderr = "", sets = { { columns = {}, rows = rows } } })
			end)
			return function() end
		end

		local function wait()
			assert(vim.wait(1000, function()
				return not next(state.metadata_jobs) and not next(state.action_jobs)
			end))
		end

		local function select(node)
			vim.api.nvim_set_current_win(state.sidebar_win)

			for line, value in pairs(state.nodes) do
				if node == value then
					vim.api.nvim_win_set_cursor(0, { line, 0 })
					return
				end
			end

			error("Node must be visible")
		end

		local function text()
			return table.concat(vim.api.nvim_buf_get_lines(state.query, 0, -1, false), "\n")
		end

		select(state.roots[1])
		workspace.refresh()
		wait()
		local database = state.roots[1].children[1]
		select(database)
		workspace.refresh()
		wait()
		local relation = database.children[1]
		local ctx = actions.context(relation)

		assert(actions.default(ctx).id == "insert", "Adding an action must not change the default implicitly")

		local no_database_creation = actions.context(state.roots[1])
		no_database_creation.adapter = vim.deepcopy(no_database_creation.adapter)
		no_database_creation.adapter.capabilities.create_database = false

		assert(#actions.list(no_database_creation) == 0, "Quoting alone does not imply CREATE DATABASE support")
		assert(not pcall(actions.generate, {
			generate = function()
				return { sql = "SELECT 1", cursor = { 9, 0 } }
			end,
		}, ctx), "Invalid cursor positions must fail before creating a tab")

		local picker
		vim.ui.select = function(items, opts, done)
			picker = { items = items, done = done }

			assert(opts.format_item(items[1]) == items[1].label)
		end
		select(relation)
		vim.fn.maparg("A", "n", false, true).callback()
		local choice

		for _, item in ipairs(picker.items) do
			if item.id == update.id then
				choice = item
			end
		end

		assert(choice and #picker.items == 4, "Picker includes built-ins and plugin actions")

		-- The selected action retains its original node if the sidebar cursor moves.
		select(database)
		picker.done(choice)
		wait()

		assert(text() == "UPDATE `db`.`users` SET `id` = <value>\nWHERE <condition>;")
		assert(vim.deep_equal(vim.api.nvim_win_get_cursor(state.query_win), { 2, 6 }))
		assert(state.query ~= original_query and state.bindings[state.query].database == "db")
		assert(metadata_calls == 3 and state.cancel == nil, "Only schema discovery was executed")

		local preferred = vim.deepcopy(update)
		preferred.id, preferred.default, preferred.priority = "test.preferred", true, 100
		register(preferred)

		assert(actions.default(ctx).id == preferred.id)

		select(relation)
		vim.fn.maparg("a", "n", false, true).callback()
		wait()

		assert(text():find("UPDATE", 1, true) == 1)
		assert(metadata_calls == 3, "Declared column metadata reuses the cache")

		actions.unregister(preferred.id)

		assert(actions.default(ctx).id == "insert")

		local restricted = vim.deepcopy(update)
		restricted.id, restricted.adapters = "test.pg_only", { "postgres" }
		register(restricted)
		local hidden = vim.deepcopy(update)
		hidden.id, hidden.available = "test.hidden", function()
			return false
		end
		register(hidden)

		assert(#actions.list(ctx) == 4, "Adapter and availability filters exclude unsupported actions")

		-- A custom metadata loader composes with built-in columns, without UI changes.
		metadata("test.extra", function(context, done)
			assert(context.metadata.columns[1].name == "id")

			vim.schedule(function()
				done(nil, "ready")
			end)
		end)
		register({
			id = "test.composed",
			label = "Composed",
			node_kinds = { "table" },
			requires = { "columns", "test.extra" },
			generate = function(context)
				assert(context.metadata["test.extra"] == "ready")

				return "SELECT <composed>;"
			end,
		})
		select(relation)
		plugin.action("test.composed")
		wait()

		assert(text() == "SELECT <composed>;")

		metadata("test.failure", function(_, done)
			done("Metadata permission denied")
		end)
		local strict = {
			id = "test.strict",
			label = "Strict",
			node_kinds = { "table" },
			requires = { "test.failure" },
			generate = function()
				error("Strict action must not generate after failed metadata")
			end,
		}
		register(strict)
		select(relation)
		local count = #state.queries
		plugin.action(strict.id)
		wait()

		assert(#state.queries == count and notices[#notices]:find("Metadata permission denied", 1, true))

		local optional = vim.deepcopy(strict)
		optional.id, optional.allow_missing_metadata = "test.optional", true
		optional.generate = function(context)
			assert(context.metadata_errors["test.failure"] == "Metadata permission denied")

			return "SELECT <fallback>;"
		end
		register(optional)
		plugin.action(optional.id)
		wait()

		assert(text() == "SELECT <fallback>;")

		local cancellations = 0
		local late
		metadata("test.pending", function(_, done)
			late = done
			return function()
				cancellations = cancellations + 1
			end
		end)
		local pending = vim.deepcopy(strict)
		pending.id, pending.requires = "test.pending", { "test.pending" }
		register(pending)
		select(relation)
		state.config.execution.timeout_ms = 20
		count = #state.queries
		plugin.action(pending.id)
		wait()

		assert(cancellations == 1 and #state.queries == count)
		assert(notices[#notices]:find("timed out", 1, true))

		state.config.execution.timeout_ms = 1000

		-- Third-party adapter.template remains a compatibility action.
		local legacy = vim.deepcopy(require("dbc.adapters.mysql"))
		legacy.template = function()
			return "SELECT <legacy>;"
		end
		require("dbc.adapters").register("test-legacy", legacy)
		local legacy_ctx =
			actions.context({ kind = "table", name = "users", profile = { name = "legacy", adapter = "test-legacy" } })
		local legacy_action = actions.default(legacy_ctx)

		assert(legacy_action.id == "legacy_template")
		assert(actions.generate(legacy_action, legacy_ctx).sql == "SELECT <legacy>;")

		local procedure = relation.children[1]
		procedure.kind = "procedure"
		register({
			id = "test.procedure",
			label = "Call procedure",
			node_kinds = { "procedure" },
			default = true,
			generate = function(context)
				return "CALL " .. context.quote(context.node.name) .. "(<argument>);"
			end,
		})
		select(procedure)
		workspace.add_query()
		wait()

		assert(text() == "CALL `id`(<argument>);", "New node kinds need no sidebar dispatch changes")

		select(relation)
		late = nil
		plugin.action(pending.id)

		assert(vim.wait(1000, function()
			return next(state.action_jobs) and late ~= nil
		end))

		workspace.actions()
		count = #state.queries
		workspace.close()
		late(nil, "too late")
		picker.done(choice)
		vim.wait(30, function()
			return false
		end)

		assert(cancellations == 2 and #state.queries == count and not next(state.action_jobs))
	end, debug.traceback)

	if state and not state.disposed then
		workspace.close()
	end

	for _, id in ipairs(registered) do
		actions.unregister(id)
	end

	for _, name in ipairs(metadata_names) do
		actions.unregister_metadata(name)
	end

	vim.ui.select, vim.notify = original_select, original_notify

	if not ok then
		error(err)
	end
end

return M

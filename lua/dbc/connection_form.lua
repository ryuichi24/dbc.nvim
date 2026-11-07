local M = {}
local api = vim.api
local namespace = api.nvim_create_namespace("dbc.connection_form")
local fields = { "name", "adapter", "database", "host", "port", "user", "login_path", "service", "executable" }

local function parse(lines)
	local profile, seen = {}, {}

	for _, line in ipairs(lines) do
		local text = vim.trim(line)

		if text ~= "" and text ~= "Add" and not text:match("^#") then
			local key, value = text:match("^([%w_]+):%s*(.*)$")
			assert(key and vim.tbl_contains(fields, key), "Use field: value for a supported connection field")
			assert(not seen[key], "Duplicate field: " .. key)
			seen[key] = true
			value = vim.trim(value)

			if value ~= "" then
				profile[key] = value
			end
		end
	end

	assert(
		vim.tbl_contains({ "sqlite", "mysql", "postgres" }, profile.adapter),
		"Adapter must be sqlite, mysql, or postgres"
	)

	if profile.port then
		local port = tonumber(profile.port)
		assert(port and port % 1 == 0 and port >= 1 and port <= 65535, "Port must be an integer between 1 and 65535")
		profile.port = port
	end

	require("dbc.connection_store").validate({ profile })

	if profile.adapter == "sqlite" and profile.database ~= ":memory:" and not profile.database:match("^file:") then
		profile.database = vim.fn.fnamemodify(vim.fn.expand(profile.database), ":p")
	end

	return profile
end

function M.open(done)
	local buf = api.nvim_create_buf(false, true)
	local lines = {
		"# Edit values freely. Blank optional fields are omitted.",
		"# Enter on Add submits; normal-mode q cancels.",
		"# adapter: sqlite / mysql / postgres",
		"# SQLite: database is a file path. MySQL: login_path.",
		"# PostgreSQL: service. Authentication is client-native.",
		"",
	}

	for _, key in ipairs(fields) do
		table.insert(lines, key .. ": " .. (key == "adapter" and "sqlite" or ""))
	end

	table.insert(lines, "")
	table.insert(lines, "Add")
	api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "dbc-connection"
	local width = math.max(1, math.min(64, vim.o.columns - 4))
	local height = math.max(1, math.min(#lines, vim.o.lines - vim.o.cmdheight - 4))
	local win = api.nvim_open_win(buf, true, {
		relative = "editor",
		style = "minimal",
		border = "rounded",
		title = " Add connection ",
		width = width,
		height = height,
		row = math.max(0, math.floor((vim.o.lines - height - 2) / 2)),
		col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
	})
	vim.wo[win].wrap = false
	api.nvim_win_set_cursor(win, { 7, 6 })
	local function close()
		if api.nvim_win_is_valid(win) then
			api.nvim_win_close(win, true)
		end

		if api.nvim_buf_is_valid(buf) then
			api.nvim_buf_delete(buf, { force = true })
		end
	end

	local function highlight()
		api.nvim_buf_clear_namespace(buf, namespace, 0, -1)

		for index, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
			if vim.trim(line) == "Add" then
				api.nvim_buf_set_extmark(buf, namespace, index - 1, 0, { end_col = #line, hl_group = "Special" })
			end
		end
	end

	local submitting = false
	local function submit()
		if vim.trim(api.nvim_get_current_line()) ~= "Add" then
			vim.cmd("normal! +")
			return
		end

		if submitting then
			return
		end

		local ok, profile = pcall(parse, api.nvim_buf_get_lines(buf, 0, -1, false))

		if not ok then
			vim.notify("dbc: " .. tostring(profile), vim.log.levels.ERROR)
			return
		end

		submitting = true
		local saved, result = pcall(done, profile)
		submitting = false

		if not saved then
			vim.notify("dbc: " .. tostring(result), vim.log.levels.ERROR)
		elseif result ~= false then
			close()
		end
	end

	vim.keymap.set("n", "<CR>", submit, { buffer = buf, desc = "Add connection when on Add" })
	vim.keymap.set("i", "<CR>", function()
		if vim.trim(api.nvim_get_current_line()) == "Add" then
			vim.cmd.stopinsert()
			submit()
		else
			api.nvim_feedkeys(api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
		end
	end, { buffer = buf, desc = "Add connection or insert a newline" })
	vim.keymap.set("n", "q", close, { buffer = buf, desc = "Cancel new connection" })
	api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { buffer = buf, callback = highlight })
	highlight()
	return { buf = buf, win = win }
end

return M

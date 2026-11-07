local M = {}
local api = vim.api
local popup

function M.close()
	local p = popup

	if not p then
		return
	end

	popup = nil
	vim.cmd.stopinsert()

	for _, win in ipairs({ p.search_win, p.list_win }) do
		if api.nvim_win_is_valid(win) then
			api.nvim_win_close(win, true)
		end
	end

	if api.nvim_win_is_valid(p.origin) then
		api.nvim_set_current_win(p.origin)
	end
end

function M.open(opts)
	M.close()
	local p = { origin = api.nvim_get_current_win(), items = {}, index = 1 }
	local width = math.max(1, math.min(100, vim.o.columns - 4))
	local height = math.max(1, math.min(12, vim.o.lines - 8))
	local row = math.max(0, math.floor((vim.o.lines - height - 6) / 2))
	local col = math.max(0, math.floor((vim.o.columns - width - 2) / 2))
	p.search = api.nvim_create_buf(false, true)
	p.list = api.nvim_create_buf(false, true)

	for _, buf in ipairs({ p.search, p.list }) do
		vim.bo[buf].bufhidden = "wipe"
		vim.bo[buf].filetype = "dbc_picker"
	end

	p.list_win = api.nvim_open_win(p.list, false, {
		relative = "editor",
		row = row + 3,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		focusable = false,
		zindex = 60,
		footer = " j/k: select · i: filter · Enter: open · q: close ",
	})
	vim.wo[p.list_win].cursorline = true
	vim.wo[p.list_win].wrap = false
	p.search_win = api.nvim_open_win(p.search, true, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = 1,
		style = "minimal",
		border = "rounded",
		zindex = 60,
		title = " dbc query tabs · search ",
	})
	popup = p

	local function render()
		if popup ~= p then
			return
		end

		local previous = p.items[p.index]
		local query = table.concat(api.nvim_buf_get_lines(p.search, 0, -1, false), " "):lower()
		p.items = {}
		local lines = {}

		for _, item in ipairs(opts.items()) do
			local matches = true

			for word in query:gmatch("%S+") do
				if not item.search:lower():find(word, 1, true) then
					matches = false
					break
				end
			end

			if matches then
				table.insert(p.items, item)
				table.insert(lines, (item.label:gsub("[%c]", " ")))
			end
		end

		p.index = math.max(1, math.min(p.index, #p.items))

		for index, item in ipairs(p.items) do
			if previous and previous.key == item.key then
				p.index = index
			end
		end

		vim.bo[p.list].modifiable = true
		api.nvim_buf_set_lines(p.list, 0, -1, false, #lines > 0 and lines or { "No matching query tabs" })
		vim.bo[p.list].modifiable = false
		api.nvim_win_set_cursor(p.list_win, { p.index, 0 })
	end

	local function move(delta)
		if #p.items > 0 then
			p.index = (p.index - 1 + delta) % #p.items + 1
			api.nvim_win_set_cursor(p.list_win, { p.index, 0 })
		end
	end

	for _, mode in ipairs({ "n", "i" }) do
		for _, key in ipairs({ "<Down>", "<C-n>" }) do
			vim.keymap.set(mode, key, function()
				move(1)
			end, { buffer = p.search })
		end

		for _, key in ipairs({ "<Up>", "<C-p>" }) do
			vim.keymap.set(mode, key, function()
				move(-1)
			end, { buffer = p.search })
		end

		vim.keymap.set(mode, "<CR>", function()
			local item = p.items[p.index]

			if item then
				M.close()
				opts.select(item)
			end
		end, { buffer = p.search })
	end

	vim.keymap.set("n", "j", function()
		move(1)
	end, { buffer = p.search })
	vim.keymap.set("n", "k", function()
		move(-1)
	end, { buffer = p.search })
	vim.keymap.set("n", "q", M.close, { buffer = p.search })
	vim.keymap.set("i", "<Esc>", "<Esc>", { buffer = p.search })
	api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { buffer = p.search, callback = render })
	api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(p.search_win),
		once = true,
		callback = function()
			if popup == p then
				M.close()
			end
		end,
	})
	render()
	vim.cmd.stopinsert()
end

return M

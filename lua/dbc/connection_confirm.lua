local M = {}

function M.open(name, done)
	local api = vim.api
	local buf = api.nvim_create_buf(false, true)
	local label = name:gsub("%c", " ")
	api.nvim_buf_set_lines(buf, 0, -1, false, {
		"Remove saved connection?",
		label,
		"",
		"Cancel",
		"Remove",
	})
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].modifiable = false
	local width = math.max(1, math.min(math.max(32, vim.fn.strdisplaywidth(label)), 64, vim.o.columns - 4))
	local height = math.max(1, math.min(5, vim.o.lines - vim.o.cmdheight - 4))
	local win = api.nvim_open_win(buf, true, {
		relative = "editor",
		style = "minimal",
		border = "rounded",
		title = " Remove connection ",
		width = width,
		height = height,
		row = math.max(0, math.floor((vim.o.lines - height - 2) / 2)),
		col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
	})
	api.nvim_win_set_cursor(win, { 4, 0 })
	local function close()
		if api.nvim_win_is_valid(win) then
			api.nvim_win_close(win, true)
		end
	end

	vim.keymap.set("n", "<CR>", function()
		local line = api.nvim_win_get_cursor(win)[1]

		if line == 4 or line == 5 then
			close()

			if line == 5 then
				done()
			end
		end
	end, { buffer = buf, desc = "Confirm or cancel connection removal" })

	for _, key in ipairs({ "q", "<Esc>" }) do
		vim.keymap.set("n", key, close, { buffer = buf, desc = "Cancel connection removal" })
	end

	return { buf = buf, win = win }
end

return M

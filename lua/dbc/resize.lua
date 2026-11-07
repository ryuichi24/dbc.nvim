local M = {}
local api = vim.api
local namespace = api.nvim_create_namespace("DbcResize")
local active

function M.stop()
	if not active then
		return
	end

	local mode = active
	active = nil
	vim.on_key(nil, namespace)
	api.nvim_del_augroup_by_id(mode.group)

	if not api.nvim_buf_is_valid(mode.buf) then
		return
	end

	api.nvim_buf_call(mode.buf, function()
		for _, key in ipairs({ "h", "j", "k", "l" }) do
			vim.keymap.del("n", key, { buffer = mode.buf })

			if mode.saved[key] then
				vim.fn.mapset("n", false, mode.saved[key])
			end
		end
	end)
end

function M.start(key, resize)
	resize(key)

	if active and active.win == api.nvim_get_current_win() then
		return
	end

	M.stop()
	local mode = {
		win = api.nvim_get_current_win(),
		buf = api.nvim_get_current_buf(),
		saved = {},
		group = api.nvim_create_augroup("DbcResize", { clear = true }),
	}
	active = mode

	for _, direction in ipairs({ "h", "j", "k", "l" }) do
		local saved = vim.fn.maparg(direction, "n", false, true)

		if saved.buffer == 1 then
			mode.saved[direction] = saved
		end

		vim.keymap.set("n", direction, function()
			resize(direction)
		end, { buffer = mode.buf, nowait = true, desc = "Resize dbc pane (any other key exits)" })
	end

	api.nvim_create_autocmd({ "WinLeave", "BufLeave", "BufWipeout" }, {
		group = mode.group,
		buffer = mode.buf,
		callback = M.stop,
	})
	vim.on_key(function(_, typed)
		if typed ~= "" and not ({ h = true, j = true, k = true, l = true })[typed] then
			M.stop()
		end
	end, namespace)
end

return M

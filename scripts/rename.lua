-- Run from the repository root: nvim --headless -u NONE -i NONE -l scripts/rename.lua my-tool
local function main()
	local name = arg[1]

	if #arg ~= 1 or not name or not name:match("^[A-Za-z][A-Za-z0-9_-]*$") then
		error(
			"Usage: nvim --headless -u NONE -i NONE -l scripts/rename.lua <name> (letters, digits, _ or -; start with a letter)"
		)
	end

	local module = name:gsub("-", "_"):lower()
	local command = module:gsub("%f[%w]%l", string.upper):gsub("_", "")
	local placeholder = "plugin" .. "_name"
	local old_command = "Plugin" .. "Name"

	if module == placeholder then
		error("Choose a name other than the template placeholder")
	end

	local paths = {
		{ "lua/" .. placeholder .. "/init.lua", "lua/" .. module .. "/init.lua" },
		{ "plugin/" .. placeholder .. ".lua", "plugin/" .. module .. ".lua" },
		{ "tests/run.lua", "tests/run.lua" },
		{ "README.md", "README.md" },
	}
	local contents = {}

	if vim.uv.fs_stat("lua/" .. module) or vim.uv.fs_stat("plugin/" .. module .. ".lua") then
		error("Destination already exists for " .. module)
	end

	-- Read every source before changing anything, including on repeated runs.
	for index, paths_pair in ipairs(paths) do
		local lines = vim.fn.readfile(paths_pair[1])
		contents[index] = {}

		for line_number, line in ipairs(lines) do
			if paths_pair[1] == "README.md" then
				if line_number == 1 then
					line = "# " .. name
				end
			else
				line = line:gsub(placeholder, module):gsub(old_command, command)
			end

			table.insert(contents[index], line)
		end
	end

	vim.fn.mkdir("lua/" .. module, "p")

	for index, paths_pair in ipairs(paths) do
		assert(vim.fn.writefile(contents[index], paths_pair[2]) == 0, "Could not write " .. paths_pair[2])

		if paths_pair[1] ~= paths_pair[2] then
			assert(vim.fn.delete(paths_pair[1]) == 0, "Could not remove " .. paths_pair[1])
		end
	end

	assert(vim.fn.delete("lua/" .. placeholder, "d") == 0, "Could not remove old module directory")
	print("Initialized " .. module .. ' (require("' .. module .. '"); :' .. command .. ")")
end

local ok, err = pcall(main)

if not ok then
	io.stderr:write(tostring(err) .. "\n")
	vim.cmd("cquit 1")
end

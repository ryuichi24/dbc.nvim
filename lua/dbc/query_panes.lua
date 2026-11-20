local M = {}

function M.split(tree, pane, added, direction)
	if tree == pane then
		return { first = pane, second = added, direction = direction }
	end

	if tree.first then
		tree.first = M.split(tree.first, pane, added, direction)
		tree.second = M.split(tree.second, pane, added, direction)
	end

	return tree
end

function M.remove(tree, pane)
	if tree == pane then
		return nil
	end

	if tree.first then
		tree.first = M.remove(tree.first, pane)
		tree.second = M.remove(tree.second, pane)
		return tree.first and tree.second and tree or tree.first or tree.second
	end

	return tree
end

function M.layout(tree, geometry, apply)
	if not tree.first then
		apply(tree, geometry)
		return
	end

	local first, second = vim.deepcopy(geometry), vim.deepcopy(geometry)
	local dimension = tree.direction == "vertical" and "width" or "height"
	local position = tree.direction == "vertical" and "col" or "row"
	first[dimension] = math.max(1, math.floor((geometry[dimension] - 2) / 2))
	second[dimension] = math.max(1, geometry[dimension] - first[dimension] - 2)
	second[position] = geometry[position] + first[dimension] + 2
	M.layout(tree.first, first, apply)
	M.layout(tree.second, second, apply)
end

return M

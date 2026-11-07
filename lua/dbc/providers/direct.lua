local M = {}

function M.create()
	return {
		connect = function(done)
			done(nil)
		end,
		resolve = function(_, done)
			done(nil, {})
		end,
		close = function(done)
			done(nil)
		end,
	}
end

return M

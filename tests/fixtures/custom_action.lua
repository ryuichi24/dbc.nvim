-- A plugin-style module: no knowledge of workspace internals or CLI execution.
return {
	id = "test.update",
	label = "UPDATE row",
	node_kinds = { "table" },
	adapter_methods = { "quote", "qualify" },
	requires = { "columns" },
	generate = function(ctx)
		return {
			sql = "UPDATE "
				.. ctx.qualify()
				.. " SET "
				.. ctx.quote(ctx.metadata.columns[1].name)
				.. " = <value>\nWHERE <condition>;",
			cursor = { 2, 6 },
		}
	end,
}

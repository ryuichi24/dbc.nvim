return {
	id = "preview",
	label = "SELECT preview",
	node_kinds = { "table" },
	adapter_methods = { "preview" },
	generate = function(ctx)
		return ctx.adapter.preview(ctx.node)
	end,
}

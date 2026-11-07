return {
	id = "update",
	label = "UPDATE rows",
	node_kinds = { "table" },
	adapter_methods = { "quote", "qualify" },
	capabilities = { "update" },
	requires = { "columns" },
	allow_missing_metadata = true,
	generate = function(ctx)
		return require("dbc.templates").update(ctx.qualify(), ctx.quote, ctx.metadata.columns)
	end,
}

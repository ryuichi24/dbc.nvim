return {
	id = "insert",
	label = "INSERT row",
	node_kinds = { "table" },
	adapter_methods = { "quote", "qualify" },
	capabilities = { "insert" },
	requires = { "columns" },
	allow_missing_metadata = true,
	default = true,
	generate = function(ctx)
		return require("dbc.templates").insert(ctx.qualify(), ctx.quote, ctx.metadata.columns)
	end,
}

return {
	id = "create_table",
	label = "CREATE TABLE",
	node_kinds = { "database", "schema" },
	adapter_methods = { "quote", "qualify" },
	capabilities = { "create_table" },
	default = true,
	generate = function(ctx)
		return require("dbc.templates").create(ctx.qualify("<table_name>"), ctx.quote)
	end,
}

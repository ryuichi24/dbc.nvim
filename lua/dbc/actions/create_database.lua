return {
	id = "create_database",
	label = "CREATE DATABASE",
	node_kinds = { "connection" },
	adapter_methods = { "quote" },
	capabilities = { "create_database" },
	default = true,
	generate = function(ctx)
		return "CREATE DATABASE " .. ctx.quote("<database_name>") .. ";"
	end,
}

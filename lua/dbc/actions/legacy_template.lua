-- Keep third-party adapter.template implementations usable during migration.
return {
	id = "legacy_template",
	label = "Adapter template (legacy)",
	node_kinds = { "connection", "database", "schema", "table" },
	default = true,
	priority = 10,
	allow_missing_metadata = true,
	available = function(ctx)
		return type(ctx.adapter.template) == "function"
	end,
	requires = function(ctx)
		return ctx.node.kind == "table" and { "columns" } or {}
	end,
	generate = function(ctx)
		return ctx.adapter.template(ctx.node)
	end,
}

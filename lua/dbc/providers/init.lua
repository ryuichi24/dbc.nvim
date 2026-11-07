local M = {}
local registered = {}
local builtins = {
	direct = "dbc.providers.direct",
	command = "dbc.providers.command",
	aws_ssm_rds_iam = "dbc.providers.aws_ssm_rds_iam",
}

function M.register(name, provider)
	assert(type(name) == "string" and name ~= "", "Provider requires a name")
	assert(type(provider) == "table" and type(provider.create) == "function", "Provider requires create()")
	registered[name] = provider
end

function M.get(profile)
	local spec = profile.provider or "direct"
	local name = type(spec) == "table" and spec.name or spec
	assert(type(name) == "string", "Provider must be a name or a table with a name")

	if not registered[name] and builtins[name] then
		M.register(name, require(builtins[name]))
	end

	assert(registered[name], "Unknown connection provider: " .. name)
	return registered[name]
end

function M.validate(profile)
	local provider = M.get(profile)

	if provider.validate then
		provider.validate(profile)
	end
end

return M

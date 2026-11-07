local M = {}

local function wait(predicate)
	assert(vim.wait(5000, predicate), "Provider operation did not complete")
end

function M.run()
	local providers = require("dbc.providers")
	local limits = { timeout_ms = 3000, max_output_bytes = 10000, max_rows = 100 }
	local opens, connects, resolves, closes, cancelled, released = 0, 0, 0, 0, 0, 0
	local connect_callback, resolve_callback
	providers.register("controlled-test", {
		create = function()
			opens = opens + 1
			return {
				connect = function(done)
					connects = connects + 1
					connect_callback = done
					return function()
						cancelled = cancelled + 1
					end
				end,
				resolve = function(_, done)
					resolves = resolves + 1
					resolve_callback = done
				end,
				close = function(done)
					closes = closes + 1
					done(nil)
				end,
			}
		end,
	})
	local manager = require("dbc.connections").new(limits)
	local profile = { name = "controlled", provider = "controlled-test" }
	local first, second
	local cancel_first = manager:resolve(profile, "app", function(err)
		first = err
	end)
	local cancel_second = manager:resolve(profile, "app", function(err)
		second = err
	end)
	wait(function()
		return connects == 1
	end)

	assert(opens == 1, "Concurrent callers share connection setup")

	cancel_first()

	assert(first:match("cancelled") and cancelled == 0, "One caller must not cancel another caller's setup")

	connect_callback(nil)
	wait(function()
		return resolves == 1
	end)
	cancel_second()
	resolve_callback(nil, {
		release = function()
			released = released + 1
		end,
	})
	wait(function()
		return released == 1
	end)

	assert(second:match("cancelled"))
	assert(closes == 0, "Ready transport remains reusable after query cancellation")

	manager:close()
	manager:close()

	assert(closes == 1, "Provider closes exactly once")

	-- Failed setup is retired so a later query can retry the same profile.
	manager = require("dbc.connections").new(limits)
	local failure
	manager:resolve(profile, "app", function(err)
		failure = err
	end)
	wait(function()
		return opens == 2
	end)
	connect_callback("SSO expired")
	wait(function()
		return failure ~= nil
	end)

	assert(failure == "SSO expired" and closes == 2)

	local retry
	manager:resolve(profile, "app", function(err, value)
		assert(not err)

		retry = value
	end)
	wait(function()
		return opens == 3
	end)
	connect_callback(nil)
	wait(function()
		return resolves == 2
	end)
	resolve_callback(nil, {})
	wait(function()
		return retry ~= nil
	end)
	manager:close()

	assert(closes == 3)

	-- A preparation deadline cancels opening resources and never starts SQL.
	local runner = require("dbc.execution").new({ timeout_ms = 30, max_output_bytes = 1000 })
	local result
	runner:run({ profile = profile, database = "app" }, "SELECT 1", function(value)
		result = value
	end)
	wait(function()
		return result ~= nil
	end)

	assert(result.error:match("timed out"))
	assert(cancelled == 1 and closes == 4)

	-- Late connect completion cannot revive a closed/cancelled entry.
	connect_callback(nil)
	runner:close()

	assert(closes == 4)
	assert(not pcall(providers.get, { provider = "unknown" }))
	assert(not pcall(providers.register, "invalid", {}))

	local directory = vim.fn.tempname()
	vim.fn.mkdir(directory)
	local ok, err = xpcall(function()
		local log = directory .. "/helper.log"
		local client = directory .. "/mysql"
		vim.fn.writefile({
			"#!/bin/sh",
			'[ "$MYSQL_PWD" = fresh-iam-token ] || exit 9',
			'[ "$DBC_PROVIDER_TEST" = yes ] || exit 8',
			'case " $* " in *" --host=127.0.0.1 "*) ;; *) exit 7 ;; esac',
			'case " $* " in *" --enable-cleartext-plugin "*) ;; *) exit 6 ;; esac',
			"sql=$(cat)",
			'case "$sql" in *FAIL*) exit 1 ;; esac',
			'case "$sql" in *BADXML*) printf broken; exit 0 ;; esac',
			"printf '%s' '<resultset statement=\"select\"><row><field name=\"id\">1</field></row></resultset>'",
		}, client)
		vim.fn.setfperm(client, "rwx------")
		local helper = {
			vim.v.progpath,
			"--headless",
			"-u",
			"NONE",
			"-i",
			"NONE",
			"-l",
			"tests/fixtures/provider_helper.lua",
		}
		local connection = {
			name = "ssm-helper",
			executable = client,
			provider = { name = "command", command = helper, options = { log = log } },
		}
		runner = require("dbc.execution").new(limits)

		for index = 1, 2 do
			result = nil
			runner:run({ profile = connection, database = "app" }, index == 1 and "SELECT 1" or "FAIL", function(value)
				result = value
			end)
			wait(function()
				return result ~= nil
			end)

			assert(not result.error, result.error)
			assert(result.code == (index == 1 and 0 or 1), vim.inspect(result))
		end

		assert(connection.host == nil and connection.credentials == nil, "Resolved settings must not mutate profiles")

		runner:close()
		runner:close()
		wait(function()
			return vim.fn.filereadable(log) == 1 and #vim.fn.readfile(log) == 4
		end)
		local operations = vim.fn.readfile(log)
		local id = operations[1]:match("^open:(.+)$")

		assert(id and operations[2] == "resolve:" .. id and operations[3] == "resolve:" .. id)
		assert(operations[4] == "close:" .. id)

		local exit_log = directory .. "/exit.log"
		local exited = vim.system({
			vim.v.progpath,
			"--headless",
			"-u",
			"NONE",
			"-i",
			"NONE",
			"-l",
			"tests/fixtures/provider_exit.lua",
		}, { env = { DBC_TEST_CLIENT = client, DBC_TEST_LOG = exit_log }, timeout = 10000 }):wait()

		assert(exited.code == 0, exited.stderr)

		local exit_operations = vim.fn.readfile(exit_log)

		assert(#exit_operations == 3 and exit_operations[3]:match("^close:"), "Editor exit must await helper cleanup")

		local mysql = require("dbc.adapters.mysql")
		local request = mysql.request(
			{ ssl_ca = "/a b/ca.pem", ssl_mode = "VERIFY_CA", protocol = "TCP" },
			"app",
			"SELECT 1",
			{ password = "token" }
		)

		assert(request.env.MYSQL_PWD == "token")
		assert(not table.concat(request.argv, " "):find("token", 1, true))
		assert(vim.tbl_contains(request.argv, "--ssl-ca=/a b/ca.pem"))
		assert(vim.tbl_contains(request.argv, "--ssl-mode=VERIFY_CA"))

		request = require("dbc.adapters.postgres").request({}, "app", "SELECT 1", { password = "pg-token" })

		assert(request.env.PGPASSWORD == "pg-token")

		local request_releases, preparations, transport_closes = 0, 0, 0
		providers.register("credentials-test", {
			create = function()
				return {
					connect = function(done)
						done(nil)
					end,
					resolve = function(_, done)
						preparations = preparations + 1
						done(nil, {
							connection = { host = "127.0.0.1", enable_cleartext_plugin = true },
							credentials = { password = "fresh-iam-token" },
							env = { DBC_PROVIDER_TEST = "yes" },
							release = function()
								request_releases = request_releases + 1
							end,
						})
					end,
					close = function(done)
						transport_closes = transport_closes + 1
						done(nil)
					end,
				}
			end,
		})
		local credential_profile = { name = "credentials", executable = client, provider = "credentials-test" }
		runner = require("dbc.execution").new(limits)

		for _, sql in ipairs({ "SELECT 1", "FAIL", "BADXML" }) do
			result = nil
			runner:run({ profile = credential_profile, database = "app" }, sql, function(value)
				result = value
			end)
			wait(function()
				return result ~= nil
			end)

			assert(not result.error, result.error)
		end

		assert(result.decode_error)
		assert(
			preparations == 3 and request_releases == 3,
			"Release every resolution, including SQL and decoder failures"
		)

		runner:close()

		assert(transport_closes == 1)

		-- Request construction failure also releases temporary credential resources.
		credential_profile.executable = directory .. "/missing"
		runner = require("dbc.execution").new(limits)
		result = nil
		runner:run({ profile = credential_profile }, "SELECT 1", function(value)
			result = value
		end)
		wait(function()
			return result ~= nil
		end)

		assert(result.error:match("executable not found"))
		assert(request_releases == 4)

		runner:close()

		-- Workspace closure releases its retained provider session.
		credential_profile.executable = client
		local plugin = require("dbc")
		plugin.setup({ connections = { credential_profile } })
		local workspace = plugin.open()
		vim.api.nvim_buf_set_lines(workspace.query, 0, -1, false, { "SELECT 1" })
		plugin.run()
		wait(function()
			return workspace.cancel == nil
		end)
		vim.bo[workspace.query].modified = false
		require("dbc.workspace").close()

		assert(transport_closes == 3)

		-- Helper protocol errors reach the caller without exposing raw stdout.
		connection.provider.options.invalid = true
		runner = require("dbc.execution").new(limits)
		result = nil
		runner:run({ profile = connection, database = "app" }, "SELECT 1", function(value)
			result = value
		end)
		wait(function()
			return result ~= nil
		end)

		assert(result.error:match("invalid JSON"))

		-- Failed open also invokes close using the known ID, even without session data.
		runner:close()
		wait(function()
			return #vim.fn.readfile(log) == 5
		end)

		assert(require("dbc.connections").wait_for_cleanup())
	end, debug.traceback)
	vim.fn.delete(directory, "rf")

	if not ok then
		error(err)
	end
end

return M

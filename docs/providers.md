# Connection providers

Connection strategy and database dialect are independent configuration choices:

```text
query buffer / schema browser
              |
       execution runner                    dbc.execution
              |
       connection manager                  dbc.connections
              |
     provider session                      dbc.providers.<name>
     connect once -> resolve each request -> close once
              |
     effective endpoint + TLS + credentials + environment
              |
       database adapter                    dbc.adapters.<name>
       SQL / CLI arguments / result decoding
              |
       bounded async process runner        dbc.process
```

An adapter answers “how does this database client work?” A provider answers
“how do I reach this connection and authenticate a new client process?” Neither
the UI nor a MySQL/PostgreSQL adapter needs to know how AWS SSM or SSH operates.

## Available strategies

| Strategy | Implementation |
| --- | --- |
| Direct host/socket, client login profiles, existing external tunnel | Built-in `direct`, the default |
| Managed noninteractive helper for tunnels and dynamic credentials | Built-in `command`, using the protocol below |
| SSM forwarding through ECS/SSM plus RDS IAM authentication | Built-in [`aws_ssm_rds_iam`](aws-ssm-rds-iam.md) |
| SSH tunnel or another cloud proxy | A registered custom provider or a user-supplied `command` helper |

The native AWS provider manages SSM forwarding and RDS IAM authentication without
an external helper script. Custom helper scripts still need to implement the protocol
below; interactive scripts cannot serve as command helpers unchanged.

## Configuration

Existing connection profiles use `provider = "direct"` implicitly:

```lua
require("dbc").setup({
  connections = {
    {
      name = "local",
      adapter = "mysql",
      provider = "direct",
      login_path = "local-dev",
      database = "app",
    },
  },
})
```

Use a helper implementing `open`, `resolve`, and `close` for a managed strategy:

```lua
require("dbc").setup({
  connections = {
    {
      name = "rds-dev-read",
      adapter = "mysql",
      database = "app",
      provider = {
        name = "command",
        command = { "/absolute/path/to/your-rds-helper" },
        options = {
          aws_profile = "app-dev",
          region = "ap-northeast-1",
          local_port = 13360,
          db_user = "your_user_read",
          -- Other helper-owned options: cluster/service, RDS identifier,
          -- reader/writer selection, and CA file path.
        },
        -- env = { AWS_CONFIG_FILE = "/path/to/config" },
      },
    },
  },
})
```

Connection names must be unique. The workspace keys provider sessions by name;
query buffers retain their original profile and selected database. A connection's
session is shared by its metadata and query executions, including across database
selections. Separate profiles own separate sessions, even if options are similar.

## Registered provider interface

Register before `setup()`:

```lua
require("dbc.providers").register("my_strategy", {
  create = function(profile, context)
    -- Construct state only. Start resources in connect(), not in create().
    return {
      connect = function(done)
        -- Start transport asynchronously; call done(nil) only when ready.
        -- On failure call done("actionable error").
        -- Return an optional function that cancels this setup operation.
        done(nil)
      end,
      resolve = function(database, done)
        -- Resolve current endpoint and refresh credentials for this execution.
        done(nil, {
          connection = { host = "127.0.0.1", port = 13360 },
          credentials = {},
          env = {},
          -- release = function() ... end, -- optional per-request cleanup
        })
        -- Return an optional function that cancels credential preparation.
      end,
      close = function(done)
        -- Stop owned resources, including partially initialized resources.
        -- Finish with done(nil), or done("cleanup error").
        done(nil)
      end,
    }
  end,
})
```

Select it with `provider = "my_strategy"`, or
`provider = { name = "my_strategy", ... }` for provider-owned options.
An optional `validate(profile)` method runs during setup for static validation.

`context.limits` provides timeout/output bounds. `context.on_error(message)`
reports asynchronous provider failures. Do not mutate the context or perform
blocking work. These session methods are closure functions, **not colon methods**.
Callbacks use error-first arguments and must be called once; the manager schedules
connect/resolve callbacks onto Neovim's main loop even if a provider calls them
synchronously. Close callbacks should run on the main loop too.

### Session lifecycle

- Sessions are created lazily on the first metadata/query request. Opening the
  dashboard alone does not authenticate or establish tunnels.
- Concurrent requests share one `connect()` operation per profile. Cancelling one
  waiting caller does not cancel setup needed by another caller. If all setup
  waiters cancel, setup is cancelled and the partial session is closed.
- `resolve(database, done)` runs for **every** new CLI execution. The core does
  not cache credentials. A provider may refresh each time or cache until before
  expiry. Resolve operations may overlap, so shared refresh/cache updates must
  be coordinated by the provider. Verify transport health here if necessary.
- Resolve errors fail that execution; the ready session remains available for a
  later attempt. Failed connect retires the session, allowing the next request
  to create a new one. User SQL is never retried automatically.
- Query cancellation keeps a ready tunnel alive. Closing the workspace or exiting
  Neovim cancels pending work and calls each session's `close(done)` exactly once.
- Closing is asynchronous during normal use. On editor exit the execution layer
  waits within configured bounds for client/request cleanup and outstanding
  provider closes, including closes started by an earlier workspace shutdown.
- Ignore late setup completions after close. Dispose partially created resources
  even when cancelled. Provider cleanup must only stop resources it owns.

### Resolution model

`done(nil, resolution)` returns:

```lua
{
  connection = {
    host = "127.0.0.1",
    port = 13360,
    user = "iam_user",
    protocol = "TCP",                 -- MySQL
    ssl_ca = "/path/to/global-bundle.pem", -- MySQL
    ssl_mode = "VERIFY_CA",            -- MySQL
    enable_cleartext_plugin = true,     -- MySQL IAM authentication
  },
  credentials = { password = "short-lived token" },
  env = {},
  release = function()
    -- Optional: remove temporary credential files after this CLI exits.
  end,
}
```

All fields are optional; `{}` means use the configured profile and client-native
authentication unchanged. Connection fields overlay a copy of the profile for
this execution; they never mutate saved configuration or query bindings. A
provider cannot override `name`, `adapter`, `provider`, `executable`, or `password`.
The query binding's selected database is authoritative when present.

Credentials go separately to `adapter.request(profile, database, sql, credentials)`.
MySQL maps a dynamic password/token to the child environment's `MYSQL_PWD`;
PostgreSQL uses `PGPASSWORD`. Neither puts it in argv. These are request-scoped
environment values, not a credential vault; static credentials should continue
using native profile/passfile facilities. Provider `env` overrides adapter `env`,
and both preserve the parent environment. Do not return tokens in display names,
error messages, or persistent session metadata.

`release()` runs after process completion, including SQL/decoder errors, or when
request construction fails. A late resolution arriving after cancellation is
also released. Release must be synchronous and idempotent, and must not tear down
the shared tunnel. The provider must clean its own partially prepared resources
when resolution is cancelled before returning a resolution.

## Command helper protocol

`command` is an argv array; the provider appends exactly one action argument.
There is no shell interpolation. Each invocation receives JSON on stdin:

```json
{
  "id": "opaque session identifier generated before open",
  "options": { "aws_profile": "app-dev", "local_port": 13360 },
  "session": { "provider_owned": "resource descriptor from open" },
  "database": "app"
}
```

`session` is absent before a successful open; `database` is supplied to resolve.
The ID is stable across all three actions, including close after a failed or
cancelled open. A helper must be able to clean partially opened resources by ID.

| Invocation | Required behavior / stdout |
| --- | --- |
| `helper open` | Establish transport, wait until usable, emit `{"session": {...}}` (or `{}` when no descriptor is needed) |
| `helper resolve` | Refresh credentials/verify transport; emit the resolution model as JSON, without a Lua `release` function |
| `helper close` | Stop resources owned by this ID; emit `{}` or nothing; succeed if already closed |

All operations are noninteractive and exit after their work is complete. JSON is
the only stdout output; diagnostics go to stderr without tokens. Nonzero exits,
timeouts, invalid JSON, and bounded-output failures are reported through the
normal query/sidebar error path. Helpers receive the same configured execution
limits; the execution deadline covers preparation plus SQL. Close gets its own
bounded operation. SQL text is never passed to the helper.

Tunnel processes must be supervised/detached from the short-lived helper and
must not retain its captured stdin/stdout/stderr pipes. Keep ownership state keyed
by ID, coordinate overlapping resolve/close operations, and make close safe if
open was interrupted before returning JSON. A helper owns cancellation/rollback
of its own AWS/SSH subprocesses; killing a helper process alone is not a portable
process-tree cleanup mechanism. Temporary files required for a whole session
belong to helper close; for per-request file release, use a registered Lua provider.

## SSM / RDS IAM workflow

The built-in [AWS provider](aws-ssm-rds-iam.md) implements this lifecycle:

1. **Connect/open:** validate the AWS SSO session; resolve the reader/writer RDS
   endpoint and ECS bastion target; establish SSM forwarding; wait for readiness.
   Keep the real RDS endpoint, owned SSM resource identity, local port, and CA path
   as session state. Fail if the requested local port belongs to another owner.
2. **Resolve:** generate an IAM token using the **real RDS hostname and port
   3306**, not `127.0.0.1` and the forwarded port. Return the local address/port for
   the MySQL client, IAM DB user, CA/TLS options, and token as credentials. Generate
   a new token each time or refresh before the 15-minute validity window expires.
3. **Close:** stop only this session's forwarding processes and remove its state.
   Do not scan a port and terminate unrelated listeners.

Application/environment/permission selection uses explicit provider configuration.
AWS SSO login remains external; an expired session should return an actionable
error. The native provider owns discovery and forwarding, so you do not need to
run a separate tunnel script first.

Provider sessions can persist while database sessions remain per execution.
Keeping an SSM tunnel alive does not make SQL transactions or temporary tables
persist between runs. The same provider lifecycle can support a PostgreSQL
transport; PostgreSQL-specific libpq/TLS fields still belong to its adapter.

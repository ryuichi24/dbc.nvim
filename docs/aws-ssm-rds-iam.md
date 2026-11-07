# AWS SSM + RDS IAM provider

`aws_ssm_rds_iam` manages AWS SSM port forwarding and RDS IAM authentication
inside Neovim. No helper script or jq is required. It supports the MySQL and
PostgreSQL adapters on macOS/Linux.

## Prerequisites

- AWS CLI v2 and `session-manager-plugin` on Neovim's PATH, plus `mysql` or `psql`.
- An active AWS profile with permission to discover the database/bastion and
  start SSM sessions. The existing bastion must support remote-host forwarding
  and be able to reach RDS. The DB user must have RDS IAM authentication configured.
- A readable RDS CA bundle. Download `global-bundle.pem` from
  <https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem>.

Perform interactive SSO login in a terminal before using the connection:

```sh
aws sso login --profile app-dev
```

The plugin validates that identity; it does not launch an interactive SSO flow.

## MySQL configuration

This example uses fictional application resources. Replace the AWS profile,
resource names, database, username, region, port, and CA path with your own values.

```lua
require("dbc").setup({
  connections = {
    {
      name = "app-dev-read",
      adapter = "mysql",
      database = "app",
      provider = {
        name = "aws_ssm_rds_iam",
        aws_profile = "app-dev",
        region = "ap-northeast-1",
        rds_identifier = "app-dev-aurora-cluster",
        rds_type = "cluster",
        endpoint = "writer",
        ecs_cluster = "app-dev-cluster",
        ecs_service = "app-dev-bastion-service",
        container = "bastion",
        db_user = "your_user_read",
        local_port = 13360,
        ssl_ca = "/absolute/path/to/global-bundle.pem",
      },
    },
  },
  execution = { timeout_ms = 60000 },
})
```

Open `:Dbc` and expand the connection or execute SQL. The first request validates
AWS identity, resolves RDS and ECS details, starts forwarding, and waits for the
local port. Later requests reuse the tunnel and generate a new IAM token for each
CLI execution. Closing the dashboard or exiting Neovim stops the owned forwarding
process group, including its session-manager-plugin child.

`db_user` selects database privileges. `endpoint` selects routing; the two are
independent. For an environment without a separate reader, use `endpoint = "writer"`
even when authenticating as a read-only user. Selecting a reader endpoint never
silently falls back to the writer.

Do not run another tunnel on the same local port at the same time. An
occupied port is reported as an error; the plugin does not reuse it or terminate
its owner. IAM profiles should omit login-path/defaults-file password settings
that could override the dynamic token supplied to the MySQL child environment.

## Configuration reference

### Connection helper

Use `require("dbc").rds_connection(name, config)` to build a connection from a
flat configuration table:

```lua
local dbc = require("dbc")

dbc.setup({
  connections = {
    dbc.rds_connection("app-dev-read", {
      database = "app",
      aws_profile = "app-dev",
      region = "ap-northeast-1",
      rds_identifier = "app-dev-aurora-cluster",
      endpoint = "writer",
      ecs_cluster = "app-dev-cluster",
      ecs_service = "app-dev-bastion-service",
      db_user = "your_user_read",
      local_port = 13360,
      ssl_ca = "~/.config/dbc/global-bundle.pem",
    }),
  },
  execution = { timeout_ms = 60000 },
})
```

Replace the resource names, username, and CA path with your own values.
The helper returns a normal connection profile: `adapter` (default `"mysql"`)
and `database` become top-level fields; all other configuration fields are copied
into `provider`, whose name is always `"aws_ssm_rds_iam"`. It does not mutate the
input, validate credentials, or start AWS processes. Normal configuration
validation runs in `setup()`.

All provider options below are supported, including `rds_host`, an explicit
`target` instead of ECS discovery, and `adapter = "postgres"`. Provider defaults
remain unchanged: cluster, writer endpoint, and `bastion` container. Names,
profiles, regions, and database users are explicit; the helper does not infer
company-specific naming conventions. Give independently active connections
unique names and local ports.

### Provider fields

Fields below belong inside `provider`:

| Field | Meaning / default |
| --- | --- |
| `name` | `"aws_ssm_rds_iam"` |
| `aws_profile` | Required AWS CLI profile |
| `region` | Required AWS region |
| `db_user` | Required IAM-authenticated database username |
| `ssl_ca` | Required readable CA bundle path; `~` is expanded |
| `local_port` | Required loopback forwarding port |
| `remote_port` | RDS port; default 3306 for MySQL, 5432 for PostgreSQL |
| `rds_identifier` | Required cluster/instance identifier unless `rds_host` is set |
| `rds_type` | `"cluster"` (default) or `"instance"` |
| `endpoint` | `"writer"` (default) or `"reader"` for clusters |
| `ecs_cluster` | Required ECS cluster name unless `target` is set |
| `ecs_service` | Required ECS bastion service name unless `target` is set |
| `container` | Bastion container name; default `"bastion"` |
| `rds_host` | Optional real RDS hostname, bypassing endpoint discovery |
| `target` | Optional SSM target string, bypassing ECS discovery |
| `ready_timeout_ms` | Local forwarding readiness deadline; default 15000 ms |
| `aws_executable` | AWS CLI executable path; default `"aws"` |

Discovery takes the first task returned by `ecs list-tasks`, then finds the named
container's runtime ID in `ecs describe-tasks`. It constructs the same
`ecs:<cluster>_<task-id>_<runtime-id>` SSM target. Supplying an
explicit `target` also permits an existing EC2 SSM target such as `i-...`.

Use the actual RDS hostname for `rds_host`, not the local forwarding address.
IAM tokens are signed for that real hostname and the remote database port. The
MySQL connection uses `127.0.0.1`, the local port, `--protocol=TCP`,
`--ssl-mode=VERIFY_CA`, the CA bundle, and `--enable-cleartext-plugin`.
Tokens are passed as request-scoped `MYSQL_PWD`, never SQL text or argv.

The execution timeout covers discovery, readiness, token generation, and SQL.
The long-lived tunnel itself has no query timeout. Its diagnostic output is
byte-bounded; repeated output failures terminate it. Close sends TERM to the
owned Unix process group and escalates to KILL after a short grace period.
No processes are looked up or killed by local port.

## PostgreSQL

Use the same provider with `adapter = "postgres"` and the appropriate RDS,
database, username, and local-port configuration. The default remote port becomes
5432. The resolution keeps the real RDS hostname for TLS identity and sets
`PGHOSTADDR=127.0.0.1` for the actual TCP destination, `sslmode=verify-full`, and
`PGSSLROOTCERT` to the CA bundle. IAM credentials are passed through `PGPASSWORD`.
The PostgreSQL adapter's one-result-producing-statement limitation still applies.

## Failures and reconnection

Missing credentials, inaccessible resources, absent container runtime IDs, unreadable
CA files, and forwarding startup failures are shown in the query/sidebar error
path. On expired SSO credentials, run `aws sso login --profile ...` and retry.
SQL is never retried automatically. A failed initial connection can be attempted
again; if an established tunnel exits, close and reopen the dashboard to reconnect.

Cancelling a query leaves an established shared tunnel alive. Cancelling the last
caller waiting for initial setup retires that partial session and closes its
owned resources. Database sessions remain per CLI invocation, so transactions and
temporary tables still do not persist across executions.

## Verification

The default tests use a fake AWS CLI and a real local child listener, exercising
discovery, token signing arguments, refresh, failures, cancellation, process-group
cleanup, and Neovim exit. No AWS infrastructure is contacted by those tests.
Live AWS/RDS compatibility requires testing in your account with your IAM and
bastion configuration; it has not been verified here.

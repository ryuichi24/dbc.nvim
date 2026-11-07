# dbc.nvim guide

Detailed setup, workflow, and extension reference. See the [README](../README.md)
for a quick start.

A native-buffer database workspace for Neovim 0.10+. Browse schemas, edit SQL,
execute it asynchronously with the installed `mysql`, `psql`, or `sqlite3` CLI, and navigate/yank
results using ordinary Vim motions. No runtime plugin dependencies.

## Setup

Install this repository with your plugin manager, install the appropriate database
CLI, and configure client-native authentication.

Connections can be managed independently of your Neovim configuration in a local
JSON file. Run `:Dbc`, then press `a` on a connection row or sidebar header (or `:Dbc add_connection`)
to add a connection. An editable Vim buffer shows all fields together: adapter,
name, database, and optional client connection settings. Edit the `field: value`
lines using ordinary Vim motions and insert mode, then place the cursor on `Add`
and press Enter to save it locally and open a bound query tab.
Press `q` in normal mode to cancel. Validation or save errors keep the form open
with your edits intact. Blank optional fields are omitted.

To remove a saved connection, select its connection row in the sidebar and press
`d`. A confirmation popup opens with `Cancel` selected. Move to `Remove` and
press Enter to delete the JSON entry, or press Enter on `Cancel`, `q`, or Escape
to cancel. This removes only the saved connection profile, not the database;
existing query tabs retain their bindings. Connections supplied through
`setup().connections` must be removed from your Lua configuration instead.

Use `:Dbc edit_connections` to open the JSON file in a separate tab. Its default
location is `stdpath("data")/dbc/connections.json`. The file contains an array:

```json
[
  {
    "name": "local-sqlite",
    "adapter": "sqlite",
    "database": "/absolute/path/to/app.db"
  },
  {
    "name": "postgres-dev",
    "adapter": "postgres",
    "database": "app_development",
    "service": "local-dev"
  }
]
```

Save your edits, then return with `:Dbc` or run `:Dbc reload_connections` in the
dashboard to reload the file. You can add, edit, or remove entries manually;
the file accepts the same profile fields as Lua configuration, including provider
options. Invalid JSON or duplicate names produce an error without replacing the
currently loaded connections. Existing query tabs retain their bound settings;
create a new query using the reloaded connection to use changed settings.

The JSON file is shared across working directories by default. To use a different
file, such as a project-local connection file, configure:

```lua
require("dbc").setup({
  connections_file = vim.fn.getcwd() .. "/.dbc/connections.json",
})
```

The file is read when the dashboard opens or reloads. A missing file starts empty
and is created when adding a connection or using `:Dbc edit_connections`.
Dashboard additions preserve existing JSON entries. Names must be unique across
the file and any Lua-configured connections. Use client-native authentication
or providers rather than storing a `password` field. The connection form covers
direct SQLite/MySQL/PostgreSQL connections; edit the file for advanced options.

Lua-configured connections remain supported and appear alongside JSON entries:

```lua
require("dbc").setup({
  connections = {
    {
      name = "local-dev",
      adapter = "mysql",
      provider = "direct", -- default; use a provider for tunnels/dynamic auth
      login_path = "local-dev",
      database = "app_development",
      -- executable = "mysql",
      -- defaults_file = "/path/to/mysql.cnf",
      -- host = "127.0.0.1", port = 3306, user = "app", socket = "...",
    },
    {
      name = "sqlite-local",
      adapter = "sqlite",
      database = "/absolute/path/to/app.db",
      -- executable = "sqlite3",
    },
    {
      name = "postgres-dev",
      adapter = "postgres",
      database = "app_development",
      service = "local-dev", -- optional pg_service.conf entry
      -- executable = "psql",
      -- host = "127.0.0.1", port = 5432, user = "app",
      -- passfile = "/path/to/.pgpass", sslmode = "prefer",
    },
  },
  ui = {
    sidebar_width = 30,
    results_height = 14,
    -- Each pane supports independent Vim line-number options (default: false).
    panes = {
      sidebar = { number = true, relativenumber = true },
      query = { number = true, relativenumber = true },
      results = { number = true, relativenumber = true },
    },
  },
  execution = {
    timeout_ms = 30000,
    max_output_bytes = 5 * 1024 * 1024,
    max_rows = 1000,
  },
  mappings = { run = "<localleader>r", cancel = "<localleader>c" },
})
```

`adapter` defaults to `mysql` for backward compatibility. MySQL client profiles
supply authentication (for example with `mysql_config_editor`); explicit
host/port/user/socket/database options override corresponding profile defaults.
`defaults_file` is passed as
`--defaults-extra-file` first, before `--login-path`. Do not configure passwords
in Lua or argv. Authentication must be noninteractive; the plugin does not
provide a password prompt. Client failures appear in results or the sidebar.

PostgreSQL uses `psql` 12+ (CSV output), `.pgpass`/`passfile`, and optionally
`pg_service.conf` via `service`. Explicit host/port/user/database options override
service defaults. `--no-password` prevents hidden password prompts;
`--no-psqlrc` avoids startup configuration changing the result format.

SQLite uses `sqlite3` 3.33+ with `adapter = "sqlite"` and a required `database`
file path (prefer an absolute path). No authentication settings are needed.
The sidebar shows the configured file, its tables/views, and their columns.
CREATE TABLE, INSERT, UPDATE, and SELECT preview actions are supported; CREATE
DATABASE is not applicable. SQLite creates a missing database file when opened.

## Workflow

1. `:Dbc` opens/focuses a dedicated tabpage with a schema sidebar, SQL editor,
   and read-only results buffer. The first configured connection is selected.
2. In the sidebar, `Enter` expands connections, databases, tables/views, and
   columns. PostgreSQL adds schemas between databases and tables, including
   materialized views and foreign tables. Pressing Enter on a database binds the
   current query to it and marks it `[query]`. Press `n` on a database to open a
   new bound query. Selecting a schema selects its database; it does
   not alter `search_path`. PostgreSQL previews use schema-qualified names.
3. On a table or view, `r` opens a new read query tab with `SELECT * ... LIMIT 100`
   (`p` is also supported).
   Review it and execute explicitly; previews do not run automatically.
    Press `a` on a database/schema to create a table, or on a table to insert a record.
    Press `ga` on a connection/profile for a `CREATE DATABASE` template,
   or on a database to open a new query tab with a `CREATE TABLE` template,
   or on a table to create an `INSERT` template. PostgreSQL schema nodes also
   support `ga` and prefill the schema name. Press `u` on a table to open an
   `UPDATE` template with column assignments and a `WHERE <condition>` placeholder.
4. In the query buffer, `:Dbc run` or `<localleader>r` runs the entire buffer.
   The pane header shows the query's bound connection and database, independently
   of the current sidebar selection; `(default)` means the client's default database.
   `:2,5Dbc run` or a visual selection followed by the run mapping executes
   whole selected lines, including for characterwise/blockwise selections.
5. Navigate with `<C-w>`, search and yank normally. Results render escaped
   control characters, `NULL`, and `""` for empty strings. `yc` yanks the raw
   cell under the cursor; `yr` yanks an escaped TSV row to the unnamed register.

| Command | Action |
| --- | --- |
| `:Dbc` / `:Dbc open` | Open or focus workspace |
| `:Dbc connect` | Choose connection and create a bound query |
| `:Dbc add_connection` | Open an editable connection form; Enter on `Add` saves to JSON (`a` in sidebar) |
| `:Dbc edit_connections` | Open the local connections JSON file for editing |
| `:Dbc reload_connections` | Reload JSON connections into the dashboard |
| `:Dbc query` | New SQL buffer using selected connection/database |
| `:Dbc next_query` / `:Dbc previous_query` | Switch query tabs (`gt` / `gT` in editor) |
| `[index]gt` (in query editor) | Jump to a query tab by its 1-based position (for example, `3gt`) |
| `:Dbc pick_query` | Search and select an open query tab |
| `:Dbc close_query` | Close current query tab, preserving its SQL buffer |
| `:Dbc actions` | Pick a query-generation action for the selected sidebar item (`A`) |
| `:[range]Dbc run` | Run buffer or supplied line range |
| `:Dbc cancel` | Stop active query (`<localleader>c` in editor) |
| `:Dbc refresh` | Reload selected sidebar subtree (`R` in sidebar) |
| `:Dbc close` | Close dashboard without force-deleting queries |

Sidebar `c` selects a connection; `q` closes the dashboard. Result `q` closes
its window. Successful CREATE/ALTER/DROP/RENAME queries automatically refresh
expanded table lists for the bound database; use `R` for a manual refresh.
The query header displays numbered tabs with the active tab highlighted. Use
`<localleader>t` to create a tab using the current tab's database and
`<localleader>x` to close a tab (at least one stays open). Each tab keeps its SQL,
database binding, cursor position, and results. Executions finish in their
originating tab even when you switch tabs while a query runs.
Query buffers remain listed and may be saved with `:write path.sql`.
Results are formatted as Markdown tables in a `markdown` buffer, allowing
Markdown-rendering plugins to style them. Row/cell copying preserves original values.

Closing the tab respects Neovim's modified-buffer rules. Enter on a database
rebinds the displayed query without changing its SQL; other queries keep their
bindings. SQL is sent on stdin, never
through shell interpolation. One user query and one metadata job run at a time.

### Query tab keymaps

Query buffers have unique names such as `dbc://query/42.sql` and retain the
`sql` filetype. The number identifies the buffer, not its tab position. To scope
a keymap to dbc query buffers, register this autocmd before opening dbc:

```lua
vim.api.nvim_create_autocmd({ "BufEnter", "BufFilePost" }, {
  pattern = "dbc://query/*",
  callback = function(event)
    vim.keymap.set("n", "<leader>fq", function()
      require("dbc.workspace").pick_query()
    end, {
      buffer = event.buf,
      desc = "Search query tabs",
    })
  end,
})
```

Use `:Dbc pick_query` to open a searchable floating picker. Press `i` to filter
by SQL text, connection, database, or tab number. Search is case-insensitive and
matches every space-separated word. Use `j`/`k` in normal mode or Ctrl-N/Ctrl-P
and arrow keys in either mode to select a tab, then Enter to open it with its
results. Escape leaves insert mode; `q` in normal mode closes the picker.

```lua
vim.keymap.set("n", "<leader>fq", function()
  require("dbc.workspace").pick_query()
end, { desc = "Search query tabs" })
```

In the query editor, use `[index]gt` (for example, `3gt`) to jump directly to
a query tab. Plain `gt` and `gT` move to the next and previous tabs.

For custom keymaps, `require("dbc.workspace").goto_query(index)` selects a tab
by its 1-based position among open query tabs and restores its results. The
workspace must be open, and an index without a corresponding tab raises an error.

Map a single tab:

```lua
vim.keymap.set("n", "<leader>3", function()
  require("dbc.workspace").goto_query(3)
end, { desc = "Go to query tab 3" })
```

Or map tabs 1–9:

```lua
for i = 1, 9 do
  local index = i
  vim.keymap.set("n", "<leader>" .. index, function()
    require("dbc.workspace").goto_query(index)
  end, { desc = "Go to query tab " .. index })
end
```

### Query templates

Sidebar `ga` creates editable SQL in a new query tab, bound to the item under the
cursor. It preserves your existing query tabs and focuses the first `<...>`
placeholder. On a connection/profile, it creates:

```sql
CREATE DATABASE `<database_name>`;
```

On a MySQL database:

```sql
CREATE TABLE `app`.`<table_name>` (
    `<column_name>` <data_type>
);
```

On a table, the template uses its quoted name and column names:

```sql
INSERT INTO `app`.`users` (
    `id`,
    `name`
) VALUES (
    <value_1>,
    <value_2>
);
```

Columns are loaded lazily and reused when already cached. If column discovery
fails or another metadata request is busy, the template uses `<column_name>`
and `<value_1>` instead. Adjust the column list and fill in values before running
with `:Dbc run`; creating a template never executes the generated SQL.
PostgreSQL database templates include `<schema_name>`; schema-node templates
prefill it, and INSERT templates qualify the table with its schema.

### Add your own query actions

Generators are registered modules. Sidebar `ga` uses the contextual default;
`A` opens a picker containing all applicable actions, including your extensions.
`r` (or `p`) invokes the registered SELECT preview action.

```lua
require("dbc.actions").register({
  id = "my_plugin.count_rows",
  label = "Count rows",
  node_kinds = { "table" },
  adapter_methods = { "qualify" },
  generate = function(ctx)
    return "SELECT COUNT(*) FROM " .. ctx.qualify() .. ";"
  end,
})
```

An external plugin can register a module with
`require("dbc.actions").register(require("my_plugin.actions.count_rows"))`.
Actions declare metadata needs (`requires = { "columns" }`), optional dialect
filters/capabilities, and default priority. The core handles metadata, binding,
placeholder focus, cancellation, and opening the query tab. Registration works
before or after setup; no sidebar/adapter edits are needed for a new action.
See [query actions](../docs/actions.md) for the full API, custom metadata resolvers,
and examples. `require("dbc").action(id)` runs a specific registered action.

## Connection providers

Choose `adapter` for the database dialect and `provider` for the connection
strategy. Existing profiles default to `direct`, using configured endpoints and
client-native authentication. The built-in `aws_ssm_rds_iam` provider discovers
RDS/ECS endpoints, opens an SSM tunnel, and generates IAM tokens for new client
processes. Run `aws sso login --profile app-dev` in a terminal first:

```lua
{
  name = "app-dev-read",
  adapter = "mysql",
  database = "app",
  provider = {
    name = "aws_ssm_rds_iam",
    aws_profile = "app-dev",
    region = "ap-northeast-1",
    rds_identifier = "app-dev-aurora-cluster",
    ecs_cluster = "app-dev-cluster",
    ecs_service = "app-dev-bastion-service",
    db_user = "your_user_read",
    local_port = 13360,
    ssl_ca = "/absolute/path/to/global-bundle.pem",
  },
}
```

See [AWS SSM/RDS IAM setup](../docs/aws-ssm-rds-iam.md) for prerequisites, all options,
PostgreSQL support, and the full configuration. You do not need to run the old
connection script. AWS CLI, session-manager-plugin, and a readable CA bundle are
required; configure a longer execution timeout if discovery takes time.

The generic `command` provider remains available for other user-supplied helpers
implementing the JSON `open`/`resolve`/`close` protocol.
Custom providers can register before setup with `require("dbc.providers").register`.
See [connection providers](../docs/providers.md) for the lifecycle, helper protocol,
and the SSM/RDS IAM integration design. IAM tokens are resolved for new client
processes; a retained tunnel does not retain a SQL session. MySQL profiles also
support `ssl_ca`, `ssl_mode`, `protocol`, and `enable_cleartext_plugin`.

## Session and output limitations

SQLite uses CSV output and supports **one result-producing statement per run**.
DDL/DML can precede that statement in the same run. NULL uses a fresh per-run
marker; an exact marker collision would decode as NULL. Empty SELECT results
may not include column headers. Select `hex(column)` for binary data. SQLite
dot commands and output-format overrides are unsupported. Startup `.sqliterc`
files are skipped and SQL errors stop execution. ATTACH, temporary tables, and
transactions do not persist across runs; `:memory:` starts empty on every run
and therefore is unsuitable for a browsable persistent workspace.

**Every execution creates a new client session.** Transactions, `USE`, session
variables, and temporary tables do not persist across runs. Related SQL must be
submitted together where the adapter supports them; `BEGIN` and `COMMIT` in
different runs are unrelated.
Cancellation/timeout stops the local client and cannot guarantee server-side
rollback or immediate server-side cancellation.

The MySQL adapter uses `--xml --batch` and decodes result sets, positional column
names (including duplicates), entities, and NULL attributes. Multiple XML result
sets are shown sequentially. Empty results may not provide column names. Affected
row counts are not synthesized. Non-XML/client-directive output is rejected.
Binary values not representable in XML are unsupported; select `HEX(column)`
explicitly. Statement-under-cursor parsing and persistent sessions are deferred.

The PostgreSQL adapter parses `psql` CSV output with quoted commas, quotes,
multiline values, duplicate headers, and empty results. A fresh per-execution
NULL marker distinguishes SQL NULL from empty strings and literal `NULL`/`\N`.
As psql serializes NULL as text, a value exactly matching that execution's marker
would also decode as NULL. **Execute only one result-producing statement per
PostgreSQL run.** CSV does not frame multiple result sets: consecutive SELECTs
with equal widths cannot be distinguished and may appear as one table. Use a
line range or separate query buffer for each SELECT. Non-result SQL executes
quietly without affected-row counts. SQL errors stop execution. Client meta
commands, COPY streams, and output-format overrides are not supported.

Captured stdout/stderr is byte-bounded; exceeding the bound stops execution and
discards incomplete data. Row limits cap rendering after bounded capture, rather
than rewriting SQL. Results are padded, horizontally scrollable, and values are
not clipped. The latest execution replaces prior results. Metadata refresh
replaces the selected subtree; deeper expansions within it must be reopened.

## Verification and compatibility

Run `make format`, `make lint`, and `make test` (or `make check` for lint/tests).
Headless tests use deterministic fake MySQL and PostgreSQL executables; no server
is required. Live MySQL/MariaDB/PostgreSQL versions have not yet been
integration-certified.

Before using against a real server, smoke-test a disposable database:

- Expand databases/tables/views/columns and preview an identifier containing a backtick.
- Run `SELECT 1 AS a, NULL AS b, '' AS c, CONCAT('a', CHAR(9), 'b') AS d;`.
- Test empty results, duplicate column names, Unicode, XML entities, and multiple SELECTs.
- Run invalid SQL, check permission/authentication errors, and cancel `SELECT SLEEP(10);`.
- Verify writes and multiple statements only against disposable data; confirm
  that transaction/session state does not persist between runs.
- Resize/close splits, reopen the dashboard, and save a modified query buffer.

For PostgreSQL, repeat with a disposable database and `adapter = "postgres"`:
expand schemas, preview quoted/schema-qualified relations, and run a single
SELECT containing NULL, empty strings, literal `NULL`/`\N`, commas, quotes,
newlines, and Unicode. Test empty results, invalid SQL, authentication failure,
and cancellation of `SELECT pg_sleep(10);`. Verify DDL/DML only on disposable data.

## Adapter architecture

The workspace is database-independent. Built-in adapters live in
`lua/dbc/adapters/`; the registry resolves each query's bound profile rather than
the currently selected sidebar connection. Adapters own process requests,
decoding, metadata queries/node conversion, and preview SQL. The process layer
owns asynchronous IO, environment overrides, cancellation, and limits.

Custom adapters can be registered before `setup()` with
`require("dbc.adapters").register("name", adapter)`, then selected with
`adapter = "name"`. See [the adapter contract](../docs/adapters.md) for the request,
result-set, and schema-node interfaces.

See `:help dbc` for a compact command reference after generating helptags.
## Query persistence

Query tabs are saved automatically per working directory and restored when you
reopen the dashboard, including after restarting Neovim. Saved tabs retain SQL
text, tab order, the active tab, and connection/database bindings. Connections
are matched by their configured names; credentials are not stored with tabs.
The last completed results are also saved, including row/cell copying support.
Each result displays its fetch timestamp and a reminder to rerun the query for
the latest data. Restoring tabs does not execute queries automatically.

Use `<localleader>x` to close a query tab or delete its buffer with `:bdelete` to
remove it from saved tabs. Closing the sole remaining tab keeps it open;
deleting its buffer creates a fresh blank tab.
Closing the dashboard preserves open tabs. Storage is under
`stdpath("data")/dbc/`.
## Updating a result row

In the results pane, visually select one data row with `V`, then press `u`
(or use `:'<,'>Dbc update`). Normal-mode `u` updates the row under the cursor.
This opens a new query tab with current values in `SET` and the complete primary
key in `WHERE`; edit the SQL and run it when ready. No update runs automatically.

Row updates currently support `SELECT * FROM table` with an optional `LIMIT`.
PostgreSQL requires a schema-qualified table. The table must have a primary key;
generated columns are omitted. Joins, expressions, and multiple statements are
not supported. Values come from the fetched result snapshot.

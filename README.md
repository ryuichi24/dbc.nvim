# dbc.nvim

A native-buffer database workspace for Neovim. Browse schemas, edit SQL,
execute it asynchronously with the installed `mysql`, `psql`, or `sqlite3` CLI,
and navigate/yank results using ordinary Vim motions. No runtime plugin dependencies.

## Setup

Install this repository with your plugin manager and the appropriate database
CLI: MySQL, PostgreSQL (`psql` 12+), or SQLite (`sqlite3` 3.33+).
Configure client-native, noninteractive authentication for MySQL/PostgreSQL.

Run `:Dbc`, then `:Dbc add_connection` (or press `a` on the sidebar header).
Edit the connection form, move to `Add`, and press Enter to save and open a query.
Connections are stored in `stdpath("data")/dbc/connections.json`;
`:Dbc edit_connections` opens the file for editing.

You can also configure connections in Lua:

```lua
require("dbc").setup({
  connections = {
    {
      name = "local-sqlite",
      adapter = "sqlite",
      database = "/absolute/path/to/app.db",
    },
  },
})
```

See the [setup reference](doc/guide.md#setup) for MySQL/PostgreSQL examples,
authentication, connection files, UI options, and execution limits.

## Everyday workflow

1. Open the workspace with `:Dbc`: schema sidebar, SQL editor, and results pane.
2. Press Enter in the sidebar to expand connections and tables. Enter on a
   database binds the current query; `n` opens a new bound query.
3. Press `r` on a table/view to generate a SELECT preview, or write your own SQL.
   Generated SQL is editable and never runs automatically.
4. Run the buffer with `<localleader>r` or `:Dbc run`. Select lines visually to
   run only that range.
5. Navigate panes with `<C-w>`. In results, `yc` copies a raw cell and `yr`
   copies a TSV row. Press `u` on a row to generate an editable UPDATE query
   for [supported queries](doc/guide.md#updating-a-result-row).

| Command / key                       | Action                               |
| ----------------------------------- | ------------------------------------ |
| `:Dbc connect`                      | Choose a connection and open a query |
| `<localleader>t` / `<localleader>x` | Create / close a query tab           |
| `gt` / `gT` / `3gt`                 | Next / previous / numbered query tab |
| `:Dbc pick_query`                   | Search open query tabs               |
| `<localleader>c` / `:Dbc cancel`    | Stop the active query                |
| `R` in sidebar                      | Refresh the selected subtree         |
| `:Dbc close`                        | Close the workspace                  |

Query tabs and their last results are saved per working directory and restored
when you reopen the workspace. Restoring tabs does not execute SQL; rerun queries
for current data. Query buffers can also be saved with `:write path.sql`.

**Each run starts a new client session.** Transactions, temporary tables, and
session settings do not persist between runs. PostgreSQL and SQLite support one
result-producing statement per run. Cancellation stops the local client and
does not guarantee server-side rollback. See [session and output limitations](doc/guide.md#session-and-output-limitations).

## Documentation

- [Full guide](doc/guide.md): connection management, commands, query tabs,
  templates, persistence, and result-row updates.
- [Connection providers](docs/providers.md) and [AWS SSM/RDS IAM setup](docs/aws-ssm-rds-iam.md).
- [Custom query actions](docs/actions.md) and [adapter API](docs/adapters.md).
- `:help dbc` for the compact command reference after generating helptags.

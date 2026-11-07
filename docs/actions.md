# Extending query generation with actions

Query generators are independent, registered action modules. Built-ins and external
plugins use the same API; adding a generator does not require editing the sidebar,
database adapter dispatch, or connection providers.

```text
Sidebar ga / A / r / p or require("dbc").action(id)
  → applicable action from registry
  → declared metadata loaders
  → action.generate(ctx)
  → validated SQL + optional cursor
  → new bound query tab (never auto-executed)
```

## Controls and built-ins

- `ga`: run the highest-priority applicable action marked `default = true`.
  If no default applies, open the action picker.
- `A` or `:Dbc actions`: choose from applicable built-in and registered actions.
- `r` (or `p`): open a read query using the `preview` action directly.
- `R` on a table/view: open the same read query and execute it immediately.
- `require("dbc").action("my_plugin.update")`: run a named action on the selected
  sidebar node, for example from a custom mapping.

| ID | Context | Default | Metadata |
| --- | --- | --- | --- |
| `create_database` | Connection/profile | Yes | None |
| `create_table` | Database/schema | Yes | None |
| `insert` | Table/view | Yes | Columns, optional with generic fallback |
| `update` | Table/view | No (`u`) | Columns, optional with generic fallback |
| `preview` | Table/view | No (`r` / `p`) | None |

Built-ins live separately under `lua/dbc/actions/`. MySQL/PostgreSQL adapters own
identifier quoting, relation qualification, and supported-operation capabilities.
The UI owns selection, metadata IO, binding, buffer creation, and placeholder focus.

## Add one module

Create `lua/my_dbc_actions/update.lua` in your config or an external plugin:

```lua
return {
  id = "my_plugin.update",
  label = "UPDATE row",
  node_kinds = { "table" },
  adapter_methods = { "quote", "qualify" },
  requires = { "columns" },

  generate = function(ctx)
    local column = ctx.metadata.columns[1]
    return {
      sql = "UPDATE " .. ctx.qualify()
        .. "\nSET " .. ctx.quote(column and column.name or "<column_name>")
        .. " = <value>\nWHERE <condition>;",
    }
  end,
}
```

Register it once, before or after `dbc.setup()`:

```lua
require("dbc.actions").register(require("my_dbc_actions.update"))
```

It immediately appears under `A` on a table. A small plugin can perform that
registration from its own `plugin/*.lua` entry point. No core file changes are
needed. Generate only SQL; execution remains an explicit user action.

## Action contract

| Field | Meaning |
| --- | --- |
| `id` | Required unique stable name; namespace third-party IDs |
| `label` | Required picker label |
| `node_kinds` | Required nonempty list of supported node kinds |
| `generate(ctx)` | Required function returning SQL text, `{ sql, cursor? }`, or nil to do nothing |
| `adapter_methods` | Optional required adapter function names, such as `quote` and `qualify` |
| `capabilities` | Optional required `adapter.capabilities` flags; each must be explicitly true |
| `adapters` | Optional allowlist of adapter names; omit for dialect-independent actions |
| `available(ctx)` | Optional synchronous predicate for further filtering, before metadata loading |
| `requires` | Optional list of metadata names, or a function returning that list |
| `allow_missing_metadata` | Default false: metadata errors prevent generation. True allows generator fallback |
| `default` | Default false: whether `ga` may select this action directly |
| `priority` | Finite number, default 0; larger values sort/select first |

Equal priorities are ordered by action ID, so picker/default behavior is stable.
Filtering uses node kinds, adapter allowlists, methods, semantic capabilities, and
the availability predicate. A new node kind can be used without changing the UI.
Availability predicates should inspect context only, without IO or mutation.

Actions are copied when registered/read. Duplicate IDs fail unless replacement is
explicit:

```lua
local actions = require("dbc.actions")
local action = actions.get("insert")
action.label = "My INSERT template"
actions.register(action, { replace = true })

actions.unregister("my_plugin.update")
```

To make an additional action the default without replacing the built-in, set
`default = true` and a higher priority, such as `priority = 100`.
Unregistering it restores selection of the remaining defaults. Built-ins load
once and are not silently re-added after unregistering.

### Generation context

`ctx` contains:

- `node`: the selected sidebar node, including database/schema/name and cached children.
- `profile`, `database`: the original profile and database binding for the new tab.
- `adapter`, `adapter_name`: database adapter and configured name (`mysql` by default).
- `quote(identifier)`: adapter identifier quoting helper, if provided.
- `qualify(name?)`: adapter-qualified relation; omitted name uses the node's name.
- `metadata`: resolved data keyed by requirement name.
- `metadata_errors`: errors keyed by requirement name when fallback is allowed.
- `fetch_children(done)`: callback-based cached/lazy discovery for the selected node.
- `timeout_ms`: configured preparation deadline.

Treat context, profile, node, and adapter as read-only. Configured profiles do not
contain resolved IAM tokens/passwords. Generators should be pure, synchronous SQL
builders. Put asynchronous work in a metadata loader, not in `generate()`.
The selected node/binding is captured before a picker opens; moving the sidebar
cursor does not retarget the eventual query.

SQL must be nonempty. An explicit `cursor = { row, byte_column }` uses a one-based
row and zero-based byte column; it is validated before creating the tab. Without
it, the UI focuses the first `<name>` placeholder, or leaves the normal initial
cursor if no placeholder is present. This is plain editable text, not a snippet
engine. Generator/predicate errors are reported without creating a query tab.

## Metadata loaders

The built-in `columns` loader uses child discovery and returns ordered column-node
descriptors (`name`, `kind`, `detail`, etc.). It reuses cached metadata and joins a
load already in progress for the same node. An unrelated busy metadata request
is reported as an error. INSERT explicitly allows that error and uses generic
column/value placeholders; strict custom actions do not generate without their
required metadata.

Register another resolver without changing the UI:

```lua
require("dbc.actions").register_metadata("my_plugin.extra", function(ctx, done)
  -- Perform asynchronous work and call done(nil, value) or done(error).
  -- Earlier requirements are available through ctx.metadata.
  done(nil, { description = ctx.node.name })
  -- Return an optional cancellation function for in-flight work.
end)
```

Then declare `requires = { "columns", "my_plugin.extra" }`. Requirements are
loaded sequentially in declaration order and callbacks are scheduled on Neovim's
main loop. Dynamic requirements can return different lists for different nodes.
Unknown requirements fail clearly rather than silently supplying empty data.

Resolvers must call back once and return an optional, idempotent cancellation
function. They must not block the UI. Preparation uses the configured execution
deadline; timeout cancels the active resolver and prevents generation. Workspace
close also cancels action preparation. Late resolver/picker callbacks cannot open
tabs after closure. Cached shared sidebar discovery is owned by the workspace,
so cancelling an action does not cancel another caller's discovery request.

Use `register_metadata(name, loader, { replace = true })` for explicit replacement
or `unregister_metadata(name)` to remove a resolver. Resolvers that manage their
own external requests/resources are responsible for their cancellation cleanup.

## Adapter integration and migration

New adapters can opt into standard actions by exposing `quote`,
`qualify(node, name?)`, and semantic capability flags:

```lua
capabilities = {
  create_database = true,
  create_table = true,
  insert = true,
}
```

Missing/false flags hide the corresponding standard action. Quoting support alone
does not imply that a database supports `CREATE DATABASE`. Database-specific
generators can register their own actions with an `adapters` allowlist instead.

Older third-party `adapter.template(node)` implementations still appear through
the `legacy_template` compatibility action. It defaults above generic built-ins
(priority 10) so existing custom templates retain precedence, and loads columns
only for table nodes. New code should use registered actions; the built-in
MySQL/PostgreSQL adapters no longer contain a template-dispatch function.

See [the adapter contract](adapters.md) and [connection providers](providers.md)
for the separate database and connection interfaces.
# Result-row updates

Select a single result data row with `V` and press `u`, or run `:Dbc update`
on that row. A new query tab opens with its current values, excluding primary
keys and generated columns from `SET`. All primary-key columns identify the row
in `WHERE`. The statement is not executed automatically.

Supported source queries are `SELECT * FROM table` with an optional `LIMIT`.
PostgreSQL table names must be schema-qualified. Joins, expressions, multiple
statements, and tables without primary keys are rejected.

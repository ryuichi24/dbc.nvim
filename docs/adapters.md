# Database adapter contract

The UI and process runner do not contain database-specific SQL, client flags, or
output parsers. `dbc.adapters` resolves a profile's `adapter` (`mysql` by default)
and lazily loads built-ins. `register(name, adapter)` validates required methods
and allows third-party adapters or explicit overrides before `setup()`.

## Responsibilities and execution flow

1. The workspace takes the query buffer's immutable connection/database binding.
2. The connection provider establishes transport once and resolves endpoint,
   TLS settings, and credentials for this execution. The execution runner overlays
   those settings onto a copy of the bound profile.
3. `adapter.request(profile, database, sql, credentials)` constructs a process
   request. The optional credentials argument is request-scoped.
4. The shared process layer starts argv directly, writes stdin, captures bounded
   stdout/stderr, handles timeout/cancellation, and schedules completion on the
   Neovim thread. Environment overrides are merged with the inherited environment.
5. For a successful process, the execution runner calls that request's decoder and
   renders its normalized result sets. Decoder errors are displayed separately
   from process/SQL errors. Failed output is never decoded as successful results.
6. Discovery uses the same execution path, then `children()` converts result sets
   into sidebar nodes. Errors remain local to the selected node.

Keeping the decoder on the request allows per-execution parsing context (such as
PostgreSQL's fresh NULL marker) without mutable adapter-global state leaking
between concurrent metadata/query jobs or connections.

## Required methods

### `request(profile, database, sql, credentials) -> request`

Return:

```lua
{
  argv = { "client", "--flag", "--database=" .. database },
  stdin = sql,
  env = { CLIENT_SETTING = "value" }, -- optional overrides; preserve inheritance
  decode = function(stdout)
    return {
      { columns = { "id", "name" }, rows = { { "1", "Alice" } } },
    }
  end,
}
```

Do not use shell command strings. The adapter controls encoding, client authentication options,
startup-file suppression, output format, and noninteractive client options.
Passwords must not be placed in argv. Use client-native credential sources.
Dynamic provider credentials are passed separately, for example
`{ password = "short-lived token" }`. MySQL maps this to `MYSQL_PWD` and PostgreSQL
to `PGPASSWORD` in request `env`. Provider environment overrides adapter environment.
Existing custom adapters may ignore the extra argument if they rely solely on
native client authentication. Transport provisioning and credential refresh belong
to the [provider layer](providers.md), not the database adapter.
The selected database argument is authoritative; profile defaults may apply when
it is nil. CLI flags/values should remain distinct argv entries as appropriate.

`decode(stdout)` returns an ordered list of result sets, or `{}` when no result
sets are supplied. Each set has string `columns` and positional `rows` containing
strings or `vim.NIL` for SQL NULL. Duplicate column names are valid; empty strings
must stay empty strings. Empty sets retain columns when the client provides them.
Decoders must raise an error for malformed/incomplete output. Do not synthesize
affected-row counts or infer success from a partial result after a process error.

The request is created for each execution, and must not retain query text or
credentials in global state. All current adapters use a fresh process/session.

### `metadata(node) -> sql | nil`

Return the discovery SQL for this node's children, or nil for a leaf. Quote SQL
identifiers and literal values using the database's own rules. The runner uses
`node.profile` and `node.database`. There is no fixed hierarchy in the UI:

- MySQL: connection → database → table/view → column.
- PostgreSQL: connection → database → schema → table/view → column.

The current renderer uses `kind = "table"` with `detail = "view"` for views, and
`kind = "column"` for leaves. `database` and `schema` kinds select the database
for future query buffers. Other expandable kinds may be added by custom adapters.

### `children(node, result_sets) -> nodes`

Return an ordered list of descriptors:

```lua
{
  {
    name = "users",       -- display name / identifier
    kind = "table",
    database = "app",     -- explicit target for child discovery / preview
    schema = "public",    -- adapter-owned context, if applicable
    detail = "view",      -- optional display annotation
  },
}
```

The workspace attaches the parent's profile to each descriptor. Adapters must
propagate database/schema context and may add other fields needed for discovery
or preview generation. Keep display text separate from underlying identifiers.
Loading, expansion, errors, generations, and child caching belong to the UI.

### `preview(node) -> sql | nil`

Return a bounded, correctly quoted query for a supported relation, or nil.
The workspace inserts this into a new buffer bound to node.profile/database;
execution remains explicit. PostgreSQL previews qualify schema and relation
independently. Never add a limit to arbitrary user SQL.

## Adding an adapter

### Query-action dialect helpers

Query generators live in the independent [action registry](actions.md), not in
adapter dispatch functions. An adapter can enable standard actions with:

- `quote(identifier)`: database-specific identifier escaping/quoting.
- `qualify(node, name?)`: qualified relation name; use `node.name` when omitted.
- `capabilities`: boolean flags opting into supported standard SQL operations,
  currently `create_database`, `create_table`, and `insert`.

MySQL qualification uses the node's database. PostgreSQL uses its schema, or a
`<schema_name>` placeholder when creating a table from a database node. New
adapters opt into appropriate capabilities; a quote function alone does not
imply support for CREATE DATABASE. Database-specific actions can also register
independently with dialect filters.

The `preview` method is invoked through the registered `preview` action. Legacy
third-party `template(node)` methods remain supported by a compatibility action,
but new generators should be standalone action modules. Built-in MySQL and
PostgreSQL adapters no longer contain template dispatch. The shared
`dbc.templates` module remains an internal SQL formatting helper for actions.

### Registering an implementation

Implement these four functions, register the adapter before setup, and configure
a connection with its name. Built-ins are mapped in `lua/dbc/adapters/init.lua`.
Helpers such as MySQL `argv`/`decode` are implementation details. The optional
`quote`/`qualify` helpers and capabilities above are part of the action interface.

Test argument boundaries, quoted identifiers/literals, malformed and empty
output, NULL versus empty values, multiline/Unicode values, metadata context,
and query-buffer routing with multiple connection types. Use fake CLI integration
tests for the runner/UI and live smoke tests for claimed client compatibility.
Document output limitations honestly: MySQL uses XML, while PostgreSQL currently
uses CSV and supports one result-producing statement per execution, not framed
multi-result scripts. PostgreSQL NULL uses a fresh marker rather than reserving
a fixed application value; an exact marker collision remains theoretically possible.

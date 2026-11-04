# dbc.nvim

## Start a new plugin

After creating a repository from this template, run this command from its root
(requires Neovim):

```sh
make rename NAME=my-tool
```

Replace `my-tool` with your project name. Names must start with a letter and may
contain letters, digits, underscores, and hyphens. The script normalizes names to
lowercase underscores for Lua and PascalCase for the Neovim command:

- `lua/my_tool/init.lua`, loaded with `require("my_tool")`
- `plugin/my_tool.lua`, providing `:MyTool`
- Updated module references, load guard, greetings, and example tests
- README title set to the project name as provided (for example, `# my-tool`)

Run the initializer once, before customizing the template. It refuses existing
destination paths. Then run `make check` to verify your renamed plugin.

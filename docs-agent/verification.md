# Verification

- Run `make format` and `make lint` after modifying code or configuration.
- Run `make test` for the dependency-free headless Neovim example tests.
- Use `make check` for the current verification suite (Lua formatting checks,
  linting, and tests). See the [Makefile](../Makefile) for individual targets.
- Add meaningful tests for behavior; do not add tests that merely mirror trivial
  scaffolding.
- For documentation-only changes, verify that relative file links resolve from
  the document containing them.
- Report unavailable tools and failed checks explicitly. Never claim a check ran
  successfully unless it did.

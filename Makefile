STYLUA ?= stylua
LUACHECK ?= luacheck
NVIM_BIN ?= nvim
LUA_PATHS := lua plugin tests scripts
LUA_FILES := $(shell find $(LUA_PATHS) -type f -name '*.lua')

.PHONY: format format-lua lint lint-lua test check hooks setup rename

format: format-lua

format-lua:
ifneq ($(strip $(LUA_FILES)),)
	$(STYLUA) $(LUA_FILES)
else
	@echo "No Lua files to format."
endif

lint: lint-lua

lint-lua:
ifneq ($(strip $(LUA_FILES)),)
	$(STYLUA) --check $(LUA_FILES)
	$(LUACHECK) $(LUA_FILES)
else
	@echo "No Lua files to lint."
endif

test:
	$(NVIM_BIN) --headless -u NONE -i NONE -l tests/run.lua

check: lint test

rename: export NAME := $(NAME)
rename:
	@test -n "$$NAME" || { echo "Usage: make rename NAME=my-tool"; exit 1; }
	$(NVIM_BIN) --headless -u NONE -i NONE -l scripts/rename.lua "$$NAME"

hooks:
	install -d "$$(git rev-parse --git-path hooks)"
	install -m 755 .githooks/pre-commit .githooks/commit-msg "$$(git rev-parse --git-path hooks)/"

setup: hooks

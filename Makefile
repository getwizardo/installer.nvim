.PHONY: test fmt

# Runs the pure-Lua tests. Uses Neovim when available, otherwise LuaJIT / Lua 5.1.
test:
	@if command -v nvim >/dev/null 2>&1; then nvim -l tests/run.lua; \
	elif command -v luajit >/dev/null 2>&1; then luajit tests/run.lua; \
	elif command -v lua5.1 >/dev/null 2>&1; then lua5.1 tests/run.lua; \
	else echo "need nvim, luajit or lua5.1"; exit 1; fi

fmt:
	stylua lua plugin tests

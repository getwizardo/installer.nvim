.PHONY: test fmt

# Runs the pure-Lua tests. Uses Neovim when available, otherwise LuaJIT / Lua 5.1.
test:
	@if command -v nvim >/dev/null 2>&1; then nvim -l tests/run.lua; \
	elif command -v luajit >/dev/null 2>&1; then luajit tests/run.lua; \
	elif command -v lua5.1 >/dev/null 2>&1; then lua5.1 tests/run.lua; \
	elif python3 -c "import lupa" >/dev/null 2>&1; then python3 tests/run.py tests/run.lua; \
	else echo "need nvim, luajit, lua5.1 or python3 + lupa"; exit 1; fi

fmt:
	stylua lua plugin tests

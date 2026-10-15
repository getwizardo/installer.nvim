# Fallback runner: executes tests/run.lua with LuaJIT via `pip install lupa` when no nvim/luajit is available.
import sys
import lupa.luajit21 as lj
L = lj.LuaRuntime(unpack_returned_tuples=True)
L.execute('arg = {}')
L.execute('os.exit = function(c) error("__EXIT__" .. tostring(c)) end')
try:
    L.execute(open(sys.argv[1]).read())
except Exception as e:
    msg = str(e)
    if "__EXIT__1" in msg: sys.exit(1)
    print(msg); sys.exit(2)

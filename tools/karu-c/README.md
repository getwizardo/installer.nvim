# kaeru-cast

A small C client for the Kikru cast server. It sends links and transport
commands over HTTP. It uses POSIX sockets only, so no libcurl is needed.

    make -C tools/karu-c
    tools/karu-c/kaeru-cast cast "https://www.youtube.com/watch?v=..." --mode queue
    tools/karu-c/kaeru-cast toggle
    tools/karu-c/kaeru-cast volume 40
    tools/karu-c/kaeru-cast status

Start the server first with `:Kikru cast server`. It listens on 127.0.0.1:8722.
Set `KAERU_CAST_PORT`, `KAERU_CAST_HOST`, and `KAERU_CAST_TOKEN` (or pass `-p`,
`-H`, `-t`) when the server uses another port or a token.

Exit status: 0 on success, 1 on an HTTP error, 2 on a usage error, 3 when the
server cannot be reached.

Tests: `make -C tools/karu-c test` (runs against a local mock server).

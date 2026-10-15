"""Tests for the kaeru-cast C client, against a local mock of the Kikru cast server."""
import http.server
import os
import subprocess
import sys
import threading
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(HERE, "..", "kaeru-cast")
seen = []


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        seen.append(self.path)
        if "token=wrong" in self.path:
            code, body = 401, b'{"ok":false,"error":"missing or invalid token"}'
        elif self.path.startswith("/cast"):
            code, body = 200, b'{"ok":true,"queued":"play"}'
        elif self.path.startswith("/status"):
            code, body = 200, b'{"ok":true,"state":{"playing":true}}'
        else:
            code, body = 200, b'{"ok":true}'
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def run(args, port, env=None):
    cmd = [BIN, "-H", "127.0.0.1", "-p", str(port)] + args
    e = dict(os.environ)
    e.pop("KAERU_CAST_TOKEN", None)
    if env:
        e.update(env)
    return subprocess.run(cmd, capture_output=True, text=True, env=e, timeout=10)


def main():
    if not os.path.exists(BIN):
        print("build first: make -C tools/karu-c")
        return 1
    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    failures = []

    def check(name, cond, detail=""):
        if not cond:
            failures.append(f"{name}: {detail}")
            print("FAIL", name, detail)
        else:
            print("ok  ", name)

    r = run(["cast", "https://www.youtube.com/watch?v=abc&t=10"], port)
    check("cast exits 0", r.returncode == 0, r.stderr)
    path = seen[-1]
    q = urllib.parse.parse_qs(urllib.parse.urlsplit(path).query)
    check("cast url is percent-encoded and decodes back", q.get("url") == ["https://www.youtube.com/watch?v=abc&t=10"], path)
    check("cast defaults to mode=play", q.get("mode") == ["play"], path)
    check("cast prints the JSON body", '"queued":"play"' in r.stdout, r.stdout)

    r = run(["cast", "https://example.com/a.mp3", "--mode", "queue"], port)
    check("cast --mode queue", "mode=queue" in seen[-1], seen[-1])

    r = run(["cast", "x", "--mode", "bogus"], port)
    check("bad mode is a usage error (2)", r.returncode == 2, str(r.returncode))

    for verb in ["play", "pause", "toggle", "next", "prev", "stop"]:
        r = run([verb], port)
        check(f"transport {verb}", r.returncode == 0 and seen[-1] == f"/{verb}", seen[-1])

    r = run(["volume", "42"], port)
    check("volume 42", seen[-1] == "/volume?value=42", seen[-1])
    r = run(["volume", "999"], port)
    check("volume out of range is rejected", r.returncode == 2, str(r.returncode))
    r = run(["volume", "loud"], port)
    check("volume must be a number", r.returncode == 2, str(r.returncode))

    r = run(["status"], port)
    check("status prints state", '"playing":true' in r.stdout, r.stdout)

    r = run(["status"], port, {"KAERU_CAST_TOKEN": "abc def"})
    check("token from environment is sent and encoded", seen[-1] == "/status?token=abc%20def", seen[-1])

    r = run(["-t", "wrong", "play"], port)
    check("HTTP 401 exits 1 and says so", r.returncode == 1 and "HTTP 401" in r.stderr, f"{r.returncode} {r.stderr}")

    r = subprocess.run([BIN, "-H", "127.0.0.1", "-p", "1", "status"], capture_output=True, text=True, timeout=10)
    check("no server exits 3 with a hint", r.returncode == 3 and "cast server" in r.stderr, f"{r.returncode} {r.stderr}")

    r = run(["bogus"], port)
    check("unknown command is a usage error", r.returncode == 2, str(r.returncode))

    server.shutdown()
    print(f"\n{len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# Fixture server for the token-efficiency benchmark (scripts/bench-agent.sh).
# Serves this folder, plus two endpoints the scenarios need:
#   /api/orders   always answers 500 (the failing-request scenario)
#   /admin/login  sets `session` with Path=/admin (the cookie-scope scenario)
#   python3 server.py [port]
import http.server, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=HERE, **kwargs)

    def send_json(self, status, body, headers=()):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/api/orders":
            return self.send_json(500, {"error": "internal", "message": "orders service unavailable"})
        if path == "/admin/login":
            return self.send_json(200, {"ok": True, "user": "ada"},
                                  [("Set-Cookie", "session=abc123; Path=/admin; SameSite=Lax")])
        return super().do_GET()

    def log_message(self, *args):
        pass

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8792
    http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()

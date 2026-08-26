#!/usr/bin/env python3
"""Serve docs/ locally, the way GitHub Pages does.

    python3 tools/serve_docs.py          # http://localhost:8731
    python3 tools/serve_docs.py 9000     # another port

`python3 -m http.server` is enough for the pages as they are, but it answers no
Range requests and is single threaded. Both matter the moment there are clips in
docs/shots/: Safari refuses to play media from a server that ignores Range, and
one thread stalls when a browser opens several connections for one page. This
speaks HTTP/1.1, answers Range, and threads, so what you see locally is what
Pages will serve.
"""

import mimetypes
import os
import re
import socketserver
import sys
import webbrowser
from http.server import BaseHTTPRequestHandler

ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "docs")
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8731


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def resolve(self):
        rel = self.path.split("?")[0].split("#")[0].lstrip("/")
        path = os.path.abspath(os.path.join(ROOT, rel))
        if os.path.isdir(path):
            path = os.path.join(path, "index.html")
        # A crafted path must not reach outside docs/.
        if not path.startswith(ROOT):
            return None
        return path if os.path.isfile(path) else None

    def do_GET(self):
        path = self.resolve()
        if not path:
            body = b"not found"
            self.send_response(404)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        size = os.path.getsize(path)
        start, end, status = 0, size - 1, 200

        rng = self.headers.get("Range")
        if rng:
            match = re.match(r"bytes=(\d*)-(\d*)", rng)
            if match:
                if match.group(1):
                    start = int(match.group(1))
                    if match.group(2):
                        end = min(int(match.group(2)), size - 1)
                elif match.group(2):
                    start = max(0, size - int(match.group(2)))
                status = 206

        length = max(0, end - start + 1)
        self.send_response(status)
        self.send_header("Content-Type",
                         mimetypes.guess_type(path)[0] or "application/octet-stream")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", "no-store")
        if status == 206:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.end_headers()

        with open(path, "rb") as handle:
            handle.seek(start)
            remaining = length
            while remaining > 0:
                chunk = handle.read(min(65536, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)

    def log_message(self, fmt, *args):
        sys.stderr.write("  %s\n" % (fmt % args))


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    url = "http://localhost:%d/" % PORT
    print("serving %s at %s" % (ROOT, url))
    print("pages: index, whatsapp, telegram, signal, facetime, zoom,")
    print("       google-meet, microsoft-teams, slack-huddles, discord,")
    print("       security, privacy, hipaa")
    print("ctrl-c to stop\n")
    try:
        webbrowser.open(url)
    except Exception:
        pass
    try:
        Server(("127.0.0.1", PORT), Handler).serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")

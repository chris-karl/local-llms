#!/usr/bin/env python3
"""Sanitizing reverse-proxy that fronts llama-server for the Claude Code router.

Why this exists: llama.cpp (checked on b10050, the current brew stable) turns a
tool's JSON-Schema *value constraints* -- pattern, format, min/max, minItems,
propertyNames, ... -- into a GBNF grammar that forces the model's tool-call
arguments to match. Across Claude Code's full tool suite (~27 tools) the
combined grammar overflows llama.cpp's rule limit and the request fails closed:

    400  Failed to initialize samplers: failed to parse grammar

Only the models whose chat format grammar-constrains arguments hit it -- gpt-oss
(harmony) and devstral (Mistral). The Qwen presets are immune because their
format doesn't constrain arguments, which is why they work unpatched.

The fix: strip those value-constraint keywords from every tool schema before the
request reaches llama-server. They only bound argument *values* (a string's
length, a number's range); the tool's name, description and parameter structure
are untouched, so the model still calls tools correctly -- it just isn't
grammar-forced to honour value bounds, which capable models do anyway.

This proxy also *owns* the llama-server it fronts: it launches the command given
after `--` on a private loopback port, forwards to it, and exits with it (and
kills it on SIGTERM/SIGINT). So to router.sh it is just "the router on $PORT" --
kill it and llama-server goes too. serve.sh execs it in place of llama-server.

    router-shim.py --listen 127.0.0.1:8080 -- llama-server --models-preset ...
"""

import http.client
import json
import os
import signal
import socket
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# JSON-Schema keywords that only constrain a value (not the shape of the tool
# interface) and that llama.cpp compiles into grammar rules. Dropping them is
# what keeps the combined tool grammar under llama.cpp's limit.
STRIP_KEYS = {
    "pattern", "format",
    "minLength", "maxLength",
    "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
    "minItems", "maxItems", "uniqueItems",
    "minProperties", "maxProperties", "propertyNames", "patternProperties",
}

UPSTREAM_HOST = "127.0.0.1"
UPSTREAM_PORT = None  # filled in once the private llama-server port is chosen


def strip(node):
    """Recursively drop STRIP_KEYS from a schema subtree."""
    if isinstance(node, dict):
        return {k: strip(v) for k, v in node.items() if k not in STRIP_KEYS}
    if isinstance(node, list):
        return [strip(x) for x in node]
    return node


def sanitize_body(raw):
    """Return possibly-rewritten request bytes; only touches `tools` entries."""
    try:
        body = json.loads(raw)
    except Exception:
        return raw
    tools = body.get("tools")
    if not isinstance(tools, list):
        return raw
    body["tools"] = [strip(t) for t in tools]
    return json.dumps(body).encode()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):  # quiet; llama-server does the logging
        pass

    def _relay(self, method):
        length = int(self.headers.get("content-length", 0) or 0)
        raw = self.rfile.read(length) if length else b""

        if method == "POST" and "application/json" in self.headers.get("content-type", ""):
            raw = sanitize_body(raw)

        headers = {}
        for k, v in self.headers.items():
            if k.lower() in ("host", "content-length", "connection",
                             "transfer-encoding", "expect"):
                continue
            headers[k] = v
        headers["Content-Length"] = str(len(raw))

        try:
            # Generous: a dense preset prefilling Claude Code's ~20K-token
            # system prompt cold can take minutes before the first byte.
            up = http.client.HTTPConnection(UPSTREAM_HOST, UPSTREAM_PORT, timeout=900)
            up.request(method, self.path, body=raw, headers=headers)
            resp = up.getresponse()
        except (ConnectionRefusedError, OSError):
            # llama-server not up yet (startup) or gone: let the caller retry.
            self.send_response(503)
            self.send_header("content-type", "application/json")
            msg = b'{"error":{"type":"unavailable","message":"upstream not ready"}}'
            self.send_header("content-length", str(len(msg)))
            self.end_headers()
            self.wfile.write(msg)
            return

        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() in ("content-length", "transfer-encoding", "connection"):
                continue
            self.send_header(k, v)
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        # Stream the body through as it arrives, so SSE (stream:true) stays live.
        try:
            while True:
                chunk = resp.read(8192)
                if not chunk:
                    break
                self.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n")
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            # Client hung up mid-stream (e.g. Claude Code timed out waiting on a
            # slow first token). Nothing to do but stop writing.
            pass
        finally:
            up.close()

    do_GET = lambda self: self._relay("GET")
    do_POST = lambda self: self._relay("POST")
    do_DELETE = lambda self: self._relay("DELETE")
    do_PUT = lambda self: self._relay("PUT")
    do_OPTIONS = lambda self: self._relay("OPTIONS")


def free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def main():
    argv = sys.argv[1:]
    if "--listen" not in argv or "--" not in argv:
        sys.exit("usage: router-shim.py --listen HOST:PORT -- <llama-server ...>")
    listen = argv[argv.index("--listen") + 1]
    lhost, lport = listen.rsplit(":", 1)
    cmd = argv[argv.index("--") + 1:]

    global UPSTREAM_PORT
    UPSTREAM_PORT = free_port()
    cmd = cmd + ["--host", UPSTREAM_HOST, "--port", str(UPSTREAM_PORT)]

    # Launch and own llama-server; its stdout/stderr are ours (-> router.log).
    child = subprocess.Popen(cmd)

    def shutdown(*_):
        if child.poll() is None:
            child.terminate()
        try:
            child.wait(timeout=20)
        except Exception:
            child.kill()
        os._exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    # If llama-server dies on its own, take the shim down too, so router.sh's
    # health check sees the router as gone.
    def watch():
        child.wait()
        os._exit(child.returncode if child.returncode is not None else 1)
    threading.Thread(target=watch, daemon=True).start()

    httpd = ThreadingHTTPServer((lhost, int(lport)), Handler)
    httpd.daemon_threads = True
    httpd.serve_forever()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Serves web/ with CORS so browser tests can load the SQLite Wasm module."""
import functools
import http.server
import pathlib

WEB = pathlib.Path(__file__).resolve().parents[2] / 'web'


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        '.wasm': 'application/wasm',
    }

    def end_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cross-Origin-Resource-Policy', 'cross-origin')
        super().end_headers()

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(
    ('127.0.0.1', 8377), functools.partial(Handler, directory=str(WEB))
).serve_forever()

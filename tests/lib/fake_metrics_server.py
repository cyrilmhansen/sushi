#!/usr/bin/env python3
# sushi-test: tier=lib
# A read-only stand-in for the Sushi HTTP surface, for tests/measure-persistence.sh.
#
# It serves exactly two GETs, /metrics.json and /props, from files in a directory the test owns, so
# one session's two snapshots can be taken from one address with different bodies. Flags in that
# directory change behaviour: OFF makes /metrics.json answer 503 (metrics disabled), NOPROPS makes
# /props answer 404. Any POST/PUT/DELETE/PATCH is answered 501 and written to the access log, so a
# test can prove the measuring script never sends one.
#
# Usage: fake_metrics_server.py <servedir> <port> <accesslog>

import http.server
import os
import sys

ROOT, PORT, LOG = sys.argv[1], int(sys.argv[2]), sys.argv[3]


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def _log(self, status):
        with open(LOG, 'a') as fh:
            fh.write('%s %s %s\n' % (self.command, self.path, status))

    def _reply(self, status, body=b'', ctype='application/json'):
        self.send_response(status)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)
        self._log(status)

    def do_GET(self):
        path = self.path.split('?')[0].lstrip('/')
        if path == 'metrics.json' and os.path.exists(os.path.join(ROOT, 'OFF')):
            return self._reply(503, b'{"error":"metrics not enabled"}')
        if path == 'props' and os.path.exists(os.path.join(ROOT, 'NOPROPS')):
            return self._reply(404, b'not found')
        f = os.path.join(ROOT, path)
        if not os.path.isfile(f):
            return self._reply(404, b'not found')
        with open(f, 'rb') as fh:
            return self._reply(200, fh.read())

    def _refused(self):
        self._reply(501, b'write methods are not served here')

    do_POST = do_PUT = do_DELETE = do_PATCH = _refused

    def log_message(self, fmt, *args):
        pass


class Server(http.server.ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


with Server(('127.0.0.1', PORT), Handler) as srv:
    srv.serve_forever()

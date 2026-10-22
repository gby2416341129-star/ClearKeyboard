"""Serve the fixture and reopen its fixed URL before a diagnostic sequence.

Runs only on a disposable Mac test runner. The single fixed action avoids
assuming Safari survived the initial Settings/Add Keyboard preparation.
"""
import argparse
import functools
import http.server
import json
import subprocess
import uuid

FIXTURE_URL = 'http://127.0.0.1:8765/safari-fixture.html'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--device', required=True, type=uuid.UUID)
    parser.add_argument('--directory', required=True)
    args = parser.parse_args()

    class Handler(http.server.SimpleHTTPRequestHandler):
        def do_POST(self):
            if self.path != '/open-safari-fixture' or self.headers.get('Content-Length', '0') != '0':
                self.send_error(400)
                return
            try:
                result = subprocess.run(['xcrun', 'simctl', 'openurl', str(args.device), FIXTURE_URL],
                                        capture_output=True, text=True, timeout=20)
                status = 200 if result.returncode == 0 else 503
                response = dict(requestedURL=FIXTURE_URL, exitCode=result.returncode,
                                stderr=result.stderr[-1500:], initialEntryOnly=True,
                                focusTransitionsVerified=False)
            except subprocess.TimeoutExpired:
                status = 504
                response = dict(requestedURL=FIXTURE_URL, error='openurl timed out after 20 seconds')
            data = json.dumps(response).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    server = http.server.ThreadingHTTPServer(
        ('127.0.0.1', 8765), functools.partial(Handler, directory=args.directory))
    server.serve_forever()


if __name__ == '__main__':
    main()

# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
"""Loopback HTTPS stand-in for Artifactory, for tests/test_cli.sh.

Usage: artifactory_fixture.py <cert.pem> <key.pem> <port-file> <log>

Logs one JSON line per request (method, path, authorization, body)
and writes its port once listening. A PUT whose path contains
"reject" gets 403; every other PUT succeeds and is stored, and an AQL
search returns every stored file.
"""

import hashlib
import json
import ssl
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import final, override

STORED: dict[str, str] = {}


@final
class Handler(BaseHTTPRequestHandler):
    """Record each request and answer like a permissive Artifactory."""

    def _handle(self) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode(errors="replace")
        with open(sys.argv[4], "a", encoding="utf-8") as log:
            entry = {
                "method": self.command,
                "path": self.path,
                "authorization": self.headers.get("Authorization", ""),
                "body": body,
            }
            _ = log.write(json.dumps(entry) + "\n")
        status = 403 if self.command == "PUT" and "reject" in self.path else 200
        if status == 200 and self.command == "PUT":
            status = 201
        reply = b'{"version":"7.104.0"}' if status < 400 else b'{"errors":[]}'
        if status == 201:
            STORED[self.path] = hashlib.sha256(body.encode()).hexdigest()
        if self.path.endswith("/api/search/aql"):
            reply = json.dumps({"results": _aql_results()}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        _ = self.wfile.write(reply)

    def do_GET(self) -> None:  # noqa: N802
        """Answer version and other read requests."""
        self._handle()

    def do_HEAD(self) -> None:  # noqa: N802
        """Answer existence checks."""
        self._handle()

    def do_POST(self) -> None:  # noqa: N802
        """Answer AQL searches."""
        self._handle()

    def do_PUT(self) -> None:  # noqa: N802
        """Accept or reject an upload."""
        self._handle()

    @override
    def log_message(self, format: str, *args: object) -> None:  # noqa: A002
        """Keep test output quiet; the JSON log is the record."""


def _aql_results() -> list[dict[str, str]]:
    """Describe every stored file the way an AQL search does."""
    results: list[dict[str, str]] = []
    for url_path, sha256 in STORED.items():
        repo, _, rest = url_path.removeprefix("/artifactory/").partition("/")
        folder, _, name = rest.rpartition("/")
        results.append(
            {
                "repo": repo,
                "path": folder or ".",
                "name": name,
                "type": "file",
                "sha256": sha256,
            }
        )
    return results


def main() -> None:
    """Serve on an ephemeral loopback port until killed."""
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(sys.argv[1], sys.argv[2])
    server.socket = context.wrap_socket(server.socket, server_side=True)
    with open(sys.argv[3], "w", encoding="utf-8") as port_file:
        _ = port_file.write(str(server.server_address[1]))
    server.serve_forever()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Exercise the Mobile HTTP contract against a local in-process fake API.

This is deliberately not a production smoke test.  It proves that the
wire-level assumptions used by the native tests are reproducible without a
network, credentials, or a deployed WebTag instance: session identity,
minimal submit bodies, same-key replay, and explicit refresh.
"""

from __future__ import annotations

import http.client
import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any


NAMESPACE = "n" * 43
API_KEY = "synthetic-mobile-smoke-key"
URL = "https://example.org/mobile-wire-smoke"
LINK_ID = "11111111-1111-1111-1111-111111111111"


class FakeAPI(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    submissions: dict[str, dict[str, Any]] = {}

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def send_json(self, status: int, payload: dict[str, Any], **headers: str) -> None:
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-WebTag-Data-Namespace", NAMESPACE)
        for name, value in headers.items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path != "/api/session":
            self.send_json(404, {"error": {"error_code": "not_found"}})
            return
        self.send_json(
            200,
            {
                "client_data_namespace": NAMESPACE,
                "representation_contract": "v2",
                "scopes": ["write"],
            },
        )

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        if self.path == "/api/links":
            try:
                payload = json.loads(body.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                self.send_json(400, {"error": {"error_code": "invalid_json"}})
                return
            if set(payload) != {"url"} or payload["url"] != URL:
                self.send_json(400, {"error": {"error_code": "invalid_body"}})
                return
            key = self.headers.get("Idempotency-Key")
            if not key:
                self.send_json(400, {"error": {"error_code": "missing_idempotency_key"}})
                return
            previous = self.submissions.get(key)
            if previous is None:
                self.submissions[key] = {"url": payload["url"], "link_id": LINK_ID}
                self.send_json(202, {"link_id": LINK_ID, "status": "pending"})
            elif previous["url"] == payload["url"]:
                self.send_json(
                    202,
                    {"link_id": previous["link_id"], "status": "pending"},
                    **{"Idempotent-Replay": "true"},
                )
            else:
                self.send_json(409, {"error": {"error_code": "idempotency_body_mismatch"}})
            return
        if self.path == f"/api/links/{LINK_ID}/refresh":
            if body:
                self.send_json(400, {"error": {"error_code": "unexpected_body"}})
                return
            self.send_json(202, {"link_id": LINK_ID, "status": "pending"})
            return
        self.send_json(404, {"error": {"error_code": "not_found"}})


def request(
    port: int,
    method: str,
    path: str,
    body: bytes | None = None,
    headers: dict[str, str] | None = None,
) -> tuple[int, dict[str, str], bytes]:
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
    try:
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        return response.status, {key.lower(): value for key, value in response.getheaders()}, response.read()
    finally:
        connection.close()


def main() -> int:
    FakeAPI.submissions = {}
    server = HTTPServer(("127.0.0.1", 0), FakeAPI)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        port = server.server_port
        common_headers = {
            "Authorization": f"Bearer {API_KEY}",
            "Accept": "application/json",
            "X-WebTag-Data-Namespace": NAMESPACE,
        }
        status, headers, body = request(port, "GET", "/api/session", headers=common_headers)
        session = json.loads(body)
        assert status == 200
        assert session["client_data_namespace"] == NAMESPACE
        assert session["representation_contract"] == "v2"
        assert session["scopes"] == ["write"]
        assert headers["x-webtag-data-namespace"] == NAMESPACE

        submit_body = json.dumps({"url": URL}, separators=(",", ":")).encode("utf-8")
        submit_headers = {**common_headers, "Idempotency-Key": "mobile-smoke-key", "Content-Type": "application/json"}
        first_status, first_headers, first_body = request(
            port, "POST", "/api/links", body=submit_body, headers=submit_headers
        )
        second_status, second_headers, second_body = request(
            port, "POST", "/api/links", body=submit_body, headers=submit_headers
        )
        first = json.loads(first_body)
        second = json.loads(second_body)
        assert first_status == second_status == 202
        assert first["link_id"] == second["link_id"] == LINK_ID
        assert "idempotent-replay" not in first_headers
        assert second_headers["idempotent-replay"] == "true"

        refresh_status, _, refresh_body = request(
            port,
            "POST",
            f"/api/links/{LINK_ID}/refresh",
            headers=common_headers,
        )
        refresh = json.loads(refresh_body)
        assert refresh_status == 202
        assert refresh["link_id"] == LINK_ID

        print("mobile wire smoke passed: session, minimal submit, idempotent replay, and refresh")
        return 0
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


if __name__ == "__main__":
    raise SystemExit(main())

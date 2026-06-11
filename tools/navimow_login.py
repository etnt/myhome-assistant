#!/usr/bin/env python3
"""Obtain a Navimow cloud access token via the OAuth2 browser flow.

The Navimow cloud uses a standard OAuth2 *authorization-code* flow. The
NavimowHA Home Assistant integration relies on HA's generic
`LocalOAuth2Implementation`, whose redirect URI is simply
`<ha-host>/auth/external/callback`. Because every HA install has a different
host, the cloud accepts an arbitrary redirect -- so we can run the same flow
locally with `http://localhost:<port>/auth/external/callback`.

This script:
  1. starts a tiny local web server to catch the OAuth redirect,
  2. opens the Navimow login page in your browser (you log in with the SAME
     account you use in the Navimow mobile app -- your password is entered on
     Navimow's site, never seen by this script),
  3. captures the returned `code`, exchanges it for an access token, and
  4. prints an `export NAVIMOW_TOKEN=...` line (and optionally saves it).

Usage:
    pip install 'navimow-sdk>=0.1.2'   # not strictly needed here, but for the poller
    python tools/navimow_login.py
    # then follow the printed instructions, or:
    python tools/navimow_login.py --save   # also write ~/.config/navimow/token.json
"""
from __future__ import annotations

import argparse
import http.server
import json
import os
import secrets
import socket
import threading
import urllib.parse
import urllib.request
import webbrowser
from pathlib import Path

# Endpoints + client identity copied from the NavimowHA integration (public).
AUTHORIZE_URL = "https://navimow-h5-fra.willand.com/smartHome/login"
TOKEN_URL = "https://navimow-fra.ninebot.com/openapi/oauth/getAccessToken"
CLIENT_ID = "homeassistant"
CLIENT_SECRET = "57056e15-722e-42be-bbaa-b0cbfb208a52"

CALLBACK_PATH = "/auth/external/callback"
TOKEN_FILE = Path.home() / ".config" / "navimow" / "token.json"

# Filled in by the callback handler.
_received: dict[str, str] = {}
_done = threading.Event()


class _CallbackHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 (http.server API)
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != CALLBACK_PATH:
            self.send_response(404)
            self.end_headers()
            return
        query = dict(urllib.parse.parse_qsl(parsed.query))
        _received.update(query)
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        ok = "code" in query
        msg = (
            "Login complete. You can close this tab and return to the terminal."
            if ok
            else f"No authorization code received. Query: {query}"
        )
        self.wfile.write(f"<html><body><h3>{msg}</h3></body></html>".encode())
        _done.set()

    def log_message(self, *args) -> None:  # silence default logging
        pass


def _build_authorize_url(redirect_uri: str, state: str) -> str:
    query = {
        "response_type": "code",
        "client_id": CLIENT_ID,
        "redirect_uri": redirect_uri,
        "state": state,
        "channel": "homeassistant",
    }
    return f"{AUTHORIZE_URL}?{urllib.parse.urlencode(query)}"


def _exchange_code(code: str, redirect_uri: str) -> dict:
    data = urllib.parse.urlencode(
        {
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect_uri,
            "client_id": CLIENT_ID,
            "client_secret": CLIENT_SECRET,
        }
    ).encode()
    req = urllib.request.Request(
        TOKEN_URL,
        data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode())


def main() -> int:
    parser = argparse.ArgumentParser(description="Navimow OAuth2 login helper.")
    parser.add_argument("--port", type=int, default=8123, help="local callback port")
    parser.add_argument(
        "--no-browser", action="store_true", help="don't auto-open the browser"
    )
    parser.add_argument(
        "--save", action="store_true", help=f"also write token to {TOKEN_FILE}"
    )
    args = parser.parse_args()

    redirect_uri = f"http://localhost:{args.port}{CALLBACK_PATH}"
    state = secrets.token_urlsafe(16)

    # Start the local callback server.
    try:
        server = http.server.HTTPServer(("localhost", args.port), _CallbackHandler)
    except OSError as err:
        raise SystemExit(f"Cannot bind localhost:{args.port} ({err}). Try --port.")
    threading.Thread(target=server.serve_forever, daemon=True).start()

    auth_url = _build_authorize_url(redirect_uri, state)
    print("Open this URL and log in with your Navimow app account:\n")
    print(f"  {auth_url}\n")
    if not args.no_browser:
        webbrowser.open(auth_url)

    print(f"Waiting for the redirect to {redirect_uri} ...")
    if not _done.wait(timeout=300):
        raise SystemExit("Timed out waiting for login (5 min).")
    server.shutdown()

    if _received.get("state") != state:
        raise SystemExit(
            f"State mismatch (csrf). expected={state} got={_received.get('state')}"
        )
    code = _received.get("code")
    if not code:
        raise SystemExit(f"No authorization code in redirect: {_received}")

    print("Exchanging authorization code for an access token ...")
    token = _exchange_code(code, redirect_uri)
    access_token = token.get("access_token")
    if not access_token:
        raise SystemExit(f"No access_token in response: {token}")

    expires_in = token.get("expires_in")
    print("\nSuccess! Access token obtained.")
    if expires_in:
        print(f"  expires_in: {expires_in}s (~{int(expires_in) // 3600}h)")
    print("\nUse it with the status poller:\n")
    print(f"  export NAVIMOW_TOKEN='{access_token}'")
    print("  python tools/navimow_status.py\n")

    if args.save:
        TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
        TOKEN_FILE.write_text(json.dumps(token, indent=2))
        os.chmod(TOKEN_FILE, 0o600)
        print(f"Saved token to {TOKEN_FILE} (mode 600).")
    return 0


if __name__ == "__main__":
    try:
        socket.gethostbyname("localhost")
    except OSError:
        pass
    raise SystemExit(main())

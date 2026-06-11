#!/usr/bin/env python3
"""Local HTTP bridge that exposes Navimow mower status to the Web UI.

The Web UI (viz/index.html) runs in a browser and can only reach HTTP
endpoints; it cannot perform the cloud OAuth/SDK calls itself. This tiny
server sits on the same machine, fetches mower status via the Navimow cloud
(reusing navimow_client), caches it briefly, and serves it as CORS-enabled
JSON so the dashboard can render a mower card.

Token: read from NAVIMOW_TOKEN env or ~/.config/navimow/token.json
(create the latter with `python tools/navimow_login.py --save`).

Usage:
    pip install 'navimow-sdk>=0.1.2'
    python tools/navimow_server.py                 # serves on :8765
    python tools/navimow_server.py --port 8765
    # then open the Web UI; the mower card appears on the dashboard.
"""
from __future__ import annotations

import argparse
import time

from aiohttp import web

from navimow_client import fetch_status

CACHE_TTL_SECONDS = 60  # cloud is polled at most once per minute
_cache: dict[str, object] = {"ts": 0.0, "data": None}

CORS_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
}


async def handle_options(request: web.Request) -> web.Response:
    return web.Response(status=204, headers=CORS_HEADERS)


async def handle_mower(request: web.Request) -> web.Response:
    now = time.monotonic()
    cached = _cache["data"]
    if cached is not None and now - float(_cache["ts"]) < CACHE_TTL_SECONDS:
        return web.json_response({"ok": True, "mowers": cached, "cached": True},
                                 headers=CORS_HEADERS)
    try:
        rows = await fetch_status()
    except Exception as err:  # token expired, cloud error, missing SDK, etc.
        return web.json_response(
            {"ok": False, "error": str(err)}, headers=CORS_HEADERS
        )
    _cache["ts"] = now
    _cache["data"] = rows
    return web.json_response({"ok": True, "mowers": rows, "cached": False},
                             headers=CORS_HEADERS)


async def handle_health(request: web.Request) -> web.Response:
    return web.json_response({"ok": True, "service": "navimow-bridge"},
                             headers=CORS_HEADERS)


def main() -> None:
    parser = argparse.ArgumentParser(description="Navimow status HTTP bridge.")
    parser.add_argument("--port", type=int, default=8765, help="listen port")
    parser.add_argument("--host", default="127.0.0.1", help="bind address")
    args = parser.parse_args()

    app = web.Application()
    app.add_routes(
        [
            web.get("/", handle_health),
            web.get("/api/mower", handle_mower),
            web.options("/api/mower", handle_options),
        ]
    )
    print(f"Navimow bridge listening on http://{args.host}:{args.port}/api/mower")
    web.run_app(app, host=args.host, port=args.port, print=None)


if __name__ == "__main__":
    main()

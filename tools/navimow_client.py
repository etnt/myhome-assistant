"""Shared Navimow cloud helpers: token loading + status fetch.

Used by both the CLI poller (navimow_status.py) and the bridge server
(navimow_server.py) so the cloud logic lives in one place.
"""
from __future__ import annotations

import json
import os
from pathlib import Path

import aiohttp

API_BASE_URL = os.environ.get(
    "NAVIMOW_API_BASE_URL", "https://navimow-fra.ninebot.com"
)
TOKEN_FILE = Path.home() / ".config" / "navimow" / "token.json"


def load_token() -> str | None:
    """Return an access token from NAVIMOW_TOKEN env or the saved token file."""
    token = os.environ.get("NAVIMOW_TOKEN")
    if token:
        return token
    if TOKEN_FILE.exists():
        try:
            return json.loads(TOKEN_FILE.read_text()).get("access_token")
        except (ValueError, OSError):
            return None
    return None


async def fetch_status(token: str | None = None) -> list[dict]:
    """Return a list of mower status dicts for all devices on the account."""
    from mower_sdk.api import MowerAPI

    token = token or load_token()
    if not token:
        raise RuntimeError(
            "No Navimow token. Set NAVIMOW_TOKEN or run "
            "`python tools/navimow_login.py --save`."
        )

    async with aiohttp.ClientSession() as session:
        api = MowerAPI(session=session, token=token, base_url=API_BASE_URL)
        devices = await api.async_get_devices()
        result: list[dict] = []
        for device in devices:
            status = await api.async_get_device_status(device.id)
            result.append(
                {
                    "id": device.id,
                    "name": device.name,
                    "model": device.model,
                    "online": device.online,
                    "firmware": device.firmware_version,
                    "state": status.status.value,
                    "battery": status.battery,
                    "signal_strength": status.signal_strength,
                    "mowing_time": status.mowing_time,
                    "error_code": status.error_code.value,
                    "error_message": status.error_message,
                    "position": status.position,
                    "timestamp": status.timestamp,
                }
            )
        return result

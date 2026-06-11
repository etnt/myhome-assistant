#!/usr/bin/env python3
"""Fetch Navimow mower status from the Segway/Ninebot cloud.

The Navimow i208 has no local API -- it is a cloud-connected device. This
script reuses the same `navimow-sdk` (imported as `mower_sdk`) that the
NavimowHA Home Assistant integration uses, and performs the simplest possible
read: list devices and print their current status (state + battery).

Auth: the cloud uses an OAuth2 *authorization-code* flow (browser login), so
this script does NOT log in for you. You must supply an already-obtained
access token via the NAVIMOW_TOKEN environment variable. See the project notes
for how to obtain one.

Usage:
    pip install 'navimow-sdk>=0.1.2'
    export NAVIMOW_TOKEN='<access_token>'
    python tools/navimow_status.py            # human-readable
    python tools/navimow_status.py --json      # machine-readable
"""
from __future__ import annotations

import argparse
import asyncio
import json
import sys

from navimow_client import fetch_status


def print_human(rows: list[dict]) -> None:
    if not rows:
        print("No Navimow devices found on this account.")
        return
    for r in rows:
        online = "online" if r["online"] else "offline"
        line = (
            f"{r['name']} ({r['model']}, {online}): "
            f"state={r['state']} battery={r['battery']}%"
        )
        if r["error_code"] and r["error_code"] != "none":
            line += f" error={r['error_code']} ({r['error_message']})"
        print(line)


def main() -> int:
    parser = argparse.ArgumentParser(description="Print Navimow mower status.")
    parser.add_argument(
        "--json", action="store_true", help="emit JSON instead of text"
    )
    args = parser.parse_args()

    rows = asyncio.run(fetch_status())
    if args.json:
        print(json.dumps(rows, indent=2))
    else:
        print_human(rows)
    return 0


if __name__ == "__main__":
    sys.exit(main())

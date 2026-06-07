"""
MCP Server for MyHome Assistant ESP32 device.

Exposes the device's REST API as MCP tools so AI assistants
can control lights, read sensors, and manage automation policies.
"""

import os
import httpx
from mcp.server.fastmcp import FastMCP

DEVICE_URL = os.environ.get("MYHOME_DEVICE_URL", "http://192.168.68.64:8080")

mcp = FastMCP("MyHome Assistant")


def _api(method: str, path: str, json: dict | None = None) -> dict:
    """Make an API call to the device."""
    url = f"{DEVICE_URL}/api/{path}"
    with httpx.Client(timeout=10.0) as client:
        if method == "GET":
            r = client.get(url)
        else:
            r = client.post(url, json=json or {})
    return r.json()


# --- Status & Sensors ---


@mcp.tool()
def get_status() -> dict:
    """Get device status: list of bulbs and their connection state."""
    return _api("GET", "status")


@mcp.tool()
def get_sensors() -> dict:
    """Get current sensor readings (temperature, humidity, lux)."""
    return _api("GET", "sensors")


@mcp.tool()
def get_logs(level: str = "info", limit: int = 50) -> dict:
    """Get system logs from the device.

    Args:
        level: Log level filter (debug, info, warning, error)
        limit: Max number of log entries to return
    """
    url = f"{DEVICE_URL}/api/logs?level={level}&limit={limit}"
    with httpx.Client(timeout=10.0) as client:
        r = client.get(url)
    return r.json()


# --- BLE Scanning & Connections ---


@mcp.tool()
def get_scan_results() -> dict:
    """Get results from the last BLE scan."""
    return _api("GET", "scan")


@mcp.tool()
def trigger_scan(duration: int = 10) -> dict:
    """Trigger a new BLE scan for nearby devices.

    Args:
        duration: Scan duration in seconds (1-30)
    """
    return _api("POST", "scan", {"duration": duration})


@mcp.tool()
def discover_bulbs() -> dict:
    """Run bulb discovery and pairing. Finds new Hue bulbs via BLE."""
    return _api("POST", "discover")


@mcp.tool()
def get_connections() -> dict:
    """List active BLE connections to bulbs."""
    return _api("GET", "connections")


# --- Bulb Control ---


@mcp.tool()
def get_bulb_state(bulb: int) -> dict:
    """Get cached state of a bulb (no BLE connection needed).

    Args:
        bulb: Bulb number (1-4)
    """
    return _api("GET", f"bulb/{bulb}/state")


@mcp.tool()
def refresh_bulb_state(bulb: int) -> dict:
    """Live-read bulb state via BLE GATT (connects on-demand, slower).

    Args:
        bulb: Bulb number (1-4)
    """
    return _api("POST", f"bulb/{bulb}/refresh")


@mcp.tool()
def set_bulb_power(bulb: int, on: bool) -> dict:
    """Turn a bulb on or off.

    Args:
        bulb: Bulb number (1-4)
        on: True to turn on, False to turn off
    """
    return _api("POST", f"bulb/{bulb}/power", {"on": on})


@mcp.tool()
def set_bulb_brightness(bulb: int, value: int) -> dict:
    """Set bulb brightness.

    Args:
        bulb: Bulb number (1-4)
        value: Brightness level (1-254)
    """
    return _api("POST", f"bulb/{bulb}/brightness", {"value": value})


@mcp.tool()
def set_bulb_color_temp(bulb: int, value: int) -> dict:
    """Set bulb color temperature in mirek.

    Args:
        bulb: Bulb number (1-4)
        value: Color temperature in mirek (153=cold/6500K, 500=warm/2000K)
    """
    return _api("POST", f"bulb/{bulb}/color_temp", {"value": value})


@mcp.tool()
def set_bulb_color_xy(bulb: int, x: int, y: int) -> dict:
    """Set bulb color using CIE xy coordinates.

    Args:
        bulb: Bulb number (1-4)
        x: CIE x coordinate (0-65535)
        y: CIE y coordinate (0-65535)
    """
    return _api("POST", f"bulb/{bulb}/color_xy", {"x": x, "y": y})


@mcp.tool()
def set_bulb_state(bulb: int, power: bool | None = None, brightness: int | None = None, color_temp: int | None = None) -> dict:
    """Set multiple bulb properties at once.

    Args:
        bulb: Bulb number (1-4)
        power: True/False to turn on/off (optional)
        brightness: Brightness 1-254 (optional)
        color_temp: Color temperature in mirek 153-500 (optional)
    """
    body = {}
    if power is not None:
        body["power"] = power
    if brightness is not None:
        body["brightness"] = brightness
    if color_temp is not None:
        body["color_temp"] = color_temp
    return _api("POST", f"bulb/{bulb}/state", body)


# --- Automation Policies ---


@mcp.tool()
def list_policies() -> dict:
    """List all automation policies and their enabled/disabled status."""
    return _api("GET", "policies")


@mcp.tool()
def enable_policy(policy_id: str) -> dict:
    """Enable an automation policy.

    Args:
        policy_id: Policy identifier (e.g. 'evening_lights', 'dark_room')
    """
    return _api("POST", f"policies/{policy_id}/enable")


@mcp.tool()
def disable_policy(policy_id: str) -> dict:
    """Disable an automation policy.

    Args:
        policy_id: Policy identifier (e.g. 'evening_lights', 'dark_room')
    """
    return _api("POST", f"policies/{policy_id}/disable")


def main():
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()

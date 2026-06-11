# Navimow Mower Integration Plan

## Overview

Surface Navimow (Segway/Ninebot) robot lawn-mower status in the MyHome
Assistant dashboard. The mower is **cloud-only** — there is no local LAN API —
so all data flows through the vendor cloud (`https://navimow-fra.ninebot.com`)
using an OAuth2 access token.

This document captures the current working state and the planned future steps.
Implementation of the later phases is deferred.

## Current state (implemented)

A standalone, host-side bridge approach is working end-to-end:

```
┌────────────┐    HTTPS (cloud)     ┌──────────────────────┐
│  Navimow   │◄────────────────────►│  navimow_server.py   │
│  cloud API │   Bearer token       │  (host / home server)│
└────────────┘                      │  GET /api/mower      │
                                    │  + CORS, 60s cache   │
                                    └──────────┬───────────┘
                                               │ HTTP (LAN)
                                               ▼
                                    ┌──────────────────────┐
                                    │  viz/index.html      │
                                    │  🤖 Mower card       │
                                    │  refreshMower()      │
                                    └──────────────────────┘
```

Files:
- `tools/navimow_client.py` — shared cloud logic: `load_token()` (reads
  `NAVIMOW_TOKEN` env or `~/.config/navimow/token.json`) and `fetch_status()`.
- `tools/navimow_status.py` — CLI poller (human / `--json` output).
- `tools/navimow_login.py` — OAuth2 browser login helper; `--save` writes the
  token to `~/.config/navimow/token.json`.
- `tools/navimow_server.py` — aiohttp bridge serving `GET /api/mower`
  (CORS-enabled JSON, 60s cache, graceful `{ok:false,error}` on failure).
  Flags: `--host` (default `127.0.0.1`), `--port` (default `8765`).
- `viz/index.html` — Mower card on the dashboard; `refreshMower()` polls the
  bridge every 60s; Admin tab has a configurable **Mower Bridge** URL
  (`localStorage.myhome_mower_url`, default `http://localhost:8765`).

### Cloud API (reverse-engineered from `navimow-sdk`)

Auth: `Authorization: Bearer <token>` + `requestId: <uuid>` header.
- `GET  /openapi/smarthome/authList` — list devices
- `POST /openapi/smarthome/getVehicleStatus` — status (body: device ids)
- `POST /openapi/smarthome/sendCommands` — control (start/pause/dock/...)

OAuth2 (authorization-code):
- authorize: `https://navimow-h5-fra.willand.com/smartHome/login?channel=homeassistant`
- token: `https://navimow-fra.ninebot.com/openapi/oauth/getAccessToken`
- `client_id=homeassistant`, `client_secret=57056e15-722e-42be-bbaa-b0cbfb208a52`
- redirect_uri pattern: `<host>/auth/external/callback`

### Status payload fields

`id, name, model, online, firmware, state, battery, signal_strength,
mowing_time, error_code, error_message, position, timestamp`.
`state` enum: `idle | mowing | paused | docked | charging | error |
returning | unknown`.

Observations: HTTP endpoint returns `signal_strength/position/timestamp` as
null (these only populate over MQTT push). `online` reflects app/MQTT session
presence, not whether the mower is running.

## Deployment: run the bridge on the home server (recommended)

The bridge belongs on an always-on LAN machine, not the ESP32 (see below).

1. `pip install 'navimow-sdk>=0.1.2' aiohttp` on the server; copy
   `tools/navimow_client.py`, `navimow_server.py`, `navimow_login.py`.
2. Token: run `navimow_login.py --save` (needs a browser) on any machine, copy
   `~/.config/navimow/token.json` to the server (plain JSON, portable).
3. Run bound to the LAN: `python tools/navimow_server.py --host 0.0.0.0 --port 8765`.
4. UI → Admin → Mower Bridge → `http://<server-ip>:8765`.

systemd unit:

```ini
# /etc/systemd/system/navimow-bridge.service
[Unit]
Description=Navimow mower status bridge
After=network-online.target

[Service]
User=youruser
WorkingDirectory=/home/youruser/myhome-assistant
ExecStart=/usr/bin/python3 tools/navimow_server.py --host 0.0.0.0 --port 8765
Restart=on-failure
Environment=NAVIMOW_API_BASE_URL=https://navimow-fra.ninebot.com

[Install]
WantedBy=multi-user.target
```

Security caveat: `--host 0.0.0.0` exposes the bridge with no auth — keep it
LAN-only (firewall / no port-forward).

## Why not run the bridge on the ESP32?

Technically possible — AtomVM ships `ahttp_client` (HTTPS via `ssl`/MbedTLS) and
`json:decode/1`, and the API is plain Bearer-token HTTP. But:

- **Token can't be minted on-device** — OAuth needs a browser login; a token
  must be obtained externally and stored on-device (NVS).
- **Token expires ~1–2 days, usually no refresh_token** — requires periodic
  browser re-auth + pushing a fresh token to the device. Moving to the ESP32
  does not remove this chore.
- **AtomVM TLS defaults to `verify_none`** (no cert validation; MITM risk);
  provisioning CA certs is limited.
- **RAM/stability** — TLS handshakes are heavy on a chip already running BLE +
  sensors + HTTP. Unproven against this specific cloud; needs on-device testing.

Conclusion: keep cloud polling off the embedded device.

## Future work (deferred — implement later)

1. **Token lifecycle**
   - `navimow_login.py --refresh` one-shot / cron-friendly script.
   - Bridge: detect 401 → mark token expired in `/api/mower` response so the UI
     can show a "re-login needed" badge.

2. **MQTT live updates**
   - Use `async_get_mqtt_user_info()` + `NavimowSDK` (MQTT-over-WebSocket) for
     real-time state + position; bridge maintains the connection and serves the
     cached push state (fills the null `position/signal_strength/timestamp`).

3. **Controls from the UI**
   - `POST /api/mower/command` on the bridge → `MowerCommand`
     (start/pause/dock/resume/stop); add buttons to the mower card.

4. **MCP tool**
   - Wrap status as `get_mower_status` in `mcp_server/` (reuse `navimow_client`).

5. **UI polish**
   - Show mowing time / last-updated; error state styling; multi-mower layout.

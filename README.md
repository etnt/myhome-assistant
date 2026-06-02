# MyHome Assistant

Control Philips Hue Bluetooth light bulbs directly from an ESP32-S3 running
AtomVM/Erlang. No Hue Bridge required — communicates via BLE GATT.

## Hardware

- ESP32-S3 development board
- Philips Hue Bluetooth bulbs (2019+ models with built-in BLE)

## Architecture

```
ESP32-S3 (AtomVM/Erlang)
  ├── myhome_top_sup (rest_for_one)
  │     ├── myhome_log (in-memory log ring buffer)
  │     ├── ble (gen_server, owns port, serializes all BLE commands)
  │     ├── myhome_event_bus (pub/sub for BLE events)
  │     └── myhome_sup (one_for_one)
  │           ├── myhome_scanner (subscribes to scan events)
  │           ├── myhome_ble_conn (connection state machine)
  │           ├── myhome_http (WiFi + tiny_httpd)
  │           ├── myhome_http_handler (request routing + tiny_json)
  │           ├── myhome_discovery (pairing + bulb startup)
  │           ├── bulb_1 (connect-on-demand) ─·BLE·─► Hue Bulb 1
  │           └── bulb_2 (connect-on-demand) ─·BLE·─► Hue Bulb 2
  └── ble_port (C, NimBLE)
```

Event flow: C port → `ble` process → `myhome_event_bus` → filtered subscribers.

BLE strategy: **connect-on-demand** — bulb gen_servers only establish a BLE
connection when a command is sent, then disconnect after 5s idle. This keeps
the radio free for WiFi when no light commands are active.

## Prerequisites

- [ESP-IDF](https://docs.espressif.com/projects/esp-idf/en/stable/esp32s3/get-started/) (v5.x)
- [rebar3](https://rebar3.org/)
- USB connection to your ESP32-S3

## Quick Start

```bash
# Build and flash everything (first time)
make flash

# Or step by step:
make atomvm          # Build AtomVM firmware with BLE component
make flash-firmware  # Flash firmware to ESP32-S3
make flash-app       # Build and flash the Erlang application
make monitor         # Open serial console
```

## Configuration

Override defaults via environment or command line:

```bash
make flash PORT=/dev/cu.usbmodem5B414826621
make flash-app APP_OFFSET=0x250000
```

| Variable     | Default                      | Description                     |
|-------------|-----------------------------|---------------------------------|
| `PORT`      | `/dev/cu.usbmodem11101`     | Serial port for ESP32-S3        |
| `IDF_PATH`  | `~/esp/esp-idf`             | Path to ESP-IDF installation    |
| `APP_OFFSET`| `0x250000`                  | Flash offset for Erlang app     |

Run `make help` to see all targets.

## First Boot — Bulb Pairing

On first boot (no bulbs in NVS), the application runs discovery automatically:

1. Power-cycle your Hue bulbs (they enter pairing mode for ~30 seconds)
2. The ESP32 scans for all nearby BLE devices, then pairs with those that have "Hue" in their name
3. It connects and bonds with each discovered bulb
4. Addresses are stored in NVS for automatic reconnection on future boots

Monitor the serial console to follow the pairing process:

```bash
make monitor
```

## Usage (Erlang shell)

Once paired, the bulbs are controlled via named gen_servers:

```erlang
%% Turn on
myhome_hue_ble:set_power(bulb_1, true).

%% Set brightness (1-254)
myhome_hue_ble:set_brightness(bulb_1, 200).

%% Set color temperature (153-500 mirek, higher = warmer)
myhome_hue_ble:set_color_temp(bulb_1, 370).

%% Set color via CIE XY (0-65535 each)
myhome_hue_ble:set_color_xy(bulb_1, 30146, 26869).

%% Combined state change (single BLE connection, most efficient)
myhome_hue_ble:set_state(bulb_1, #{power => true, brightness => 254, color_temp => 370}).

%% Read actual bulb state via BLE (connects on-demand)
myhome_hue_ble:read_state(bulb_1).
%% => {ok, #{power => true, brightness => 200, color_temp => 370, color_xy => {30146, 26869}}}

%% Read cached state (no BLE connection)
myhome_hue_ble:get_state(bulb_1).
```

```bash
# Check status
curl http://<esp-ip>:8080/api/status

# Power on bulb 1
curl -X POST http://<esp-ip>:8080/api/bulb/1/power -d '{"on":true}'

# Set brightness (1-254)
curl -X POST http://<esp-ip>:8080/api/bulb/1/brightness -d '{"value":200}'

# Set color temperature (153-500 mirek, higher = warmer)
# 153 = cool daylight (6500K), 370 = neutral (2700K), 454 = candle (2200K)
curl -X POST http://<esp-ip>:8080/api/bulb/1/color_temp -d '{"value":370}'

# Set color via CIE 1931 XY chromaticity (0-65535, where 65535 = 1.0)
# Useful for saturated colors that can't be expressed as white temperature
curl -X POST http://<esp-ip>:8080/api/bulb/1/color_xy -d '{"x":30146,"y":26869}'

# Read actual bulb state (connects via BLE, reads GATT characteristics)
curl http://<esp-ip>:8080/api/bulb/1/state
# => {"status":"ok","power":true,"brightness":200,"color_temp":370,"color_x":30146,"color_y":26869}

# Set multiple properties at once
curl -X POST http://<esp-ip>:8080/api/bulb/1/state \
  -d '{"power":true,"brightness":200,"color_temp":370}'

# Scan for nearby BLE devices (blocks until scan completes)
curl -X POST http://<esp-ip>:8080/api/scan -d '{"duration":10}'

# Get last scan results
curl http://<esp-ip>:8080/api/scan

# Pretty print scan result
curl -s http://<esp-ip>:8080/api/scan | jq -r '.scan.results[] | select(.name != "") | "\(.addr) rssi=\(.rssi) \(.name)"'

# Trigger discovery and pairing of new Hue bulbs
curl -X POST http://<esp-ip>:8080/api/discover

# View system logs (newest first)
curl http://<esp-ip>:8080/api/logs

# Pretty printed as oneliners
curl http://<esp-ip>:8080/api/logs | jq -r '.logs[] | "\(.ts) [\(.level)] \(.msg)"'

# Filter logs by level
curl http://<esp-ip>:8080/api/logs?level=error

# Limit number of entries
curl http://<esp-ip>:8080/api/logs?limit=20

# 1. Factory-reset bulbs (power-cycle 5x) so they enter pairing mode
# 2. Then clear ESP32 bonds + config and reboot:
curl -X POST http://192.168.1.115:8080/api/reset
```


## Color Control

The Hue bulbs support two color modes: **color temperature** (Mirek) for
white tones, and **CIE XY** for full-gamut saturated colors.

### Color Temperature (Mirek)

The Mirek scale (also called "mired") is the standard unit for correlated
color temperature. It is the inverse of Kelvin, scaled by 1,000,000:

$$Mirek = \frac{1{,}000{,}000}{Kelvin}$$

The Hue BLE protocol accepts values **153–500**. Higher values = warmer light.

| Mirek | Kelvin | Description |
|-------|--------|-------------|
| 153   | 6500K  | Cool daylight (bluish white) |
| 250   | 4000K  | Neutral white (office lighting) |
| 370   | 2700K  | Warm white (standard incandescent) |
| 454   | 2200K  | Candle / sunset |
| 500   | 2000K  | Warmest (deep amber) |

```bash
curl -X POST http://<esp-ip>:8080/api/bulb/1/color_temp -d '{"value":454}'
```

### CIE 1931 XY Chromaticity

For saturated colors (red, green, blue, purple, etc.) that cannot be
expressed as a white temperature, use the XY endpoint. X and Y are
coordinates on the CIE 1931 chromaticity diagram:

- **X** = red–green axis (higher = more red/orange)
- **Y** = luminance/green axis (higher = more green/yellow)

Standard CIE values range 0.0–1.0. The Hue protocol scales them to
integers 0–65535:

$$X_{hue} = X_{cie} \times 65535$$

| Color              | CIE (x, y) | Hue API (x, y) |
|--------------------|------------|----------------|
| Warm white (2700K) | 0.46, 0.41 | 30146, 26869   |
| Candle (2000K).    | 0.53, 0.41 | 34734, 26869   |
| Saturated red      | 0.68, 0.32 | 44564, 20971   |
| Saturated green    | 0.21, 0.71 | 13762, 46530   |
| Saturated blue     | 0.15, 0.06 | 9830, 3932     |
| Purple / magenta   | 0.32, 0.15 | 20971, 9830    |
| Orange             | 0.58, 0.38 | 38010, 24903   |
| D65 daylight white | 0.31, 0.33 | 20316, 21627   |

```bash
# Saturated red
curl -X POST http://<esp-ip>:8080/api/bulb/1/color_xy -d '{"x":44564,"y":20971}'

# Purple
curl -X POST http://<esp-ip>:8080/api/bulb/1/color_xy -d '{"x":20971,"y":9830}'
```

> **Tip:** For everyday warm/cool white lighting, use `color_temp` — it's
> simpler and designed for white tones. Use `color_xy` when you want actual
> colors (party mode, accent lighting, etc.).


## Re-pairing

You can trigger re-discovery via the HTTP API without rebooting:

```bash
# Power-cycle bulbs first, then:
curl -X POST http://<esp-ip>:8080/api/discover
```

Or clear NVS and reboot to start fresh:

```erlang
esp:nvs_erase_all(myhome).
esp:restart().
```

## Troubleshooting

### `ATT_ERR_INSUFFICIENT_AUTHENTICATION` (error code 5)

GATT writes are rejected because the connection is not encrypted/bonded.

**Symptoms:**
- `{"reason": "{ble_error,<<5>>}", "status": "error"}` from HTTP API
- Serial log shows `encryption change: handle=N status=1285`
- Discovery reports "connected (bond pending)" instead of "bonded!"

**Causes:**
1. The bulb is already bonded to another device (phone/tablet). Hue BLE
   bulbs only support one bond at a time.
2. The bulb was not in pairing mode during discovery.

**Fix:**
1. Remove the bulbs from the Hue Bluetooth app on your phone (if paired).
2. Factory-reset the bulbs: rapidly power-cycle 5 times (on ~1s, off ~1s).
   The bulb flashes to confirm the reset.
3. Rebuild and flash firmware + app: `make flash`
4. The bulbs enter pairing mode for ~30s after reset — the ESP32 will
   discover and bond them automatically.

### Timeout errors on first GATT write

The first write to a bulb after connection takes longer (~5-10s) because
NimBLE performs GATT service discovery to resolve characteristic handles.

**Symptoms:**
- `{timeout, {gen_server, call, ...}}` on first command
- Subsequent commands work fine

**Fix:** This is expected on the first write after connection. The API uses
a 15-second timeout to accommodate this. If you still see timeouts, check
that the bulb is within BLE range.

### Serial port busy during flash

```
Could not open /dev/cu.usbmodemXXX, the port is busy
```

Close minicom (or any serial monitor) before flashing:
```bash
pkill minicom
make flash-app
```

### WiFi beacon timeouts

```
WIFI_EVENT_STA_BEACON_TIMEOUT received
```

The ESP32 is losing WiFi signal. This can happen when BLE and WiFi are
active simultaneously (they share the radio). Move the ESP32 closer to
the WiFi access point, or reduce BLE activity.

## Project Structure

```
├── Makefile                  Build automation (make help)
├── rebar.config              Erlang build config
├── sdkconfig.defaults        NimBLE Kconfig settings
├── src/
│   ├── myhome_app.erl        Application entry point (start/0)
│   ├── myhome_top_sup.erl    Top-level supervisor (rest_for_one)
│   ├── myhome_log.erl        In-memory log server (ring buffer via queue)
│   ├── ble.erl               BLE port server (owns port, serializes commands)
│   ├── myhome_event_bus.erl  Pub/sub event bus for BLE events
│   ├── myhome_sup.erl        Secondary supervisor (one_for_one)
│   ├── myhome_scanner.erl    On-demand BLE device scanner
│   ├── myhome_ble_conn.erl   Connection state machine + sync connect
│   ├── myhome_http.erl       WiFi connection + HTTP listener
│   ├── myhome_http_handler.erl  HTTP API request routing
│   ├── myhome_discovery.erl  BLE pairing + dynamic bulb startup
│   ├── myhome_hue_ble.erl    Per-bulb gen_server, Hue BLE protocol
│   ├── tiny_httpd.erl        Minimal HTTP/1.1 server (no deps)
│   └── tiny_json.erl         Lightweight JSON encoder/decoder
├── nifs/ble/
│   ├── CMakeLists.txt         ESP-IDF component build
│   ├── include/ble_port.h     Port driver header
│   └── ble_port.c            NimBLE port driver (scan/connect/GATT)
└── plans/
    └── philips_hue_control.md Detailed implementation plan
```

## References

[BLE](https://learn.adafruit.com/introduction-to-bluetooth-low-energy/introduction)

[hello_atomvm_ble_switchbot](https://github.com/piyopiyoex/hello_atomvm_ble_switchbot)

## License

Apache-2.0

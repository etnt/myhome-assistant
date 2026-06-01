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
  │     ├── myhome_scanner ──BLE scan──► all nearby devices
  │     └── myhome_sup (one_for_one)
  │           ├── myhome_http (WiFi + HTTP API)
  │           ├── myhome_discovery (pairing + bulb startup)
  │           ├── bulb_1 (gen_server) ──BLE──► Hue Bulb 1
  │           └── bulb_2 (gen_server) ──BLE──► Hue Bulb 2
  └── ble_port (C, NimBLE)
```

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

%% Set warm white (higher = warmer, 0-255)
myhome_hue_ble:set_color_temp(bulb_1, 244).

%% Combined state change (single BLE write, most efficient)
myhome_hue_ble:set_state(bulb_1, #{power => true, brightness => 254, color_temp => 200}).

%% Read current state from bulb
myhome_hue_ble:get_state(bulb_1).
```

```bash
# Check status
curl http://<esp-ip>:8080/api/status

# Power on bulb 1
curl -X POST http://<esp-ip>:8080/api/bulb/1/power -d '{"on":true}'

# Set brightness (1-254)
curl -X POST http://<esp-ip>:8080/api/bulb/1/brightness -d '{"value":200}'

# Set color temperature (0-255, warm to cool)
curl -X POST http://<esp-ip>:8080/api/bulb/1/color_temp -d '{"value":153}'

# Set multiple properties at once
curl -X POST http://<esp-ip>:8080/api/bulb/1/state -d '{"power":true,"brightness":200,"color_temp":100}'

# Scan for nearby BLE devices (blocks until scan completes)
curl -X POST http://<esp-ip>:8080/api/scan -d '{"duration":10}'

# Get last scan results
curl http://<esp-ip>:8080/api/scan

# Trigger discovery and pairing of new Hue bulbs
curl -X POST http://<esp-ip>:8080/api/discover
```


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
│   ├── myhome_sup.erl        Secondary supervisor (one_for_one)
│   ├── myhome_http.erl       WiFi connection + HTTP server
│   ├── myhome_scanner.erl    On-demand BLE device scanner
│   ├── myhome_discovery.erl  BLE pairing + dynamic bulb startup
│   ├── myhome_hue_ble.erl    Per-bulb gen_server, Hue BLE protocol
│   ├── myhome_http_handler.erl  HTTP API request handler
│   └── ble.erl               Erlang wrapper for BLE port driver
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

# MyHome Assistant

Control Philips Hue Bluetooth light bulbs directly from an ESP32-S3 running
AtomVM/Erlang. No Hue Bridge required — communicates via BLE GATT.

## Hardware

- ESP32-S3 development board
- Philips Hue Bluetooth bulbs (2019+ models with built-in BLE)

## Architecture

```
ESP32-S3 (AtomVM/Erlang)
  ├── ble_port (C, NimBLE) ──BLE──► Hue Bulb 1
  ├── myhome_hue_ble (gen_server)
  └── myhome_hue_ble (gen_server) ──BLE──► Hue Bulb 2
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
2. The ESP32 scans for BLE devices with "Hue" in their name
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
```


## Re-pairing

If a bulb is factory-reset or paired to another device, clear NVS and reboot:

```erlang
esp:nvs_erase_all(myhome).
esp:restart().
```

## Project Structure

```
├── Makefile                  Build automation (make help)
├── rebar.config              Erlang build config
├── sdkconfig.defaults        NimBLE Kconfig settings
├── src/
│   ├── myhome_app.erl        Application entry point (start/0)
│   ├── myhome_sup.erl        Supervisor (one_for_one)
│   ├── myhome_hue_ble.erl    Per-bulb gen_server, Hue BLE protocol
│   ├── myhome_discovery.erl  BLE scanning & pairing flow
│   └── ble.erl               Erlang wrapper for BLE port driver
├── nifs/ble/
│   ├── CMakeLists.txt         ESP-IDF component build
│   ├── include/ble_port.h     Port driver header
│   └── ble_port.c            NimBLE port driver (scan/connect/GATT)
└── plans/
    └── philips_hue_control.md Detailed implementation plan
```

## License

Apache-2.0

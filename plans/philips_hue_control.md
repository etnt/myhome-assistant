# Plan: Philips Hue Light Bulb Control via Bluetooth LE

## Overview

Control two Philips Hue Bluetooth light bulbs directly from an ESP32-S3
running AtomVM/Erlang, using Bluetooth Low Energy (BLE). No Hue Bridge required.

## Architecture

```
 ┌─────────────────┐        BLE/GATT         ┌──────────┐
 │  ESP32-S3       │ ◄─────────────────────► │  Bulb 1  │
 │  (AtomVM/Erlang)│                          └──────────┘
 │                 │        BLE/GATT         ┌──────────┐
 │                 │ ◄─────────────────────► │  Bulb 2  │
 └─────────────────┘                          └──────────┘
```

- Newer Philips Hue bulbs (2019+) have built-in Bluetooth LE radios.
- The ESP32-S3 connects directly to each bulb via BLE GATT, acting as a central.
- No bridge, no WiFi required for light control (WiFi optional for future remote access).

## Hue BLE Protocol (Reverse-Engineered)

The protocol uses standard BLE GATT services and characteristics. It has been
reverse-engineered by the community (see references at end).

### Key GATT Services

| Service UUID | Purpose |
|-------------|---------|
| `932c32bd-0000-47a2-835a-a8d455b859dd` | Light control |
| `0000fe0f-0000-1000-8000-00805f9b34fb` | Device configuration |
| `0000180a-0000-1000-8000-00805f9b34fb` | Device information (standard) |

### Light Control Characteristics (Service `932c32bd-0000-...`)

| UUID suffix | Purpose | Read/Write |
|-------------|---------|------------|
| `0002` | Power state (0x01=on, 0x00=off) | R/W |
| `0003` | Brightness (1-254) | R/W |
| `0004` | Color temperature (2 bytes: temp + enable flag) | R/W |
| `0005` | Color XY | R/W |
| `0006` | Effect/flash mode | W |
| `0007` | Combined control (multi-command in one write) | W |
| `1005` | Power-on default state | R/W |

### Combined Control Protocol (Characteristic `0007`)

Commands are type-length-value (TLV) sequences that can be concatenated:

| Type | Length | Value | Meaning |
|------|--------|-------|---------|
| `0x01` | `0x01` | `0x01` or `0x00` | Power on / off |
| `0x02` | `0x01` | `0x01`-`0xFE` | Set brightness |
| `0x03` | `0x02` | `<temp> <enable>` | Color temp (higher=warmer, enable: 0x01/0x00) |
| `0x04` | `0x04` | `<X_hi> <X_lo> <Y_hi> <Y_lo>` | CIE XY color |

Examples:
- Turn on: `<<16#01, 16#01, 16#01>>`
- Turn off: `<<16#01, 16#01, 16#00>>`
- Set brightness to 200: `<<16#02, 16#01, 16#C8>>`
- Turn on + set brightness 254 + warm white: `<<16#01,16#01,16#01, 16#02,16#01,16#FE, 16#03,16#02,16#F4,16#01>>`

### Device Configuration Characteristics (Service `0000fe0f-...`)

| UUID | Purpose | Read/Write |
|------|---------|------------|
| `97fe6561-0001-4f62-86e9-b71ee2da3d22` | Zigbee MAC address | R |
| `97fe6561-0003-4f62-86e9-b71ee2da3d22` | User-defined name | R/W |
| `97fe6561-0004-4f62-86e9-b71ee2da3d22` | Factory reset (write 0x01) | W |

### Device Information (Standard BLE Service `0000180a-...`)

| UUID | Purpose |
|------|---------|
| `00002a28-...` | Firmware version |
| `00002a24-...` | Model number |
| `00002a29-...` | Manufacturer name |

### Pairing

Before first connection, the bulb must be in pairing mode:
1. Turn the bulb off and on again (power cycle) — it enters pairing mode for ~30s.
2. Or: if previously paired, factory reset by power-cycling 5 times (3s on, 3s off).
3. The ESP32-S3 initiates BLE bonding during the pairing window.
4. Once bonded, the bulb remembers the ESP32 and reconnects automatically.

## Implementation Plan

### Phase 1: BLE NIF Component (C)

**Critical path**: AtomVM does NOT have native BLE support. We must write a
custom AtomVM component (NIF) in C that wraps ESP-IDF's NimBLE stack.

**Directory:** `nifs/ble/`

The NIF exposes these operations to Erlang:

```erlang
%% Scan for BLE devices
-spec ble:scan(Timeout :: integer()) -> {ok, [#{addr => binary(), name => binary(), rssi => integer()}]}.

%% Connect to a device by address
-spec ble:connect(Addr :: binary()) -> {ok, ConnHandle} | {error, Reason}.

%% Disconnect
-spec ble:disconnect(ConnHandle) -> ok.

%% Read a GATT characteristic
-spec ble:read(ConnHandle, ServiceUUID :: binary(), CharUUID :: binary()) -> {ok, binary()} | {error, Reason}.

%% Write a GATT characteristic
-spec ble:write(ConnHandle, ServiceUUID :: binary(), CharUUID :: binary(), Value :: binary()) -> ok | {error, Reason}.

%% Subscribe to notifications on a characteristic
-spec ble:subscribe(ConnHandle, ServiceUUID :: binary(), CharUUID :: binary()) -> ok | {error, Reason}.
```

Implementation approach:
1. Use ESP-IDF's NimBLE host stack (lighter than Bluedroid, better for constrained devices)
2. Implement as an AtomVM port or NIF (port preferred for async operations)
3. BLE events (scan results, connect/disconnect, notifications) delivered as Erlang messages to the calling process
4. Handle bonding/pairing at the C level, persist bond info in NVS

**Build integration:** Add as a component in the AtomVM build via `CMakeLists.txt` and `Kconfig`, similar to how `atomvm_lib` components work.

### Phase 2: Hue BLE Light Driver (Erlang)

**Module:** `myhome_hue_ble`

A `gen_server` per bulb that manages the BLE connection and provides the control API.

```erlang
%% Start a light controller for a specific bulb address
-spec start_link(Addr :: binary(), Name :: atom()) -> {ok, pid()}.

%% Power control
-spec set_power(Name :: atom(), On :: boolean()) -> ok | {error, term()}.

%% Brightness (1-254)
-spec set_brightness(Name :: atom(), Bri :: 1..254) -> ok | {error, term()}.

%% Color temperature (larger value = warmer)
-spec set_color_temp(Name :: atom(), Temp :: 0..255) -> ok | {error, term()}.

%% XY color
-spec set_color_xy(Name :: atom(), X :: 0..65535, Y :: 0..65535) -> ok | {error, term()}.

%% Combined state change (most efficient — single BLE write)
-spec set_state(Name :: atom(), State :: map()) -> ok | {error, term()}.

%% Read current state
-spec get_state(Name :: atom()) -> {ok, map()} | {error, term()}.
```

The gen_server:
- Connects to the bulb on init (with retry/backoff)
- Reconnects automatically on disconnect
- Batches rapid state changes using the combined control characteristic (`0007`)
- Caches last-known state from reads/notifications

### Phase 3: Application Structure

**Module:** `myhome_app` (entry point, exports `start/0`)

```
myhome_app (start/0)
  └── myhome_sup (supervisor)
        ├── myhome_hue_ble (gen_server, bulb 1)
        └── myhome_hue_ble (gen_server, bulb 2)
```

Since AtomVM supports `gen_server` and `supervisor`, we use OTP patterns.

Configuration (bulb addresses, names) stored in NVS or compiled into the app.

### Phase 4: Discovery & Initial Setup

**Module:** `myhome_discovery`

One-time setup flow:

1. Scan for BLE devices advertising the Hue service UUID (`0000fe0f-...`)
2. Display discovered bulbs (via serial console / UART)
3. User confirms which bulbs to pair with
4. Initiate bonding with each bulb (bulb must be in pairing mode)
5. Store bonded device addresses in NVS

After initial setup, the app connects directly using stored addresses.

### Phase 5: Optional WiFi & Remote Access

**Module:** `myhome_network` (future)

- Connect ESP32-S3 to WiFi for remote control capabilities
- Serve a minimal HTTP API or accept MQTT commands
- Not required for basic local BLE light control

## Module Summary

| Module | Language | Responsibility |
|--------|----------|---------------|
| `ble` (NIF) | C | BLE GAP/GATT operations via NimBLE |
| `myhome_app` | Erlang | Application entry point (`start/0`) |
| `myhome_hue_ble` | Erlang | Per-bulb gen_server, Hue BLE protocol |
| `myhome_discovery` | Erlang | BLE scanning, pairing, NVS storage |

## Configuration Storage (NVS)

| Namespace | Key | Value |
|-----------|-----|-------|
| `myhome` | `bulb_1_addr` | BLE MAC address of bulb 1 (6-byte binary) |
| `myhome` | `bulb_1_name` | User-friendly name |
| `myhome` | `bulb_2_addr` | BLE MAC address of bulb 2 (6-byte binary) |
| `myhome` | `bulb_2_name` | User-friendly name |

Bond information is managed by NimBLE's own NVS storage automatically.

## Build & Deploy

### Project Structure

```
myhome-assistant/
├── rebar.config
├── src/                      # Erlang source
│   ├── myhome_app.erl
│   ├── myhome_hue_ble.erl
│   └── myhome_discovery.erl
├── nifs/
│   └── ble/                  # BLE NIF component
│       ├── CMakeLists.txt
│       ├── Kconfig
│       └── nif_ble.c
└── plans/
```

### Build Steps

1. Build a custom AtomVM firmware that includes the BLE NIF component
2. Flash the custom AtomVM image to the ESP32-S3
3. `rebar3 compile` — compile Erlang sources
4. `rebar3 atomvm packbeam` — create AVM file
5. `rebar3 atomvm esp32_flash` — flash application to ESP32-S3

### Custom AtomVM Build

Since we need a NIF, we must build AtomVM from source with our component:

```bash
git clone https://github.com/atomvm/AtomVM.git
cd AtomVM/src/platforms/esp32
# Add our BLE component to the build
# Link or copy nifs/ble/ into components/
idf.py set-target esp32s3
idf.py build
idf.py flash
```

## Risks & Considerations

- **BLE NIF complexity**: Writing the NIF is the hardest part. NimBLE's async event model must be bridged to Erlang's message-passing model carefully.
- **BLE connection limit**: ESP32-S3 can maintain ~3-9 simultaneous BLE connections. Two bulbs is well within limits.
- **Pairing fragility**: If the bulb is factory-reset or paired to a phone, the ESP32 bond is lost and re-pairing is needed.
- **BLE range**: Typical BLE range is 10-30m indoors. Ensure the ESP32 is positioned within range of both bulbs.
- **AtomVM NIF stability**: Custom NIFs must be careful with memory — avoid leaking resources when Erlang processes crash.
- **No official Hue BLE docs**: The protocol is reverse-engineered. Firmware updates to the bulbs could break things (unlikely for basic on/off/brightness).
- **Single-connection per bulb**: A Hue Bluetooth bulb only accepts one BLE connection at a time. The Hue phone app won't be able to control bulbs while the ESP32 is connected (can disconnect temporarily to allow app access).

## References

- [Hue BLE GATT Services & Characteristics](https://gist.github.com/shinyquagsire23/f7907fdf6b470200702e75a30135caf3) — reverse-engineered protocol
- [HueBLE (Python)](https://github.com/flip-dots/HueBLE) — active Python library using Bleak
- [philble (Python)](https://github.com/npaun/philble) — earlier Python BLE client
- [ESP-IDF NimBLE Guide](https://docs.espressif.com/projects/esp-idf/en/latest/esp32s3/api-reference/bluetooth/nimble/index.html)
- [AtomVM Components](https://github.com/atomvm/atomvm_lib/blob/master/markdown/components.md)

## Future Extensions

- Physical button/switch input via GPIO to toggle lights
- Motion sensor (PIR) integration for automatic on/off
- Time-based schedules (sunrise/sunset dimming using BLE schedule characteristic)
- WiFi + MQTT for remote control from phone/computer
- Web UI served from the ESP32 (AP mode) for configuration
- Support for more bulbs (up to BLE connection limit)
- Light scenes and presets stored in NVS

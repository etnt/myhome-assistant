# Two-Chip Architecture Plan

Eliminate WiFi/BLE radio contention by offloading Zigbee communication to a
dedicated ESP32-H2 radio worker, connected to the existing ESP32-S3 brain
via UART.

## Motivation

The current single-chip (ESP32-S3) design shares a single 2.4 GHz radio
between WiFi and BLE. This causes:
- Beacon timeouts during BLE operations
- Connection failures after overnight idle (slow BLE advertisers + WiFi coex)
- Serialized bulb commands (only one BLE op at a time)

Moving to Zigbee on a dedicated chip solves all three: the H2's 802.15.4
radio never contends with WiFi, and Zigbee mesh supports concurrent devices.

## System Architecture

```
   +-------------------------+              +------------------------+
   |    Development PC       |              |   Zigbee End Devices   |
   |   (minicom @ 115200)    |              |  (Hue, Aqara, IKEA)    |
   +-----------+-------------+              +-----------+------------+
               |                                        |
               | USB (UART0 console)                    | 802.15.4 (Zigbee)
               v                                        v
   +-------------------------+  UART1 (115200)  +------------------------+
   |       ESP32-S3          |<================>|       ESP32-H2         |
   |     "The Brain"         |  GPIO17=TX       |   "Radio Worker"       |
   |                         |  GPIO18=RX       |                        |
   |  - AtomVM/Erlang        |                  |  - ESP-Zigbee SDK (C)  |
   |  - WiFi + HTTP API      |                  |  - Zigbee Coordinator  |
   |  - Web UI               |                  |  - Custom UART framing |
   |  - Event bus            |                  |  - Device table in RAM |
   |  - Supervision tree     |                  |  - No WiFi stack       |
   +-------------------------+                  +------------------------+
```

## Hardware

### Bill of Materials

| Qty | Component | Notes |
|-----|-----------|-------|
| 1 | ESP32-S3 dev board | Already in use (the brain) |
| 1 | ESP32-H2 dev board | Dedicated Zigbee coordinator |
| 4 | Dupont jumper wires | TX, RX, VCC, GND |
| 1 | USB-C cable | For flashing the H2 (only during development) |

### Wiring

| Signal | ESP32-S3 Pin | Dir | ESP32-H2 Pin | Notes |
|--------|-------------|-----|-------------|-------|
| GND | GND | ↔ | GND | Common ground (required) |
| VCC | 3V3 | → | 3V3 | Power from S3 regulator |
| S3_TX | GPIO 17 | → | GPIO 4 (RX) | S3 sends commands to H2 |
| S3_RX | GPIO 18 | ← | GPIO 5 (TX) | H2 sends events to S3 |

> **Note:** Verify your H2 board's UART1 default pins. On the ESP32-H2-DevKitM-1,
> UART0 (GPIO 23/24) is the USB console; use UART1 (GPIO 4/5) for the link.
> Power via 3V3 pin avoids needing a separate USB connection in production.

## Software Architecture (ESP32-S3 Side)

Follows the same pattern as the existing `ble.erl` port server — a gen_server
owns the UART port, serializes commands, and publishes events to the event bus.

### Supervision Tree (Extended)

```
myhome_top_sup (rest_for_one)
  ├── myhome_log
  ├── ble (existing — kept for BLE-only devices)
  ├── zigbee (NEW — owns UART port to H2)
  ├── myhome_event_bus
  └── myhome_sup (one_for_one)
        ├── myhome_scanner
        ├── myhome_ble_conn
        ├── myhome_zigbee_devices (NEW — per-device state)
        ├── myhome_http
        ├── myhome_discovery
        └── myhome_sensors
```

### New Module: `zigbee.erl`

```erlang
-module(zigbee).
-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([permit_join/1, send_cmd/3, get_devices/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    port     :: port(),
    seq = 0  :: non_neg_integer(),  %% frame sequence number
    pending  :: #{non_neg_integer() => {gen_server:from(), reference()}}
}).

-define(UART_TIMEOUT, 5000).
-define(FRAME_START, 16#AA).
-define(FRAME_END,   16#55).

init([]) ->
    Port = uart:open([
        {peripheral, "UART1"},
        {tx, 17},
        {rx, 18},
        {speed, 115200},
        {data_bits, 8},
        {stop_bits, 1},
        {parity, none},
        {flow_control, none}
    ]),
    %% Start receive loop
    self() ! poll_uart,
    {ok, #state{port = Port, pending = #{}}}.
```

### UART Frame Protocol (S3 ↔ H2)

Simple length-prefixed binary frames to avoid parsing ambiguity:

```
┌──────┬──────┬────────┬─────────────┬─────┬──────┐
│ 0xAA │ Len  │ SeqNum │   Payload   │ CRC │ 0x55 │
│ (1B) │ (2B) │  (1B)  │ (0-1024B)   │ (1B)│ (1B) │
└──────┴──────┴────────┴─────────────┴─────┴──────┘
```

| Field | Size | Description |
|-------|------|-------------|
| Start | 1 | `0xAA` — frame delimiter |
| Len | 2 | Little-endian payload length |
| Seq | 1 | Sequence number (for request/response correlation) |
| Payload | N | Command or event (see below) |
| CRC | 1 | XOR of all bytes from Len through Payload |
| End | 1 | `0x55` — frame terminator |

### Command Payloads (S3 → H2)

| Cmd ID | Name | Payload | Description |
|--------|------|---------|-------------|
| 0x01 | PERMIT_JOIN | `<<Duration:8>>` | Open network for N seconds |
| 0x02 | SEND_CMD | `<<ShortAddr:16, EP:8, Cluster:16, CmdId:8, Data/bin>>` | Send ZCL command |
| 0x03 | GET_DEVICES | (empty) | Request device list |
| 0x04 | REMOVE_DEVICE | `<<ShortAddr:16>>` | Remove from network |
| 0x05 | BIND | `<<ShortAddr:16, EP:8, Cluster:16>>` | Set up reporting |
| 0x10 | PING | (empty) | Liveness check |
| 0xFF | RESET | (empty) | Reboot the H2 |

### Event Payloads (H2 → S3)

| Evt ID | Name | Payload | Description |
|--------|------|---------|-------------|
| 0x81 | DEVICE_JOINED | `<<ShortAddr:16, IEEE:8B, EP:8>>` | New device paired |
| 0x82 | DEVICE_LEFT | `<<ShortAddr:16>>` | Device left network |
| 0x83 | ATTRIBUTE_REPORT | `<<ShortAddr:16, EP:8, Cluster:16, AttrId:16, Data/bin>>` | Sensor/state update |
| 0x84 | CMD_RESPONSE | `<<Seq:8, Status:8>>` | Ack for a command |
| 0x90 | PONG | `<<Version:8, Devices:8>>` | Reply to PING |
| 0x91 | READY | (empty) | H2 booted and coordinator started |

## Software Architecture (ESP32-H2 Side)

The H2 runs ESP-IDF + ESP-Zigbee SDK (C). **Not** Z-Stack/EZSP — those are
for TI/Silicon Labs chips. Key components:

```
ESP32-H2 Firmware
  ├── main.c              — init UART + Zigbee stack
  ├── zigbee_coordinator.c — network formation, device management
  ├── uart_protocol.c     — frame parsing, command dispatch
  └── device_table.c      — track joined devices (short addr, IEEE, endpoints)
```

### H2 Responsibilities

1. **Form Zigbee network** on boot (channel 15 or auto-scan)
2. **Accept join requests** when PERMIT_JOIN is active
3. **Route ZCL commands** from UART to devices
4. **Forward attribute reports** from devices to UART
5. **Maintain device table** in RAM (rebuilt on rejoin)
6. **Watchdog** — reboot if no PING received within 60s

### H2 Firmware Source

Uses Espressif's `esp-zigbee-sdk` (Apache-2.0):

```bash
# Clone and build H2 coordinator firmware
cd nifs/zigbee_h2
idf.py set-target esp32h2
idf.py build
idf.py -p /dev/cu.usbmodemXXX flash
```

## Integration with Existing Codebase

### Phase 1: UART Bridge (Week 1)

- Add `zigbee.erl` gen_server to `myhome_top_sup`
- Implement frame encode/decode
- H2 firmware: UART echo + PING/PONG
- Verify bidirectional communication

### Phase 2: Zigbee Coordinator (Week 2-3)

- H2 firmware: form network, handle joins
- `zigbee.erl`: PERMIT_JOIN, DEVICE_JOINED events
- `myhome_zigbee_devices.erl`: track device state
- HTTP endpoints: `POST /api/zigbee/permit_join`, `GET /api/zigbee/devices`

### Phase 3: Device Control (Week 3-4)

- ZCL on/off cluster (lights)
- ZCL level control (brightness)
- ZCL color control (color temp, XY)
- Map to existing HTTP API: `POST /api/bulb/{n}/power` routes to Zigbee
  when device is Zigbee-type

### Phase 4: Sensor Reporting (Week 4-5)

- Bind temperature/humidity clusters
- Forward attribute reports through event bus
- `myhome_sensors.erl` accepts both I2C (BME680) and Zigbee sources
- UI sensor cards: unified regardless of source

### Coexistence with BLE

The BLE stack remains for devices that don't support Zigbee (or during
migration). Device routing in `myhome_http_handler.erl`:

```erlang
%% Route based on device type stored in config
route_bulb_cmd(BulbNum, Cmd) ->
    case myhome_config:get_bulb_type(BulbNum) of
        ble    -> myhome_hue_ble:Cmd;
        zigbee -> myhome_zigbee_devices:Cmd
    end.
```

## Project Layout (New Files)

```
├── nifs/
│   ├── ble/                    (existing)
│   └── zigbee_h2/             (NEW — ESP-IDF project for H2)
│       ├── CMakeLists.txt
│       ├── main/
│       │   ├── main.c
│       │   ├── zigbee_coordinator.c
│       │   ├── zigbee_coordinator.h
│       │   ├── uart_protocol.c
│       │   ├── uart_protocol.h
│       │   ├── device_table.c
│       │   └── device_table.h
│       └── sdkconfig.defaults
├── src/
│   ├── zigbee.erl             (NEW — UART port server)
│   ├── myhome_zigbee_devices.erl  (NEW — per-device state)
│   └── ... (existing modules unchanged)
```

## Open Questions

1. **Channel selection** — Fixed channel 15 (avoids WiFi channels 1/6/11)
   or let the H2 auto-scan for quietest channel?
2. **OTA for H2** — Can we flash the H2 via UART from the S3, or always
   require USB connection? (ESP-IDF UART bootloader supports this)
3. **Hue bulbs on Zigbee** — Philips Hue bulbs support Zigbee 3.0.
   Once paired to our coordinator, we skip BLE entirely. Need to test
   pairing without the Hue Bridge (Touchlink commissioning).
4. **Fallback** — If H2 is unresponsive (no PONG), should the S3 fall back
   to BLE for Hue bulbs, or just report the error?

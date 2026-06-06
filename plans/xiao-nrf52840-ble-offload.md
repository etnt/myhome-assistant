# BLE Offload: Seeed Studio XIAO nRF52840

Eliminate WiFi/BLE radio contention by moving all BLE operations to a
dedicated XIAO nRF52840 module, connected to the ESP32-S3 via UART.

## Motivation

The ESP32-S3 shares a single 2.4 GHz radio between WiFi and BLE. Despite
mitigations (connect-on-demand, cooldowns, core pinning, SW coexistence),
we still experience:

- **Beacon timeouts** during BLE connections (WiFi drops)
- **OOM risk** from BLE retry storms (NimBLE stack + WiFi buffers compete
  for ~320 KB RAM)
- **Serialized operations** — only one BLE connection at a time while
  WiFi remains usable
- **Heartbeat jitter** — 5-minute polls sometimes collide with HTTP requests

A dedicated BLE chip eliminates all of these permanently.

## Why XIAO nRF52840?

| Property | Value |
|----------|-------|
| SoC | Nordic nRF52840 (the company that designed BLE) |
| BLE | Bluetooth 5.0, up to 20 simultaneous connections |
| RAM | 256 KB (plenty for BLE stack + bond storage) |
| Flash | 1 MB |
| Interfaces | UART, I2C, SPI, USB |
| Size | 21 × 17.5 mm (tiny) |
| Power | 3.3V logic, 5V input via USB or 3V3 pin |
| Antenna | Onboard PCB antenna |
| Dev support | Zephyr RTOS (Nordic's official platform) |

Nordic's BLE stack is more mature and efficient than ESP-IDF's NimBLE port.
The nRF52840 can maintain persistent connections to all bulbs simultaneously
— no more connect-on-demand dance.

## Target Architecture

```
   ESP32-S3 (AtomVM/Erlang)              XIAO nRF52840 (Zephyr)
  ┌─────────────────────────┐           ┌─────────────────────────┐
  │  WiFi only (no BLE!)    │           │  BLE only (no WiFi)     │
  │                         │   UART    │                         │
  │  myhome_ble_uart.erl ──────────────── uart_cmd_handler.c     │
  │    (gen_server)         │  115200   │                         │
  │                         │           │  ble_central.c          │
  │  myhome_event_bus       │           │    ├── scan             │
  │  myhome_http            │           │    ├── connect/bond     │
  │  myhome_hue_ble         │           │    ├── GATT read/write  │
  │  myhome_sensors (I2C)   │           │    └── notify/indicate  │
  │  myhome_rules           │           │                         │
  └────────────┬────────────┘           │  bond_store.c (flash)   │
               │                        │  device_table.c (RAM)   │
               │ I2C                    └─────────────────────────┘
               v                                    │ BLE
         BME680/VEML6030                           v
                                          Hue Bulb 1, Bulb 2, ...
```

### What Changes on ESP32-S3

| Before | After |
|--------|-------|
| NimBLE stack enabled (large RAM footprint) | **BLE disabled entirely** in sdkconfig |
| `ble.erl` owns C port driver | `myhome_ble_uart.erl` owns UART port |
| `ble_port.c` (NimBLE C code) | **Removed** — no BLE C code on S3 |
| Connect-on-demand (radio sharing) | Persistent connections (dedicated radio) |
| Cooldowns, retry limits | Not needed — BLE never interferes with WiFi |
| ~320 KB RAM (WiFi + BLE) | ~200 KB for WiFi alone → more headroom |

### What the nRF52840 Handles

- BLE scanning (device discovery)
- Connection management (connect, disconnect, reconnect)
- Pairing and bonding (SMP, stored in nRF52840 flash)
- GATT service discovery and handle caching
- GATT reads and writes (characteristics)
- Connection parameter negotiation
- Multi-connection (all bulbs connected simultaneously)

## Hardware Wiring

| Signal | ESP32-S3 Pin | Dir | XIAO nRF52840 Pin | Notes |
|--------|-------------|-----|-------------------|-------|
| GND | GND | ↔ | GND | Common ground |
| VCC | 3V3 | → | 3V3 | Power from S3 regulator |
| TX | GPIO 17 | → | D7 (RX) | Commands to nRF52840 |
| RX | GPIO 18 | ← | D6 (TX) | Events from nRF52840 |

> **Note:** The XIAO nRF52840 D6/D7 are UART1 pins. Confirm with the
> Seeed pinout diagram. Power draw is ~15 mA idle, ~20 mA during BLE
> operations — well within the ESP32-S3's 3V3 regulator capacity.

## UART Protocol

Reuse the same framing as the Zigbee plan (binary, length-prefixed):

```
┌──────┬──────┬────────┬─────────────┬─────┬──────┐
│ 0xAA │ Len  │ SeqNum │   Payload   │ CRC │ 0x55 │
│ (1B) │ (2B) │  (1B)  │ (0-512B)    │ (1B)│ (1B) │
└──────┴──────┴────────┴─────────────┴─────┴──────┘
```

- **Len**: little-endian, payload length only
- **Seq**: request/response correlation (wraps at 255)
- **CRC**: XOR of bytes from Len through end of Payload
- **Max payload**: 512 bytes (largest GATT MTU we'll encounter)

### Commands (ESP32-S3 → nRF52840)

| Cmd | ID | Payload | Description |
|-----|----|---------|-------------|
| PING | 0x01 | (empty) | Liveness check |
| SCAN_START | 0x02 | `<<Duration:8>>` | Start BLE scan (seconds) |
| SCAN_STOP | 0x03 | (empty) | Stop ongoing scan |
| CONNECT | 0x10 | `<<Addr:6B, AddrType:1>>` | Connect to device |
| DISCONNECT | 0x11 | `<<ConnHandle:2>>` | Disconnect |
| BOND | 0x12 | `<<ConnHandle:2>>` | Initiate pairing/bonding |
| GATT_DISCOVER | 0x13 | `<<ConnHandle:2>>` | Discover services + chars |
| GATT_READ | 0x20 | `<<ConnHandle:2, Handle:2>>` | Read characteristic |
| GATT_WRITE | 0x21 | `<<ConnHandle:2, Handle:2, Data/bin>>` | Write characteristic |
| GATT_WRITE_NR | 0x22 | `<<ConnHandle:2, Handle:2, Data/bin>>` | Write without response |
| SUBSCRIBE | 0x23 | `<<ConnHandle:2, Handle:2, Type:1>>` | Enable notify/indicate |
| GET_BONDS | 0x30 | (empty) | List stored bonds |
| DELETE_BOND | 0x31 | `<<Addr:6B>>` | Remove a bond |
| DELETE_ALL_BONDS | 0x32 | (empty) | Factory reset bonds |
| RESET | 0xFF | (empty) | Reboot nRF52840 |

### Events (nRF52840 → ESP32-S3)

| Event | ID | Payload | Description |
|-------|----|---------|-------------|
| PONG | 0x81 | `<<Version:8, Connections:8>>` | Reply to PING |
| READY | 0x82 | (empty) | Boot complete, stack ready |
| SCAN_RESULT | 0x83 | `<<Addr:6B, Type:1, RSSI:1s, NameLen:1, Name/bin>>` | Adv report |
| SCAN_DONE | 0x84 | (empty) | Scan duration elapsed |
| CONNECTED | 0x85 | `<<ConnHandle:2, Addr:6B>>` | Connection established |
| DISCONNECTED | 0x86 | `<<ConnHandle:2, Reason:1>>` | Connection lost |
| BOND_COMPLETE | 0x87 | `<<ConnHandle:2, Status:1>>` | Pairing result |
| GATT_SERVICES | 0x88 | `<<ConnHandle:2, Data/bin>>` | Discovery result |
| GATT_READ_RSP | 0x89 | `<<ConnHandle:2, Handle:2, Data/bin>>` | Read response |
| GATT_WRITE_RSP | 0x8A | `<<ConnHandle:2, Handle:2, Status:1>>` | Write ack |
| GATT_NOTIFY | 0x8B | `<<ConnHandle:2, Handle:2, Data/bin>>` | Notification |
| ENC_CHANGE | 0x8C | `<<ConnHandle:2, Status:1>>` | Encryption established |
| CMD_ERROR | 0xFE | `<<Seq:8, ErrorCode:1>>` | Command failed |

## Software: nRF52840 Firmware (Zephyr)

### Why Zephyr?

- Nordic's official platform for nRF52840
- Mature BLE stack (host + controller in one image)
- Up to 20 simultaneous connections
- Built-in bond storage (settings subsystem → flash)
- Well-documented Central role samples
- `west` build tool (similar to `idf.py`)

### Project Structure

```
nifs/xiao_ble/
├── CMakeLists.txt
├── prj.conf                  # Zephyr Kconfig
├── boards/
│   └── xiao_nrf52840.overlay # Pin mappings (UART, LEDs)
├── src/
│   ├── main.c                # Init UART + BLE, event loop
│   ├── uart_protocol.c       # Frame parse/build, command dispatch
│   ├── uart_protocol.h
│   ├── ble_central.c         # Scan, connect, security
│   ├── ble_central.h
│   ├── gatt_client.c         # Service discovery, read/write, notify
│   ├── gatt_client.h
│   ├── device_table.c        # Track connected devices (handle→addr map)
│   └── device_table.h
└── README.md
```

### Key Zephyr Config (`prj.conf`)

```ini
# BLE Central
CONFIG_BT=y
CONFIG_BT_CENTRAL=y
CONFIG_BT_GATT_CLIENT=y
CONFIG_BT_MAX_CONN=5
CONFIG_BT_MAX_PAIRED=5

# Security (required for Hue bulbs)
CONFIG_BT_SMP=y
CONFIG_BT_BONDABLE=y
CONFIG_BT_SETTINGS=y
CONFIG_SETTINGS=y
CONFIG_FLASH=y
CONFIG_FLASH_MAP=y
CONFIG_NVS=y

# UART
CONFIG_SERIAL=y
CONFIG_UART_INTERRUPT_DRIVEN=y

# Logging (optional, disable in production)
CONFIG_LOG=y
CONFIG_BT_LOG_LEVEL_WRN=y
```

### Firmware Behavior

1. **Boot** → init UART, init BLE stack, load bonds from flash
2. **Send READY** event to ESP32-S3
3. **Wait for commands** on UART (interrupt-driven RX)
4. **Auto-reconnect** bonded devices on boot (optional, configurable)
5. **Forward events** (connect/disconnect/notify) immediately to ESP32-S3
6. **Watchdog** — if no PING received in 30s, reboot

## Software: ESP32-S3 Side

### New Module: `myhome_ble_uart.erl`

Replaces `ble.erl` as the BLE transport. Same API surface so
`myhome_hue_ble.erl` doesn't need major changes.

```erlang
-module(myhome_ble_uart).
-behaviour(gen_server).

-export([start_link/0]).
-export([scan/1, connect/1, disconnect/1, bond/1]).
-export([gatt_read/2, gatt_write/3, gatt_write_nr/3]).
-export([subscribe/2, get_bonds/0, delete_bonds/0]).

-record(state, {
    port       :: port(),
    seq = 0    :: 0..255,
    pending    :: #{non_neg_integer() => {from(), reference()}},
    connected  :: #{conn_handle() => binary()}  %% handle → addr
}).

init([]) ->
    Port = uart:open([
        {peripheral, "UART1"},
        {tx, 17}, {rx, 18},
        {speed, 115200}
    ]),
    self() ! await_ready,
    {ok, #state{port = Port, pending = #{}, connected = #{}}}.
```

### Changes to `myhome_hue_ble.erl`

Minimal — replace calls from `ble:*` to `myhome_ble_uart:*`:

| Before | After |
|--------|-------|
| `ble:start_scan(...)` | `myhome_ble_uart:scan(Duration)` |
| `ble:connect(Addr)` | `myhome_ble_uart:connect(Addr)` |
| `ble:gatt_write(H, V)` | `myhome_ble_uart:gatt_write(ConnH, CharH, V)` |
| `ble:disconnect(H)` | `myhome_ble_uart:disconnect(ConnH)` |

Key simplification: **no more connect-on-demand**. The nRF52840 can keep
all bulbs connected persistently (dedicated radio, no WiFi contention).
The 5s idle disconnect timer in `myhome_hue_ble.erl` becomes optional.

### Changes to AtomVM Build

Remove BLE from ESP32-S3 sdkconfig entirely:

```diff
- CONFIG_BT_ENABLED=y
- CONFIG_BT_NIMBLE_ENABLED=y
- CONFIG_BT_NIMBLE_MAX_CONNECTIONS=3
+ # BLE disabled — offloaded to external nRF52840
+ CONFIG_BT_ENABLED=n
```

This frees ~80 KB of RAM on the ESP32-S3.

### Supervision Tree (Updated)

```
myhome_top_sup (rest_for_one)
  ├── myhome_log
  ├── myhome_ble_uart (NEW — owns UART port to nRF52840)
  ├── myhome_event_bus
  └── myhome_sup (one_for_one)
        ├── myhome_scanner
        ├── myhome_http
        ├── myhome_http_handler
        ├── myhome_discovery
        ├── myhome_sensors
        ├── myhome_rules
        ├── bulb_1 (persistent connection via nRF52840)
        └── bulb_2 (persistent connection via nRF52840)
```

Removed: `ble.erl`, `myhome_ble_conn.erl` (connection state machine no
longer needed — nRF52840 manages connections internally).

## Implementation Phases

### Phase 1: UART Link + Ping (1-2 days)

**Goal:** Verify bidirectional UART communication.

- [ ] Set up Zephyr dev environment (`west init`)
- [ ] Create `nifs/xiao_ble/` project with UART echo
- [ ] Implement frame encoding/decoding (both sides)
- [ ] ESP32-S3: `myhome_ble_uart.erl` with PING/PONG
- [ ] Flash XIAO, verify frames on logic analyzer or serial monitor
- [ ] Watchdog: nRF52840 reboots if no PING in 30s

### Phase 2: BLE Scan (1 day)

**Goal:** Trigger scan from ESP32-S3, receive results via UART.

- [ ] nRF52840: implement SCAN_START/SCAN_STOP + SCAN_RESULT events
- [ ] ESP32-S3: `myhome_ble_uart:scan(Duration)` → collect results
- [ ] Wire into `myhome_scanner.erl` (replace `ble:start_scan`)
- [ ] Verify via HTTP: `POST /api/scan` returns results from nRF52840

### Phase 3: Connect + Bond (2-3 days)

**Goal:** Connect to Hue bulbs and establish encrypted link.

- [ ] nRF52840: CONNECT command → `bt_conn_le_create()`
- [ ] nRF52840: BOND command → `bt_conn_set_security(BT_SECURITY_L3)`
- [ ] nRF52840: forward CONNECTED, BOND_COMPLETE, ENC_CHANGE events
- [ ] nRF52840: store bonds in flash (Zephyr settings subsystem)
- [ ] ESP32-S3: `myhome_ble_uart:connect/1`, `bond/1` APIs
- [ ] Test: connect + bond with a Hue bulb, verify enc_change success

### Phase 4: GATT Operations (2 days)

**Goal:** Read/write Hue characteristics through the UART bridge.

- [ ] nRF52840: GATT_DISCOVER → enumerate services/chars, return handles
- [ ] nRF52840: GATT_READ/GATT_WRITE → proxy to connected device
- [ ] ESP32-S3: `gatt_read/2`, `gatt_write/3` with seq correlation
- [ ] Wire into `myhome_hue_ble.erl` — replace direct BLE calls
- [ ] Test: power on/off, brightness, color_temp via nRF52840 bridge

### Phase 5: Persistent Connections + Cleanup (1-2 days)

**Goal:** Keep bulbs connected permanently, remove old BLE code.

- [ ] nRF52840: auto-reconnect bonded devices on boot
- [ ] Remove connect-on-demand logic from `myhome_hue_ble.erl`
- [ ] Remove `ble.erl`, `myhome_ble_conn.erl`, `nifs/ble/`
- [ ] Remove NimBLE from ESP32-S3 sdkconfig patch
- [ ] Remove cooldown/retry logic (no longer needed)
- [ ] Verify: WiFi never drops, heartbeat always succeeds

### Phase 6: Polish (1 day)

- [ ] Handle nRF52840 reset/crash (READY event → re-establish connections)
- [ ] HTTP endpoint: `GET /api/ble/status` (nRF52840 firmware version,
  connection count, uptime)
- [ ] Update discovery flow for new UART-based scan+bond
- [ ] Update README + architecture diagram

## Rollback Strategy

Keep `ble.erl` and `nifs/ble/` in a git branch until Phase 5 is verified
on hardware. The sdkconfig patch can re-enable NimBLE if needed.

## Open Questions

1. **GATT handle caching** — Should the nRF52840 cache discovered GATT
   handles in flash (survives reboot) or re-discover on each connect?
   Hue bulbs have fixed handles, so caching is safe and faster.

2. **Multiple connections** — How many bulbs can we keep connected
   simultaneously? Zephyr supports up to `CONFIG_BT_MAX_CONN=20`, but
   each connection uses ~1 KB RAM. Start with 5.

3. **Firmware updates** — Flash the XIAO via USB-C during development.
   For production, could implement UART DFU (Zephyr's `mcuboot` supports
   serial recovery mode).

4. **Notifications** — Should we subscribe to Hue bulb notifications
   (if any exist) for real-time state changes, or keep the heartbeat
   poll approach? Hue BLE bulbs don't advertise state changes, so
   polling remains necessary.

5. **Error recovery** — If the nRF52840 becomes unresponsive (no PONG),
   should the ESP32-S3 toggle a GPIO to hardware-reset it, or just wait?
   A dedicated reset line (ESP32 GPIO → XIAO RST pin) is cheap insurance.

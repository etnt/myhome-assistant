# BLE Offload: Seeed Studio XIAO nRF52840

Eliminate WiFi/BLE radio contention by moving all BLE operations to a
dedicated XIAO nRF52840 module, connected to the ESP32-S3 via I2C (shared
bus with SparkFun environment sensors).

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
  │                         │   I2C     │                         │
  │  myhome_ble_i2c.erl ───────────────── i2c_target_handler.c   │
  │    (gen_server)         │  0x08     │                         │
  │                         │   IRQ     │  ble_central.c          │
  │  myhome_event_bus    <──────────────── (event-ready signal)   │
  │  myhome_http            │  GPIO     │    ├── scan             │
  │  myhome_hue_ble         │           │    ├── connect/bond     │
  │  myhome_sensors (I2C)   │           │    ├── GATT read/write  │
  │  myhome_rules           │           │    └── notify/indicate  │
  └────────────┬────────────┘           │                         │
               │                        │  bond_store.c (flash)   │
               │ I2C (shared bus)       │  device_table.c (RAM)   │
               v                        └─────────────────────────┘
  ┌─────────────────────────┐                       │ BLE
  │ SparkFun Sensors (Qwiic)│                       v
  │  BME680  (0x76/0x77)    │             Hue Bulb 1, Bulb 2, ...
  │  VEML6030 (0x10)        │
  └─────────────────────────┘
```

All I2C devices share the same SDA/SCL bus. The ESP32-S3 is the sole
controller; the XIAO and sensors are targets with unique addresses.
The XIAO uses a dedicated GPIO interrupt line to signal "events pending"
since I2C targets cannot initiate transfers.

### What Changes on ESP32-S3

| Before | After |
|--------|-------|
| NimBLE stack enabled (large RAM footprint) | **BLE disabled entirely** in sdkconfig |
| `ble.erl` owns C port driver | `myhome_ble_i2c.erl` owns I2C target at 0x08 |
| `ble_port.c` (NimBLE C code) | **Removed** — no BLE C code on S3 |
| Connect-on-demand (radio sharing) | Persistent connections (dedicated radio) |
| Cooldowns, retry limits | Not needed — BLE never interferes with WiFi |
| ~320 KB RAM (WiFi + BLE) | ~200 KB for WiFi alone → more headroom |
| Sensors on separate I2C bus | Sensors share bus with XIAO (Qwiic chain) |

### What the nRF52840 Handles

- BLE scanning (device discovery)
- Connection management (connect, disconnect, reconnect)
- Pairing and bonding (SMP, stored in nRF52840 flash)
- GATT service discovery and handle caching
- GATT reads and writes (characteristics)
- Connection parameter negotiation
- Multi-connection (all bulbs connected simultaneously)

## Hardware Wiring

### I2C Bus (Shared: XIAO + SparkFun Sensors)

| Signal | ESP32-S3 Pin | Dir | XIAO nRF52840 Pin | Notes                              |
|--------|--------------|-----|-------------------|------------------------------------|
| GND    | GND          | ↔   | GND               | Common ground                      |
| VCC    | 3V3          | →   | 3V3               | Power from S3 regulator            |
| SDA    | GPIO 1       | ↔   | D4 (SDA)          | Shared I2C data                    |
| SCL    | GPIO 2       | →   | D5 (SCL)          | Shared I2C clock                   |
| IRQ    | GPIO 4       | ←   | D3 (output)       | XIAO pulls LOW when events pending |
| RST    | GPIO 5       | →   | RST               | Hardware reset (active LOW)        |

The SparkFun sensors connect to the same SDA/SCL lines via a Qwiic-to-
breadboard adapter cable:

| Qwiic Wire | Signal | Breadboard Connection        |
|------------|--------|------------------------------|
| ⬛ Black   | GND.   | Shared ground rail           |
| 🟥 Red     | 3.3V   | ESP32-S3 3V3 rail            |
| 🟦 Blue    | SDA    | Same row as GPIO 1 + XIAO D4 |
| 🟨 Yellow  | SCL    | Same row as GPIO 2 + XIAO D5 |

> **Power:** SparkFun Qwiic boards are strictly 3.3V. Connect the red
> wire to the 3.3V rail, **not** 5V/VBUS.

### I2C Address Map

| Device        | Address | Notes                                   |
|---------------|---------|-----------------------------------------|
| XIAO nRF52840 | `0x08`  | Custom firmware target address          |
| BME680        | `0x76`  | SparkFun Qwiic (alt: `0x77` via jumper) |
| VEML6030      | `0x10`  | SparkFun Qwiic ambient light sensor.    |

No address conflicts. The XIAO ignores all traffic not addressed to `0x08`.

### Pull-Up Resistors

**Do NOT add discrete pull-up resistors to the breadboard.** The SparkFun
Qwiic boards each include onboard $4.7\text{ k}\Omega$ pull-ups. With two
sensors daisy-chained, the effective bus resistance is:

$$R_{eff} = \frac{4.7\text{ k}\Omega}{2} \approx 2.35\text{ k}\Omega$$

This is the ideal sweet spot for a 3.3V I2C bus at 100–400 kHz.

If the bus becomes unstable after adding more devices (effective R drops
below $1\text{ k}\Omega$), cut the solder jumper labeled "I2C PU" on the
back of excess sensor boards to disable their pull-ups.

### Bus Speed

Start at **100 kHz** (standard mode). All devices support it reliably,
and breadboard jumper wire capacitance is not a concern at this speed.
Can upgrade to **400 kHz** (fast mode) once the prototype is stable —
the XIAO nRF52840 handles it fine, but cheap jumper wires may introduce
signal integrity issues at higher speeds.

## I2C Protocol

Since I2C is controller-initiated (the ESP32-S3 must start every transfer),
the XIAO uses a **register-based** interface combined with a **GPIO interrupt
line** (IRQ) to signal asynchronous BLE events.

### Communication Pattern

1. **Commands** (ESP32→XIAO): Controller writes to command register
2. **Responses** (XIAO→ESP32): Controller reads from response register
3. **Async Events** (XIAO→ESP32): XIAO pulls IRQ line LOW, controller
   reads event register(s) to drain the event queue

```
ESP32-S3                          XIAO nRF52840 (0x08)
    │                                    │
    │── I2C Write [REG_CMD, payload] ──→ │  (send command)
    │                                    │
    │← IRQ line goes LOW ────────────────│  (event ready)
    │                                    │
    │── I2C Read [REG_EVENT, N bytes] ──→│  (drain events)
    │                                    │
    │   (IRQ released when queue empty)  │
```

### Register Map

| Register       | Addr | R/W | Size  | Description                      |
|----------------|------|-----|-------|----------------------------------|
| REG_STATUS     | 0x00 | R   | 2B    | `<<Version:8, EventsPending:8>>` |
| REG_CMD        | 0x01 | W   | 1-64B | Command + payload                |
| REG_CMD_STATUS | 0x02 | R   | 2B    | `<<LastSeq:8, Result:8>>`        |
| REG_EVENT      | 0x10 | R   | 1-64B | Next event from queue (FIFO)     |
| REG_EVENT_LEN  | 0x11 | R   | 2B    | `<<EventType:8, PayloadLen:8>>`  |

### Commands (Written to REG_CMD)

| Cmd              | ID   | Payload                                | Description |
|------------------|------|----------------------------------------|-------------|
| PING             | 0x01 | (empty)                                | Liveness check |
| SCAN_START       | 0x02 | `<<Duration:8>>`                       | Start BLE scan (seconds) |
| SCAN_STOP        | 0x03 | (empty)                                | Stop ongoing scan |
| CONNECT          | 0x10 | `<<Addr:6B, AddrType:1>>`              | Connect to device |
| DISCONNECT       | 0x11 | `<<ConnHandle:2>>`                     | Disconnect |
| BOND             | 0x12 | `<<ConnHandle:2>>`                     | Initiate pairing/bonding |
| GATT_DISCOVER.   | 0x13 | `<<ConnHandle:2>>`                     | Discover services + chars |
| GATT_READ        | 0x20 | `<<ConnHandle:2, Handle:2>>`           | Read characteristic |
| GATT_WRITE.      | 0x21 | `<<ConnHandle:2, Handle:2, Data/bin>>` | Write characteristic |
| GATT_WRITE_NR    | 0x22 | `<<ConnHandle:2, Handle:2, Data/bin>>` | Write without response |
| SUBSCRIBE        | 0x23 | `<<ConnHandle:2, Handle:2, Type:1>>`   | Enable notify/indicate |
| GET_BONDS        | 0x30 | (empty)                                | List stored bonds |
| DELETE_BOND      | 0x31 | `<<Addr:6B>>`                          | Remove a bond |
| DELETE_ALL_BONDS | 0x32 | (empty)                                | Factory reset bonds |
| RESET            | 0xFF | (empty)                                | Reboot nRF52840 |

### Events (Read from REG_EVENT, signalled via IRQ)

| Event          | ID   | Payload                                | Description |
|----------------|------|----------------------------------------|---------------------------|
| PONG           | 0x81 | `<<Version:8, Connections:8>>`         | Reply to PING |
| READY          | 0x82 | (empty)                                | Boot complete, stack ready |
| SCAN_RESULT    | 0x83 | `<<Addr:6B, Type:1, RSSI:1s, NameLen:1, Name/bin>>` | Adv report |
| SCAN_DONE      | 0x84 | (empty)                                | Scan duration elapsed |
| CONNECTED      | 0x85 | `<<ConnHandle:2, Addr:6B>>`            | Connection established |
| DISCONNECTED   | 0x86 | `<<ConnHandle:2, Reason:1>>`           | Connection lost |
| BOND_COMPLETE  | 0x87 | `<<ConnHandle:2, Status:1>>`           | Pairing result |
| GATT_SERVICES  | 0x88 | `<<ConnHandle:2, Data/bin>>`           | Discovery result |
| GATT_READ_RSP  | 0x89 | `<<ConnHandle:2, Handle:2, Data/bin>>` | Read response |
| GATT_WRITE_RSP | 0x8A | `<<ConnHandle:2, Handle:2, Status:1>>` | Write ack |
| GATT_NOTIFY    | 0x8B | `<<ConnHandle:2, Handle:2, Data/bin>>` | Notification |
| ENC_CHANGE     | 0x8C | `<<ConnHandle:2, Status:1>>`           | Encryption established |
| CMD_ERROR      | 0xFE | `<<Seq:8, ErrorCode:1>>`               | Command failed |

### IRQ Flow

The XIAO drives the IRQ GPIO pin:
- **HIGH** (idle) — no pending events
- **LOW** — one or more events queued, ESP32 should read REG_EVENT

The ESP32-S3 configures the IRQ GPIO as an interrupt (falling edge).
On interrupt: read REG_EVENT_LEN to get type+size, then read REG_EVENT
for the payload. Repeat until REG_EVENT_LEN returns `<<0, 0>>` (empty).

### I2C Transaction Size Limit

I2C transfers should stay ≤ 64 bytes per transaction to avoid clock-
stretching issues. For larger payloads (e.g., GATT service discovery),
the XIAO splits the response into multiple events that the ESP32 reads
in sequence.

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
│   └── xiao_nrf52840.overlay # Pin mappings (I2C, IRQ, LEDs)
├── src/
│   ├── main.c                # Init I2C target + BLE, event loop
│   ├── i2c_target.c          # Register-based I2C target handler
│   ├── i2c_target.h
│   ├── event_queue.c         # FIFO event queue + IRQ signalling
│   ├── event_queue.h
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

# I2C Target Mode
CONFIG_I2C=y
CONFIG_I2C_TARGET=y

# GPIO (for IRQ output to ESP32)
CONFIG_GPIO=y

# Logging (optional, disable in production)
CONFIG_LOG=y
CONFIG_BT_LOG_LEVEL_WRN=y
```

### Firmware Behavior

1. **Boot** → init I2C target (address 0x08), init BLE stack, load bonds
2. **Assert IRQ LOW** → queue READY event, signal ESP32
3. **Wait for register reads/writes** (I2C target callbacks)
4. **Auto-reconnect** bonded devices on boot (optional, configurable)
5. **Queue events** (connect/disconnect/notify) → assert IRQ LOW
6. **Release IRQ HIGH** when event queue is drained
7. **Watchdog** — if no PING received in 30s, reboot

## Software: ESP32-S3 Side

### New Module: `myhome_ble_i2c.erl`

Replaces `ble.erl` as the BLE transport. Same API surface so
`myhome_hue_ble.erl` doesn't need major changes.

```erlang
-module(myhome_ble_i2c).
-behaviour(gen_server).

-export([start_link/0]).
-export([scan/1, connect/1, disconnect/1, bond/1]).
-export([gatt_read/2, gatt_write/3, gatt_write_nr/3]).
-export([subscribe/2, get_bonds/0, delete_bonds/0]).

-define(XIAO_ADDR, 16#08).
-define(REG_STATUS, 16#00).
-define(REG_CMD, 16#01).
-define(REG_EVENT, 16#10).
-define(REG_EVENT_LEN, 16#11).
-define(IRQ_PIN, 4).

-record(state, {
    i2c        :: pid(),
    irq_ref    :: reference(),
    pending    :: #{cmd_id() => {from(), reference()}},
    connected  :: #{conn_handle() => binary()}  %% handle → addr
}).

init([]) ->
    {ok, I2C} = i2c:open([{sda, 1}, {scl, 2}, {clock_hz, 100000}]),
    %% Configure IRQ pin as input with interrupt on falling edge
    IrqRef = gpio:set_int(?IRQ_PIN, falling),
    self() ! check_ready,
    {ok, #state{i2c = I2C, irq_ref = IrqRef, pending = #{}, connected = #{}}}.

handle_info({gpio_interrupt, ?IRQ_PIN}, State) ->
    %% XIAO has events pending — drain the event queue
    State1 = drain_events(State),
    {noreply, State1};
```

The module shares the I2C bus with `myhome_sensors.erl`. Since AtomVM's
I2C driver serializes transactions, there's no bus contention at the
software level — each `i2c:write_bytes/read_bytes` call is atomic.

### Changes to `myhome_hue_ble.erl`

Minimal — replace calls from `ble:*` to `myhome_ble_i2c:*`:

| Before                 | After                           |
|------------------------|---------------------------------|
| `ble:start_scan(...)`  | `myhome_ble_i2c:scan(Duration)` |
| `ble:connect(Addr)`    | `myhome_ble_i2c:connect(Addr)`  |
| `ble:gatt_write(H, V)` | `myhome_ble_i2c:gatt_write(ConnH, CharH, V)` |
| `ble:disconnect(H)`.   | `myhome_ble_i2c:disconnect(ConnH)` |

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
  ├── myhome_ble_i2c (NEW — owns I2C target comms to nRF52840)
  ├── myhome_event_bus
  └── myhome_sup (one_for_one)
        ├── myhome_scanner
        ├── myhome_http
        ├── myhome_http_handler
        ├── myhome_discovery
        ├── myhome_sensors (shares I2C bus — reads BME680/VEML6030)
        ├── myhome_rules
        ├── bulb_1 (persistent connection via nRF52840)
        └── bulb_2 (persistent connection via nRF52840)
```

Removed: `ble.erl`, `myhome_ble_conn.erl` (connection state machine no
longer needed — nRF52840 manages connections internally).

## Implementation Phases

### Phase 1: I2C Link + Ping (1-2 days)

**Goal:** Verify bidirectional I2C communication with IRQ signalling.

- [ ] Set up Zephyr dev environment (`west init`)
- [ ] Create `nifs/xiao_ble/` project with I2C target echo
- [ ] Implement register-based protocol (XIAO as target at 0x08)
- [ ] Implement IRQ pin toggling (XIAO D3 → ESP32 GPIO 4)
- [ ] ESP32-S3: `myhome_ble_i2c.erl` with PING/PONG
- [ ] Flash XIAO, verify register reads on logic analyzer
- [ ] Confirm sensors still respond on shared bus (0x76, 0x10)
- [ ] Watchdog: nRF52840 reboots if no PING in 30s

### Phase 2: BLE Scan (1 day)

**Goal:** Trigger scan from ESP32-S3, receive results via I2C events.

- [ ] nRF52840: implement SCAN_START/SCAN_STOP + queue SCAN_RESULT events
- [ ] ESP32-S3: `myhome_ble_i2c:scan(Duration)` → drain event queue on IRQ
- [ ] Wire into `myhome_scanner.erl` (replace `ble:start_scan`)
- [ ] Verify via HTTP: `POST /api/scan` returns results from nRF52840

### Phase 3: Connect + Bond (2-3 days)

**Goal:** Connect to Hue bulbs and establish encrypted link.

- [ ] nRF52840: CONNECT command → `bt_conn_le_create()`
- [ ] nRF52840: BOND command → `bt_conn_set_security(BT_SECURITY_L3)`
- [ ] nRF52840: queue CONNECTED, BOND_COMPLETE, ENC_CHANGE events + IRQ
- [ ] nRF52840: store bonds in flash (Zephyr settings subsystem)
- [ ] ESP32-S3: `myhome_ble_i2c:connect/1`, `bond/1` APIs
- [ ] Test: connect + bond with a Hue bulb, verify enc_change success

### Phase 4: GATT Operations (2 days)

**Goal:** Read/write Hue characteristics through the I2C bridge.

- [ ] nRF52840: GATT_DISCOVER → enumerate services/chars, queue results
- [ ] nRF52840: GATT_READ/GATT_WRITE → proxy to connected device
- [ ] ESP32-S3: `gatt_read/2`, `gatt_write/3` via REG_CMD + event drain
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
- [ ] Update discovery flow for new I2C-based scan+bond
- [ ] Verify sensor reads unaffected during BLE operations (bus sharing)
- [ ] Update README + architecture diagram

## Rollback Strategy

Keep `ble.erl` and `nifs/ble/` in a git branch until Phase 5 is verified
on hardware. The sdkconfig patch can re-enable NimBLE if needed.

## Decisions

1. **GATT handle caching** — Cache handles in nRF52840 flash. Hue bulbs
   have fixed handles, so this is safe and avoids re-discovery on reconnect.

2. **Multiple connections** — Start with `CONFIG_BT_MAX_CONN=5`. Expand
   later if needed (each connection uses ~1 KB RAM on the nRF52840).

3. **Firmware updates** — Flash both chips via USB-C during development.
   Only one USB dongle available, so flash sequentially: ESP32-S3 first,
   then move the cable to the XIAO nRF52840 (or vice versa).

4. **Notifications** — Keep the heartbeat poll approach. Hue BLE bulbs
   don't advertise state changes, so polling remains necessary.

5. **Error recovery** — Add a dedicated reset line (ESP32 GPIO → XIAO
   RST pin). If no PONG after 30s, the ESP32 toggles the reset GPIO
   to hardware-reboot the XIAO.

6. **I2C bus contention** — Keep individual transactions ≤ 64B. The ESP32
   event loop naturally interleaves sensor reads between event drains.

7. **Clock stretching** — Start at 100 kHz to minimize issues. Verify
   ESP-IDF/AtomVM tolerates stretching before bumping to 400 kHz.

8. **Additional sensors** — Monitor effective pull-up resistance if more
   Qwiic boards are added. Cut onboard jumpers if R drops below ~1 kΩ.

# Plan: IKEA Solskydd Speaker Volume Control via TV Remote + ESP32

## Overview

Intercept volume changes from an LG TV remote and relay them over BLE to an
IKEA Solskydd speaker connected via optical (S/PDIF) cable. The ESP32-S3
acts as a bridge: it monitors the TV's volume state and translates changes
into BLE GATT writes to the speaker.

## Problem

When using an optical connection for audio output, the LG TV remote's volume
keys only control the TV's internal speaker volume — they have no effect on
the external speaker. The user must physically use the speaker's own remote.

**Goal:** Make the LG TV remote volume buttons transparently control the
IKEA Solskydd speaker volume via the ESP32-S3 BLE bridge, so a single remote
controls the room volume.

## Architecture

```
 ┌──────────┐   IR/CEC    ┌──────────┐   Optical    ┌────────────────┐
 │ LG TV    │ ◄──────────  │ LG Remote│   (audio)    │ IKEA Solskydd │
 │ (webOS)  │ ────────────────────────────────────► │ (BLE speaker)  │
 └────┬─────┘              └──────────┘              └───────▲───────┘
      │                                                      │ BLE/GATT
      │  Volume state                                        │
      │  (HDMI-CEC / LG API / IR learn)                      │
      │                                                      │
 ┌────▼───────────────────────────────────────────────────────┐
 │                    ESP32-S3                                │
 │                 (AtomVM / Erlang)                          │
 │                                                            │
 │  ┌─────────────────┐     ┌──────────────────────┐          │
 │  │ Volume Monitor  │────►│ Solskydd BLE Driver  │          │
 │  │ (input source)  │     │ (GATT volume writes) │          │
 │  └─────────────────┘     └──────────────────────┘          │
 └────────────────────────────────────────────────────────────┘
```

## Volume Source Options (Pick One)

We need a way for the ESP32 to detect when the user presses volume up/down
on the TV remote. Several approaches, ordered by preference:

### Option A: HDMI-CEC (Preferred)

LG TVs support HDMI-CEC. The ESP32 can sniff CEC messages on the HDMI bus.

- **How:** Tap into the CEC line (HDMI pin 13) with an ESP32 GPIO.
  CEC is a single-wire, open-drain bus at 3.3V — GPIO-compatible.
- **Messages:** `<User Control Pressed>` opcode `0x44` with operand
  `0x41` (Volume Up) or `0x42` (Volume Down), `0x43` (Mute).
- **Pros:** No network needed; real-time; works regardless of TV model quirks.
- **Cons:** Requires physical HDMI cable tap; CEC timing is strict (400µs bit period).
- **Library:** Bit-bang CEC or use a dedicated CEC transceiver IC (e.g., TDA9950).

### Option B: IR Receiver on ESP32

Place an IR receiver (e.g., TSOP38238) connected to an ESP32 GPIO.
Decode the LG NEC IR protocol for volume up/down codes directly.

- **LG NEC codes (typical):**
  - Volume Up: Address `0x04`, Command `0x02`
  - Volume Down: Address `0x04`, Command `0x03`
  - Mute: Address `0x04`, Command `0x09`
- **Pros:** Simple hardware (one IR sensor + one GPIO); no TV software needed;
  instantaneous response; remote doesn't need line-of-sight to TV.
- **Cons:** Must be in IR line-of-sight of the remote; may conflict if TV
  also acts on the signal (can be mitigated by disabling TV internal speaker).

### Option C: LG webOS WebSocket API (Network)

LG smart TVs expose a WebSocket API (`ws://<tv-ip>:3000`) that reports
volume change events.

- **How:** ESP32 connects to WiFi, opens WebSocket to TV, subscribes to
  `ssap://audio/getVolume` with change notifications.
- **Pros:** No hardware modifications; precise volume level (0–100).
- **Cons:** Requires WiFi; adds latency; depends on TV being on network;
  webOS API may need pairing/PIN on first connect.

### Option D: Dedicated IR → ESP32 (Recommended Simplest)

Use a small IR receiver module placed near the user (not the TV) so the
ESP32 picks up the remote presses before/alongside the TV.

**Recommendation:** Start with **Option B (IR Receiver)** for simplicity,
with Option C as a future enhancement for precise level sync.

## IKEA Solskydd BLE Protocol

The IKEA Solskydd (SYMFONISK range) speakers use BLE for control.
This needs reverse-engineering / sniffing. Known starting points:

### Discovery

- Scan for BLE advertisements containing IKEA vendor data or the device name
  pattern `SOLSKYDD*` or `SYMFONISK*`.
- The speaker likely advertises a custom GATT service for media control, or
  uses the standard **Media Control Service (MCS)** / **Volume Control Service (VCS)**.

### Standard BLE Audio/Volume Services (likely candidates)

| Service | UUID | Purpose |
|---------|------|---------|
| Volume Control Service (VCS) | `0x1844` | Set/get absolute volume, mute |
| Media Control Service (MCS) | `0x1848` | Play/pause/skip (not needed here) |
| Audio Input Control Service (AICS) | `0x1843` | Input gain control |

#### VCS Characteristics (if supported)

| Characteristic | UUID | Properties | Format |
|---------------|------|-----------|--------|
| Volume State | `0x2B7D` | Read, Notify | uint8 volume (0–255), uint8 mute, uint8 change_counter |
| Volume Control Point | `0x2B7E` | Write | opcode + param |
| Volume Flags | `0x2B7F` | Read, Notify | uint8 flags |

#### VCS Control Point Opcodes

| Opcode | Parameter | Meaning |
|--------|-----------|---------|
| `0x00` | change_counter | Relative Volume Down |
| `0x01` | change_counter | Relative Volume Up |
| `0x02` | change_counter | Unmute + Relative Volume Down |
| `0x03` | change_counter | Unmute + Relative Volume Up |
| `0x04` | change_counter, volume | Set Absolute Volume |
| `0x05` | change_counter | Unmute |
| `0x06` | change_counter | Mute |

### Reverse Engineering Steps

1. **nRF Connect (phone):** Scan, connect to the speaker, enumerate services.
2. **Wireshark + nRF Sniffer:** Capture BLE traffic while using the IKEA remote
   to change volume; identify which characteristic/value changes.
3. **Document** the service UUID, characteristic UUID, and write format.

## Implementation Plan

### Phase 1: Solskydd BLE Protocol Discovery

**Goal:** Fully document the speaker's BLE GATT volume control interface.

1. Use nRF Connect (Android/iOS) to connect to the Solskydd and list all
   GATT services and characteristics.
2. Identify if VCS (`0x1844`) is present, or if IKEA uses a proprietary service.
3. Use the IKEA Home app or physical remote while sniffing BLE to capture
   volume change writes.
4. Document the exact service UUID, characteristic UUID, write format,
   and any required pairing/bonding.
5. Test manual volume control from nRF Connect (write to characteristic).

**Deliverable:** Protocol specification added to this plan.

### Phase 2: IR Receiver Driver (Erlang + NIF)

**Module:** `myhome_ir_recv`

Add an IR receiver (TSOP38238 or similar) to an ESP32 GPIO.

**NIF extension** (in `nifs/ir/`):
- Configure GPIO for IR input with RMT peripheral (ESP-IDF RMT is ideal for IR).
- Decode NEC protocol in C (or forward raw pulse timings to Erlang).
- Send decoded messages to Erlang: `{ir_key, Address, Command}`.

**Erlang module:**
```erlang
-module(myhome_ir_recv).
-behaviour(gen_server).

%% Receives {ir_key, 16#04, 16#02} → volume_up
%% Receives {ir_key, 16#04, 16#03} → volume_down  
%% Receives {ir_key, 16#04, 16#09} → mute
%% Publishes to event bus: {volume_change, up|down|mute}
```

- Debounce repeated key presses (NEC repeat code `0xFFFFFFFF`).
- Publish volume events to `myhome_event_bus`.

### Phase 3: Solskydd BLE Volume Driver (Erlang)

**Module:** `myhome_solskydd`

A gen_server that maintains a BLE connection to the Solskydd speaker and
sends volume commands.

```erlang
-module(myhome_solskydd).
-behaviour(gen_server).

-export([start_link/2]).
-export([volume_up/1, volume_down/1, set_volume/2, mute/1, unmute/1]).
-export([get_volume/1]).

%% State:
%% - BLE connection handle
%% - Current volume level (cached from notifications)
%% - Change counter (required by VCS protocol)
%% - Reconnection logic (same pattern as myhome_hue_ble)
```

Features:
- Connect to speaker on startup (with address from config/NVS).
- Subscribe to Volume State notifications to track current level.
- Expose `volume_up/1`, `volume_down/1`, `set_volume/2`, `mute/1`.
- Handle reconnection on BLE disconnect.
- Rate-limit rapid volume changes (max ~10/sec to avoid overwhelming BLE).

### Phase 4: Volume Bridge (Glue Logic)

**Module:** `myhome_volume_bridge`

Subscribes to volume events from the IR receiver (via `myhome_event_bus`)
and calls `myhome_solskydd` to relay volume changes to the speaker.

```erlang
-module(myhome_volume_bridge).
-behaviour(gen_server).

%% Subscribes to: {volume_change, Direction}
%% On volume_up   → myhome_solskydd:volume_up(speaker)
%% On volume_down → myhome_solskydd:volume_down(speaker)
%% On mute        → myhome_solskydd:mute(speaker) / unmute (toggle)
```

Optional features:
- Volume step scaling (one IR press = N BLE steps, configurable).
- Absolute volume sync if using Option C (webOS API) as input source.
- Mute toggle state tracking.

### Phase 5: Supervision & Integration

Add to the existing supervision tree:

```
myhome_top_sup
  └── myhome_sup
        ├── myhome_hue_ble (bulb 1)
        ├── myhome_hue_ble (bulb 2)
        ├── myhome_ir_recv          ← NEW
        ├── myhome_solskydd         ← NEW
        └── myhome_volume_bridge    ← NEW
```

### Phase 6: Optional — webOS API Integration (Future)

**Module:** `myhome_lg_tv`

- WiFi + WebSocket client connecting to LG TV.
- Subscribe to volume change notifications for absolute level sync.
- Allows setting the Solskydd to the exact same level as the TV reports.
- Useful as a complement to IR (IR gives direction, webOS gives absolute level).

## Hardware Requirements

| Component | Purpose | GPIO |
|-----------|---------|------|
| TSOP38238 (or VS1838B) | IR receiver | GPIO XX (TBD) |
| 100Ω resistor + 4.7µF cap | IR filter (per datasheet) | — |

Wiring:
```
TSOP38238:
  Pin 1 (OUT) → ESP32 GPIO (with pull-up)
  Pin 2 (GND) → GND
  Pin 3 (Vs)  → 3.3V
  Decoupling: 100Ω in series with Vs, 4.7µF between Vs and GND
```

## Module Summary

| Module | Language | Responsibility |
|--------|----------|---------------|
| `ir_recv` (NIF) | C | IR decode via RMT peripheral |
| `myhome_ir_recv` | Erlang | IR event gen_server, NEC decode, debounce |
| `myhome_solskydd` | Erlang | BLE connection + volume GATT writes to speaker |
| `myhome_volume_bridge` | Erlang | Glue: IR events → speaker volume commands |
| `myhome_lg_tv` | Erlang | (Future) webOS WebSocket volume sync |

## Known Facts

- The Solskydd accepts standard Bluetooth connections from a phone without any
  special app (just the OS Bluetooth settings). This indicates it uses standard
  Bluetooth profiles — likely **AVRCP** (Audio/Video Remote Control Profile) for
  volume over classic BT, and possibly **VCS** over BLE. No proprietary pairing
  flow is required.

## Open Questions

1. **Solskydd BLE protocol:** Does it use standard VCS over BLE, AVRCP over
   classic BT, or both? → Resolve in Phase 1 with nRF Connect (BLE services)
   and `sdptool browse` (classic BT SDP records).
2. ~~**Pairing:** Does the Solskydd require bonding?~~ **Partially answered:**
   Standard phone pairing works, so basic SSP (Secure Simple Pairing) is
   sufficient — no special secret or app-level auth needed.
3. **Volume granularity:** How many discrete volume steps does the speaker have?
4. **IR vs CEC:** If the TV is configured with "Internal Speaker Off", does it
   still process IR volume commands? (If yes, CEC won't fire volume events.)
5. **Step size mapping:** One TV remote press = how many speaker volume steps?
   May need user-configurable scaling.

## References

- [Bluetooth VCS Specification](https://www.bluetooth.com/specifications/specs/volume-control-service-1-0/)
- [ESP-IDF RMT (Remote Control) Driver](https://docs.espressif.com/projects/esp-idf/en/latest/esp32s3/api-reference/peripherals/rmt.html)
- [NEC IR Protocol](https://www.sbprojects.net/knowledge/ir/nec.php)
- [LG webOS WebSocket API](https://github.com/nicoh88/lg-webos-client)
- [HDMI-CEC on ESP32](https://github.com/AstasCeptmo/ESP32-HDMI-CEC)

# Two-Chip I2C Architecture

ESP32-S3 (controller) ↔ XIAO nRF52840 (target) communication over I2C.

## Physical Layer

```
ESP32-S3                         XIAO nRF52840
─────────                        ──────────────
GPIO 1 (SDA) ────────────────── D4 / P0.04 (SDA)
GPIO 2 (SCL) ────────────────── D5 / P0.05 (SCL)
GPIO 4 (IRQ) ←───────────────── D3 / P0.29 (IRQ, active LOW)
GPIO 5 (RST) ────────────────→  D2 / P0.28 (RST, active LOW)
```

- **Bus speed:** 100 kHz (standard mode)
- **Target address:** `0x08`
- **Pull-ups:** External 4.7kΩ on SDA/SCL (or internal pull-ups on XIAO side)
- **Bus sharing:** Sensors (BME680 @ 0x77, VEML6030 @ 0x48) coexist on same bus

## Signal Protocol

### IRQ (XIAO → ESP32)
- **Idle:** HIGH (no events pending)
- **Asserted:** LOW (one or more events in XIAO's queue)
- ESP32 has GPIO interrupt on falling edge; on trigger it drains all events

### RST (ESP32 → XIAO)
- **Idle:** HIGH
- **Assert LOW for 50ms:** Forces XIAO cold reboot
- XIAO has internal pull-up + falling-edge interrupt → calls `sys_reboot()`

## Register Interface

The ESP32 communicates by writing a register address, then reading/writing data.

| Reg   | Name         | R/W | Format                          | Description                    |
|-------|--------------|-----|---------------------------------|--------------------------------|
| 0x00  | STATUS       | R   | `[version, events_pending]`     | Firmware version + queue depth |
| 0x01  | CMD          | W   | `[cmd_id, payload...]`          | Execute a command              |
| 0x02  | CMD_STATUS   | R   | `[sequence, result_code]`       | Result of last command         |
| 0x10  | EVENT        | R   | `[type, len, payload...]`       | Pop next event from queue      |
| 0x11  | EVENT_LEN    | R   | `[type, payload_len]`           | Peek next event (no pop)       |

### I2C Transaction Pattern

```
Write command:   [START] [0x08+W] [REG_CMD] [cmd_id] [payload...] [STOP]
Read register:   [START] [0x08+W] [reg_addr] [STOP]
                 [START] [0x08+R] [data...] [STOP]
```

## Commands (ESP32 → XIAO)

| ID   | Name              | Payload       | Response Event    | Status |
|------|-------------------|---------------|-------------------|--------|
| 0x01 | PING              | —             | EVT_PONG          | Phase 1 ✓ |
| 0x02 | SCAN_START        | `[duration_s]`| EVT_SCAN_RESULT × N, EVT_SCAN_DONE | Phase 2 |
| 0x03 | SCAN_STOP         | —             | EVT_SCAN_DONE     | Phase 2 |
| 0x10 | CONNECT           | `[addr 6B]`  | EVT_CONNECTED     | Phase 2 |
| 0x11 | DISCONNECT        | `[conn_h]`   | EVT_DISCONNECTED  | Phase 2 |
| 0x12 | BOND              | `[conn_h]`   | EVT_BOND_COMPLETE | Phase 2 |
| 0x20 | GATT_READ         | `[conn_h, char_h 2B]` | EVT_GATT_READ_RSP | Phase 2 |
| 0x21 | GATT_WRITE        | `[conn_h, char_h 2B, data...]` | EVT_GATT_WRITE_RSP | Phase 2 |
| 0x22 | GATT_WRITE_NR     | `[conn_h, char_h 2B, data...]` | —          | Phase 2 |
| 0x23 | SUBSCRIBE         | `[conn_h, char_h 2B]` | EVT_GATT_NOTIFY × N | Phase 2 |
| 0xFF | RESET             | —             | (reboots)         | Phase 1 ✓ |

## Events (XIAO → ESP32)

| ID   | Name              | Payload                         | Status |
|------|-------------------|---------------------------------|--------|
| 0x81 | PONG              | `[version, active_connections]` | Phase 1 ✓ |
| 0x82 | READY             | —                               | Phase 1 ✓ |
| 0x83 | SCAN_RESULT       | `[addr 6B, rssi, name...]`      | Phase 2 |
| 0x84 | SCAN_DONE         | `[count]`                       | Phase 2 |
| 0x85 | CONNECTED         | `[conn_h, addr 6B]`             | Phase 2 |
| 0x86 | DISCONNECTED      | `[conn_h, reason]`              | Phase 2 |
| 0x87 | BOND_COMPLETE     | `[conn_h, status]`              | Phase 2 |
| 0x88 | GATT_SERVICES     | `[conn_h, svc_data...]`         | Phase 2 |
| 0x89 | GATT_READ_RSP     | `[conn_h, char_h 2B, data...]`  | Phase 2 |
| 0x8A | GATT_WRITE_RSP    | `[conn_h, char_h 2B, status]`   | Phase 2 |
| 0x8B | GATT_NOTIFY       | `[conn_h, char_h 2B, data...]`  | Phase 2 |
| 0x8C | ENC_CHANGE        | `[conn_h, level]`               | Phase 2 |
| 0xFE | CMD_ERROR         | `[seq, error_code]`             | Phase 1 ✓ |

### CMD_STATUS Result Codes

| Code | Meaning  |
|------|----------|
| 0x00 | OK       |
| 0x01 | Unknown command |
| 0x02 | Busy     |
| 0x03 | Error    |

## Watchdog / Keep-alive

- ESP32 sends `CMD_PING` every **10 seconds**
- XIAO software watchdog timeout: **30 seconds**
- If no PING received within 30s → XIAO reboots itself
- On reboot, XIAO queues `EVT_READY` → IRQ fires → ESP32 re-syncs

## Event Drain Sequence

```
1. XIAO queues event → IRQ pin goes LOW
2. ESP32 GPIO interrupt fires → handle_info({gpio_interrupt, 4}, State)
3. ESP32 reads REG_EVENT_LEN → [type, payload_len]
   - If [0, 0]: done (no more events)
4. ESP32 reads REG_EVENT → [type, len, payload...]
   - Event is popped from XIAO queue
   - If queue now empty: IRQ returns HIGH
5. Repeat from step 3 (max 16 per cycle)
```

## Software Stack

```
┌─────────────────────────────┐    ┌─────────────────────────────┐
│  ESP32-S3 (AtomVM/Erlang)   │    │  XIAO nRF52840 (Zephyr/C)   │
├─────────────────────────────┤    ├─────────────────────────────┤
│  myhome_ble_i2c (gen_server)│    │  main.c (watchdog + LED)    │
│    ├─ i2c:write_bytes/3     │    │  i2c_target.c (register I/F)│
│    ├─ i2c:read_bytes/3      │    │  event_queue.c (FIFO + IRQ) │
│    └─ gpio:attach_interrupt │    │                             │
├─────────────────────────────┤    ├─────────────────────────────┤
│  AtomVM I2C driver (C/IDF)  │    │  nRF TWIS DMA (buffer mode) │
│  ESP-IDF I2C controller     │    │  Nordic pinctrl (TWIS_SDA/  │
│                             │    │   TWIS_SCL function codes)  │
└──────────── I2C bus ────────┴────┴─────────────────────────────┘
```

## Source Files

| File | Role |
|------|------|
| `src/myhome_ble_i2c.erl` | ESP32 gen_server: I2C controller + event handling |
| `firmware/xiao_ble/src/main.c` | XIAO entry point, watchdog, LED heartbeat |
| `firmware/xiao_ble/src/i2c_target.c` | Register-based I2C target handler |
| `firmware/xiao_ble/src/i2c_target.h` | Shared constants (registers, commands, events) |
| `firmware/xiao_ble/src/event_queue.c` | Circular FIFO with IRQ GPIO signalling |
| `firmware/xiao_ble/src/event_queue.h` | Queue types and API |
| `firmware/xiao_ble/boards/xiao_ble.overlay` | Device tree: TWIS pinctrl + GPIO pins |
| `firmware/xiao_ble/prj.conf` | Zephyr Kconfig |

## Build & Flash

```bash
make xiao          # Build Zephyr firmware
make xiao-flash    # DFU over serial (double-tap reset first)
```

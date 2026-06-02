# BLE Port Driver Refactor: Move Logic from C to Erlang

## Goal

Reduce the C code in `nifs/ble/ble_port.c` to a thin async wrapper around NimBLE,
moving all state management, parsing, and timeout logic into Erlang.

## Current State

~700 lines of C handling: initialization, scanning, connection management,
GATT read/write, advertisement parsing, synchronous semaphore-based waiting,
scan result caching, and binary response encoding.

## What Can Move to Erlang

### 1. Advertisement Parsing (`parse_adv_name`)

Erlang binary pattern matching is ideal for AD type/length/value structures.
The C side would just forward raw advertisement bytes.

```erlang
parse_adv_name(<<Len, Type, Rest/binary>>) when Type =:= 16#09; Type =:= 16#08 ->
    NameLen = Len - 1,
    <<Name:NameLen/binary, _/binary>> = Rest,
    Name;
parse_adv_name(<<Len, _Type, Rest/binary>>) ->
    Skip = Len - 1,
    <<_:Skip/binary, Tail/binary>> = Rest,
    parse_adv_name(Tail);
parse_adv_name(_) ->
    <<>>.
```

### 2. Scan Result Caching/Deduplication

Currently: `g_scan_results[]` array with `scan_add_result()` doing memcmp dedup.

Move to: Erlang map keyed by address binary. The C callback just sends each
advertisement as a message `{ble_adv, Addr, AddrType, RSSI, RawData}`.

### 3. Connection Slot Management

Currently: `g_conns[]` with `conn_alloc`, `conn_find_by_addr`, `conn_find_by_handle`.

Move to: gen_server state with a map `#{ConnHandle => #{addr, state, ...}}`.

### 4. UUID Endian Conversion

Currently: `uuid128_from_be()` in C.

Move to: Erlang sends UUIDs already in little-endian (reverse binary before sending).

```erlang
uuid_to_le(<<UUID:16/binary>>) ->
    list_to_binary(lists:reverse(binary_to_list(UUID))).
```

### 5. Synchronous Wait + Timeout (biggest win)

Currently: C blocks on `xSemaphoreTake(g_op_sem, ...)` after every BLE call.
This requires `g_op_sem`, `g_op_rc`, timeout handling, and `ble_gap_conn_cancel()`.

Move to: **Async event-driven design.** C callbacks send Erlang messages:

- `{ble_connected, Handle, Status}`
- `{ble_disconnected, Handle, Reason}`
- `{ble_enc_change, Handle, Status}`
- `{ble_gatt_read_result, Handle, Status, Data}`
- `{ble_gatt_write_result, Handle, Status}`

Erlang uses `receive...after Timeout ->` for timeouts. No semaphores needed in C.

## What Must Stay in C

- NimBLE API calls: `ble_gap_connect`, `ble_gap_disc`, `ble_gattc_*`, etc.
- NimBLE callback registration (callbacks fire from NimBLE's FreeRTOS task)
- NVS flash init, NimBLE port init
- Security configuration (`ble_hs_cfg`)
- Sending Erlang messages from NimBLE callbacks (requires `globalcontext` locking)

## Proposed Minimal C API (opcodes)

| Opcode | Request | Notes |
|--------|---------|-------|
| `init` | `<<0x01>>` | Init NimBLE, register callbacks |
| `scan_start` | `<<0x10, Duration>>` | Start discovery, events sent async |
| `scan_stop` | `<<0x11>>` | Cancel discovery |
| `connect` | `<<0x20, Addr:6, AddrType>>` | Start connect, result sent async |
| `disconnect` | `<<0x21, Handle:16>>` | Terminate connection |
| `security` | `<<0x22, Handle:16>>` | Initiate pairing |
| `gatt_read` | `<<0x30, Handle:16, CharUUID:16/le>>` | Read by UUID, result async |
| `gatt_write` | `<<0x31, Handle:16, ValHandle:16, Value/bin>>` | Write with response |
| `gatt_write_nr` | `<<0x32, Handle:16, ValHandle:16, Value/bin>>` | Write no-response |
| `disc_chars` | `<<0x33, Handle:16>>` | Discover characteristics, result async |

## Estimated C Code Reduction

| Component | Current LOC | After refactor |
|-----------|-------------|----------------|
| Scan result cache | ~80 | 0 |
| Adv parsing | ~30 | 0 |
| Connection mgmt | ~50 | 0 |
| Semaphore/timeout | ~40 | 0 |
| UUID helpers | ~15 | 0 |
| Response encoding | ~30 | ~15 (simpler) |
| NimBLE wrappers | ~200 | ~150 |
| Port boilerplate | ~50 | ~50 |
| Async msg sending | 0 | ~60 |
| **Total** | **~700** | **~275** |

## Key Challenge

Sending Erlang messages from NimBLE callbacks requires:
1. Storing the port `Context*` or `GlobalContext*` + target PID
2. Using AtomVM's `globalcontext_send_message()` from a non-Erlang thread
3. Proper locking (AtomVM may not be fully thread-safe for this — needs verification)

## Implementation Approach

Incremental migration in 4 phases. Each phase produces a working system that
can be flashed and tested before proceeding.

### Phase 1: Verify Cross-Thread Messaging

**Goal:** Confirm that AtomVM can receive messages sent from NimBLE's FreeRTOS task.

1. Add a minimal test: register the port owner PID in C during `init`
2. In the existing `gap_event_cb` (scan callback), send a simple message to the
   owner PID: `{ble_adv_raw, Addr, AddrType, RSSI, AdvData}`
3. Add a temporary Erlang process that receives and logs these messages
4. If messages arrive correctly → proceed. If not → investigate AtomVM's
   `globalcontext_send_message()` thread safety or use a FreeRTOS queue + polling.

**Fallback:** If cross-thread send doesn't work, use a shared ring buffer in C
that the Erlang side polls via `port:call` on a timer (less elegant but functional).

### Phase 2: Async Scan Events

**Goal:** Replace synchronous scan_start/scan_results with event-driven scanning.

1. C `scan_start` initiates NimBLE discovery, returns immediately with `ok`
2. Each advertisement fires a message to the owner: `{ble_adv, Addr, AddrType, RSSI, Name}`
   (parse AD data in C minimally — just extract name — or send raw and parse in Erlang)
3. Scan complete sends `{ble_scan_complete, Reason}`
4. Move scan result dedup/caching to `myhome_scanner.erl` (Erlang map)
5. Remove `g_scan_results[]`, `scan_add_result()`, `parse_adv_name()` from C

### Phase 3: Async Connect + Security Events

**Goal:** Non-blocking connection and bond management.

1. C `connect` initiates `ble_gap_connect()`, returns immediately
2. Events sent to owner:
   - `{ble_connected, ConnHandle, Addr, Status}`
   - `{ble_disconnected, ConnHandle, Reason}`
   - `{ble_enc_change, ConnHandle, Status}`
3. New `security` opcode calls `ble_gap_security_initiate()`
4. Erlang gen_server manages connection state machine:
   - `connecting → connected → encrypting → bonded`
   - On `enc_change` with status=1285: delete bond, disconnect, retry
5. Remove `g_conns[]` slot management, `conn_alloc`, `conn_find_*` from C
6. Remove semaphore waiting from connect path

### Phase 4: Async GATT Operations

**Goal:** Non-blocking reads/writes with Erlang-managed timeouts.

1. Add `disc_chars` opcode — discovers all characteristics, sends results as
   message: `{ble_chars, ConnHandle, [{UUID, ValHandle, Properties}]}`
2. Cache characteristic handles in Erlang (per-connection map)
3. `gatt_write` takes `ValHandle` directly (no per-write discovery!)
4. Write result sent as `{ble_write_result, ConnHandle, ValHandle, Status}`
5. Read result sent as `{ble_read_result, ConnHandle, UUID, Status, Data}`
6. Erlang handles retries and timeouts via `receive...after`
7. Remove `discover_char_handle()`, `disc_chr_cb`, `gatt_write_cb`,
   `gatt_read_by_uuid_cb`, and all semaphore code from C

### Architecture After Refactor

```
┌─────────────────────────────────────────────────────┐
│ Erlang                                              │
│                                                     │
│  myhome_ble_conn (gen_server)                       │
│    - owns the port                                  │
│    - connection state machine per handle            │
│    - characteristic handle cache                    │
│    - timeout management (receive...after)           │
│    - auto-rebond on enc_change failure              │
│    - scan result dedup (map by address)             │
│                                                     │
│  myhome_hue_ble (gen_server, per bulb)              │
│    - calls myhome_ble_conn for GATT ops             │
│    - Hue protocol encoding (UUIDs, TLV)             │
│    - light state caching                            │
│                                                     │
├─────────────────────────────────────────────────────┤
│ C (ble_port.c, ~275 lines)                          │
│    - NimBLE init + config                           │
│    - Thin wrappers: scan, connect, disconnect,      │
│      security, gatt_read, gatt_write, disc_chars    │
│    - Callbacks → send Erlang messages               │
│    - No state management, no timeouts, no parsing   │
└─────────────────────────────────────────────────────┘
```

### Key Benefits Over Current Design

| Problem | Current | After Refactor |
|---------|---------|----------------|
| HTTP hangs during BLE ops | port:call blocks scheduler | Async messages, never blocks |
| Timeout cascades (C/port/gen_server) | 3 layers to tune | Single `receive...after` |
| Stale semaphore after timeout | Drain hack needed | No semaphores at all |
| Bond failure (status=1285) | Manual reset required | Auto-detect and rebond |
| First write slow (char discovery) | Discovery on every write | Cache handles after first discovery |
| Radio contention drops | Timeout + disconnect | Retry with backoff in Erlang |

## Next Steps

1. Verify AtomVM supports `globalcontext_send_message()` from arbitrary FreeRTOS tasks
2. Prototype async scan events first (lowest risk)
3. If cross-thread messaging works, convert connect/GATT ops to async
4. Move parsing and state management to a new `myhome_ble_conn.erl` gen_server

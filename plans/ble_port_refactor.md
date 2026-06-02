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

**Goal:** Non-blocking, user-initiated connection and bond management.

**Design principle:** Connections are never automatic. All connect/bond/disconnect
actions are initiated via the HTTP API. Previously-bonded bulbs loaded from NVS
may auto-reconnect, but initial pairing is always user-triggered.

**HTTP API:**
- `POST /api/connect` `{"addr":"E2:40:...", "addr_type":1}` — connect + bond
- `POST /api/disconnect` `{"addr":"E2:40:..."}` — explicit teardown
- `GET /api/connections` — list active connection states

**C changes:**
1. C `connect` initiates `ble_gap_connect()`, returns immediately
2. Events sent to subscriber:
   - `{ble_connected, ConnHandle, Addr, Status}`
   - `{ble_disconnected, ConnHandle, Reason}`
   - `{ble_enc_change, ConnHandle, Status}`
3. New `security` opcode calls `ble_gap_security_initiate()`
4. Remove `g_conns[]` slot management, `conn_alloc`, `conn_find_*` from C
5. Remove semaphore waiting from connect path

**Erlang changes:**
1. New gen_server (or extend myhome_scanner) manages connection state machine:
   - `connecting → connected → encrypting → bonded`
   - On `enc_change` with status=1285: delete bond, disconnect, report failure
2. Remove auto-discovery-on-boot from `myhome_discovery.erl`
3. `POST /api/discover` remains as a manual "scan + pair all Hue bulbs" convenience
4. `myhome_hue_ble` gen_servers only started after explicit pairing succeeds

### Phase 4: Async GATT Operations

**Goal:** Non-blocking reads/writes with Erlang-managed timeouts. Remove the
last blocking semaphore pattern from C.

**Current state (after Phase 3):** GATT read/write in C still uses
`xSemaphoreTake(g_gatt_sem, GATT_TIMEOUT_MS)` — the `ble` gen_server blocks
on `port:call` while waiting for the NimBLE callback. This blocks the `ble`
process (and thus all other callers) for up to 10 seconds per GATT op.

**C changes:**
1. `gatt_read` (0x30) sends the command, returns `ok` immediately.
   Callback sends: `{ble_gatt_read, ConnHandle, Status, Data}`
2. `gatt_write` (0x31) sends the command, returns `ok` immediately.
   Callback sends: `{ble_gatt_write, ConnHandle, Status}`
3. `gatt_write_nr` (0x32) remains fire-and-forget (no callback, returns `ok`).
4. Add `disc_svcs` opcode (0x33) — discover services+characteristics for a
   connection. Result sent as: `{ble_disc_complete, ConnHandle, [{SvcUUID, ChrUUID, ValHandle, Properties}]}`
5. Remove `g_gatt_sem`, `g_gatt_rc`, `g_gatt_data`, `g_gatt_data_len`,
   `GATT_TIMEOUT_MS`, and all semaphore take/give code.

**Erlang changes (`ble.erl`):**
1. `gatt_read/3` and `gatt_write/4` become two-step:
   - Send command via `port:call` (returns `ok` immediately)
   - Wait for async result in the gen_server's `handle_info`
   - Use a correlation mechanism (ConnHandle + pending op map) to match
     results to waiting callers
   - `receive...after 15000 ->` timeout handled per-caller via `gen_server:reply`
2. Add pending operations map to state: `#{ConnHandle => {From, Op, TRef}}`
3. `gatt_write_nr/4` stays synchronous (it's already fast, no callback).
4. New `discover_services/1` API — caches {SvcUUID, ChrUUID} → ValHandle mapping.
5. GATT read/write can use cached ValHandle for efficiency (skip per-op discovery).

**Event bus integration:**
- GATT results are NOT published to the event bus (they're request/response,
  not broadcast events). Only `ble.erl` handles them internally.
- Connection/disconnect events continue flowing through the bus as today.

**Serialization concern:**
- With async GATT, the `ble` gen_server can potentially have multiple in-flight
  GATT ops. Since NimBLE serializes ops per-connection anyway, we allow at most
  one pending GATT op per ConnHandle. Additional requests queue in the gen_server
  mailbox (natural backpressure via `gen_server:call` timeout).

**Benefits:**
- `ble` gen_server no longer blocks for 10s on GATT ops
- Other callers (scan, connect) aren't starved while a GATT op is pending
- Timeout logic moves to Erlang (single place to tune)
- ~40 lines of semaphore code removed from C

### Architecture After Refactor

```
┌─────────────────────────────────────────────────────┐
│ Erlang                                              │
│                                                     │
│  ble (gen_server)                                   │
│    - owns the port (sole accessor)                  │
│    - serializes all BLE commands                    │
│    - receives async events from port                │
│    - publishes events to myhome_event_bus           │
│    - manages pending GATT ops (Phase 4)             │
│    - timeout management (per-caller timers)         │
│                                                     │
│  myhome_event_bus (gen_server)                      │
│    - pub/sub with filtered subscriptions            │
│    - auto-cleanup via process monitors              │
│                                                     │
│  myhome_ble_conn (gen_server)                       │
│    - subscribes to connection events via bus         │
│    - connection state machine per handle            │
│    - sync connect (waiter pattern)                  │
│                                                     │
│  myhome_scanner (gen_server)                        │
│    - subscribes to scan events via bus              │
│    - scan result dedup (map by address)             │
│                                                     │
│  myhome_hue_ble (gen_server, per bulb)              │
│    - calls ble:gatt_* for GATT ops                  │
│    - uses myhome_ble_conn for connect/disconnect    │
│    - Hue protocol encoding (UUIDs, TLV)             │
│    - light state caching                            │
│                                                     │
├─────────────────────────────────────────────────────┤
│ C (ble_port.c, ~250 lines after Phase 4)            │
│    - NimBLE init + config                           │
│    - Thin wrappers: scan, connect, disconnect,      │
│      security, gatt_read, gatt_write, disc_svcs     │
│    - Callbacks → send Erlang messages               │
│    - No state management, no timeouts, no parsing   │
│    - No semaphores                                  │
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

## Progress

- [x] Phase 1: Cross-thread messaging verified (port_send_message_from_task works)
- [x] Phase 2: Async scan events (myhome_scanner subscribes via event bus)
- [x] Phase 3: Async connect + security events (myhome_ble_conn, HTTP API)
- [ ] Phase 4: Async GATT operations (remove last semaphore from C)

## Next Steps

1. Implement Phase 4: make `gatt_read`/`gatt_write` non-blocking in C
2. Add pending-op map to `ble.erl` for correlating async GATT results
3. Add `disc_svcs` opcode for characteristic handle caching
4. Remove all semaphore code from `ble_port.c`
5. Rebuild firmware (`make flash`) and verify end-to-end

# Phase 5 · Step 1 — nRF52840 Persistent Auto-Reconnect

> Part of `plans/xiao-nrf52840-ble-offload.md`, Phase 5 ("Persistent
> Connections + Cleanup"), task 1. This is the **foundational** step that
> unblocks the ESP32-side simplifications (tasks 2–3).

## Problem

Today `myhome_hue_ble.erl` uses a **connect-on-demand** model: it asks the
nRF to connect only when a command arrives, with a short retry window
(~3 attempts over ~1.2 s) and a 60 s cooldown after a failed connect.

When a bulb's light has been off overnight (link dropped, bulb idle), the
on-demand connect frequently misses the bulb's slow advertising window,
times out, and trips the cooldown. The bulb then stays unreachable until it
is manually switched on. This makes unattended scheduling (e.g. a
burglary-deterrent "on at dusk / off at midnight") impossible.

> **Physical prerequisite:** the bulbs must stay **mains-powered** at all
> times — only the *light* is toggled over BLE. A bulb with no power has no
> radio and cannot be reached by any software.

## Goal

The nRF52840 maintains a **persistent, encrypted connection to every bonded
Hue bulb**, auto-reconnecting on boot and whenever a bulb drops or
re-advertises — with **zero** involvement from the ESP32. The connection is
already up before any scheduled command needs it, and the system self-heals
without cooldowns.

## Approach — accept-list background auto-connect

Use Zephyr's filter accept list plus `bt_conn_le_create_auto()`. The
controller passively waits for any bonded device to advertise and connects
the instant it does, re-arming after each connection.

## Files

| File | Change |
|------|--------|
| `firmware/xiao_ble/prj.conf` | Add `CONFIG_BT_FILTER_ACCEPT_LIST=y` |
| `firmware/xiao_ble/src/ble_central.c` | Auto-connect engine + self-initiated security on the auto path |
| `firmware/xiao_ble/src/ble_central.h` | New API declarations |
| `firmware/xiao_ble/src/main.c` | Start auto-connect after `ble_central_init()` |
| `firmware/xiao_ble/src/i2c_target.c` | Suspend/resume auto-connect around discovery scans |

## Design

1. **Enumerate bonds → accept list.** On boot (after `settings_load()`),
   `bt_foreach_bond(BT_ID_DEFAULT, cb, ...)` →
   `bt_le_filter_accept_list_add(&addr)` for each stored bond.

2. **Background auto-connect.**
   `bt_conn_le_create_auto(BT_CONN_LE_CREATE_CONN, BT_LE_CONN_PARAM_DEFAULT)`
   connects the first bonded bulb that advertises. It connects **one device
   at a time and completes**, so the firmware **re-arms** after every
   connection until all bonded bulbs are up.

3. **Self-initiated encryption on the auto path.** In `connected_cb`, when
   `connect_pending` is `false` (i.e. *not* a manual on-demand connect), the
   nRF calls `bt_conn_set_security(BT_SECURITY_L2)` itself → emits
   `EVT_ENC_CHANGE`. It still emits `EVT_CONNECTED` (with the 6-byte addr) so
   the ESP32 can map `handle ↔ address`. The existing manual pairing path
   (settle/retry + ESP32-driven `CMD_BOND`) is left intact for *new* bulbs.

4. **No spurious errors.** Auto-connect failures must **not** emit
   `EVT_CMD_ERROR` (no command was issued) — they only trigger a re-arm.

5. **Re-arm triggers:**
   - boot (after the accept list is populated);
   - after each successful auto-connect, if a free conn slot **and** an
     unconnected bond remains;
   - on `disconnected` of a bonded device (re-add to accept list + re-arm)
     → self-healing reconnection.

6. **Scan arbitration (the one tricky part).** `bt_conn_le_create_auto()`
   owns the controller scanner, which conflicts with active discovery
   (`bt_le_scan_start`). Before a discovery scan or a manual
   `ble_central_connect`, call `bt_conn_create_auto_stop()` and set a
   `autoconnect_suspended` flag; re-arm when the scan finishes / the manual
   connect cycle ends.

7. **New runtime bond.** After `pairing_complete` for a freshly paired bulb,
   add its address to the accept list and re-arm so it joins the persistent
   set on the next reconnect.

## New API (`ble_central.h`)

```c
/* Populate the filter accept list from stored bonds and begin background
 * auto-connection. Call once after ble_central_init(). */
int  ble_central_autoconnect_start(void);

/* Pause background auto-connect (e.g. before a discovery scan or a manual
 * connect, which need exclusive use of the scanner). */
void ble_central_autoconnect_suspend(void);

/* Resume background auto-connect after a scan / manual connect completes. */
void ble_central_autoconnect_resume(void);
```

Internal helper: `static void rearm_autoconnect(void)`.

## Config / safety notes

- `CONFIG_BT_MAX_CONN=5`, `CONFIG_BT_MAX_PAIRED=5`, `CONFIG_BT_SETTINGS=y`,
  and `CONFIG_BT_CREATE_CONN_TIMEOUT=10` (slow Hue adverts) are already set —
  only `CONFIG_BT_FILTER_ACCEPT_LIST=y` is missing.
- Handle `-EALREADY` (auto-connect already running) and `-ENOMEM` (no free
  slots) gracefully. Only arm when a slot is free **and** at least one bonded
  bulb is disconnected.
- A watchdog reboot re-runs the boot path, re-establishing all links.

## Effect on the rest of the system (informs steps 2–3)

- `EVT_CONNECTED` / `EVT_ENC_CHANGE` / `EVT_DISCONNECTED` now arrive
  **unsolicited**; the ESP32 must treat them as spontaneous and map by
  address.
- The ESP32 stops driving connect/bond per command (step 2) and the
  connect-cooldown logic becomes dead code (step 3).
- Initial pairing of an *unbonded* bulb (`myhome_discovery`) still uses the
  explicit connect + bond flow; auto-connect takes over afterward.

## Verification (this step)

Hardware behaviour is validated later in Phase 5 task 6 (hardware-gated).
This step only confirms the firmware compiles:

```bash
source /Users/ttornkvi/git/myhome-assistant/.venv/bin/activate
export ZEPHYR_BASE=~/zephyrproject/zephyr
export ZEPHYR_SDK_INSTALL_DIR=~/zephyr-sdk-1.0.1
cd /Users/ttornkvi/git/myhome-assistant/firmware/xiao_ble
west build -b xiao_ble .
```

## Out of scope (later Phase 5 tasks)

- **Task 2** — ESP32 persistent-connection model in `myhome_hue_ble.erl`
  (react to `CONNECTED`/`ENC_CHANGE`/`DISCONNECTED`; no per-command connect).
- **Task 3** — remove `last_connect_fail` / `CONNECT_COOLDOWN_MS` and the
  connect-on-demand path.
- **Task 6** — on-hardware verification (WiFi never drops, bulbs reconnect
  after overnight power-off of the *light*).

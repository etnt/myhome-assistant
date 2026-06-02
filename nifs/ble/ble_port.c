/**
 * BLE Port Driver for AtomVM — Hue Light Control
 *
 * Based on the port driver pattern from hello_atomvm_ble_switchbot
 * (Apache-2.0, github.com/piyopiyoex/hello_atomvm_ble_switchbot).
 *
 * Extends passive scanning with GATT client operations:
 * connect, read, write, subscribe, and pairing/bonding.
 */

#include "ble_port.h"

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include <context.h>
#include <globalcontext.h>
#include <mailbox.h>
#include <memory.h>
#include <port.h>
#include <portnifloader.h>
#include <term.h>

// #define ENABLE_TRACE
#include <trace.h>

#include "freertos/FreeRTOS.h"

#include "esp_log.h"
#include "nvs_flash.h"

#include "host/ble_gap.h"
#include "host/ble_gatt.h"
#include "host/ble_hs.h"
#include "host/ble_store.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "store/config/ble_store_config.h"

#define TAG "ble_port"

// ─────────────────────────────────────────────────────────────────────────────
// Opcodes (Erlang → C requests)
// ─────────────────────────────────────────────────────────────────────────────

enum {
    // Lifecycle
    OP_INIT         = 0x01,

    // Scanning
    OP_SCAN_START   = 0x10,
    OP_SCAN_STOP    = 0x11,
    OP_SUBSCRIBE_SCAN = 0x13,  // Subscribe to async scan events

    // Connection
    OP_CONNECT      = 0x20,
    OP_DISCONNECT   = 0x21,
    OP_SECURITY     = 0x22,
    OP_UPDATE_PARAMS = 0x23,  // Update connection parameters

    // GATT operations
    OP_GATT_READ    = 0x30,
    OP_GATT_WRITE   = 0x31,
    OP_GATT_WRITE_NR = 0x32,  // write no-response
    OP_SUBSCRIBE    = 0x33,
    OP_DISC_SVCS    = 0x34,   // discover all characteristics
};

// ─────────────────────────────────────────────────────────────────────────────
// Response status codes
// ─────────────────────────────────────────────────────────────────────────────

#define RSP_OK          0x00
#define RSP_ERR         0x01
#define RSP_ERR_ARGS    0x02
#define RSP_ERR_STATE   0x03
#define RSP_ERR_TIMEOUT 0x04
#define RSP_ERR_BLE     0x05
#define RSP_ERR_NOMEM   0x06

// ─────────────────────────────────────────────────────────────────────────────
// Scan state
// ─────────────────────────────────────────────────────────────────────────────

#define MAX_NAME_LEN     32
static bool g_scanning = false;

// ─────────────────────────────────────────────────────────────────────────────
// GATT discovery buffer (Phase 4: async)
// ─────────────────────────────────────────────────────────────────────────────

#define MAX_GATT_READ 128
#define MAX_DISC_CHARS 32

struct disc_chr_entry {
    uint8_t uuid_be[16];     // UUID in big-endian (natural) order
    uint16_t val_handle;
    uint8_t properties;
};

static struct disc_chr_entry g_disc_results[MAX_DISC_CHARS];
static uint16_t g_disc_count;
static uint16_t g_disc_conn_handle;

// NimBLE state
static bool g_ble_initialized = false;
static uint8_t g_own_addr_type;

// ─────────────────────────────────────────────────────────────────────────────
// Async messaging (Phase 1: cross-thread message delivery)
// ─────────────────────────────────────────────────────────────────────────────

static GlobalContext *g_global = NULL;
static int32_t g_scan_subscriber_pid = -1;  // PID subscribed to scan events (-1 = none)

static const char *const ble_scan_event_atom = ATOM_STR("\xE", "ble_scan_event");
static const char *const ble_scan_complete_atom = ATOM_STR("\x11", "ble_scan_complete");
static const char *const ble_connected_atom = ATOM_STR("\xD", "ble_connected");
static const char *const ble_disconnected_atom = ATOM_STR("\x10", "ble_disconnected");
static const char *const ble_enc_change_atom = ATOM_STR("\xE", "ble_enc_change");
static const char *const ble_gatt_read_atom = ATOM_STR("\xD", "ble_gatt_read");
static const char *const ble_gatt_write_atom = ATOM_STR("\xE", "ble_gatt_write");
static const char *const ble_disc_complete_atom = ATOM_STR("\x11", "ble_disc_complete");

// ─────────────────────────────────────────────────────────────────────────────
// Utility: build response binaries
// ─────────────────────────────────────────────────────────────────────────────

static term make_response(Context *ctx, uint8_t status,
                          const uint8_t *payload, size_t payload_len)
{
    size_t total = 1 + payload_len;
    term bin = term_create_uninitialized_binary(total, &ctx->heap, ctx->global);
    uint8_t *out = (uint8_t *) term_binary_data(bin);
    out[0] = status;
    if (payload_len > 0 && payload != NULL) {
        memcpy(out + 1, payload, payload_len);
    }
    return bin;
}

static term make_ok(Context *ctx)
{
    return make_response(ctx, RSP_OK, NULL, 0);
}

static term make_ok_payload(Context *ctx, const uint8_t *p, size_t len)
{
    return make_response(ctx, RSP_OK, p, len);
}

static term make_error(Context *ctx, uint8_t code)
{
    return make_response(ctx, RSP_ERR, &code, 1);
}

// ─────────────────────────────────────────────────────────────────────────────
// NimBLE: Scan advertisement parser
// ─────────────────────────────────────────────────────────────────────────────

static void parse_adv_name(const uint8_t *data, uint8_t data_len,
                           char *name_out, uint8_t *name_len_out)
{
    *name_len_out = 0;
    uint8_t i = 0;
    while (i < data_len) {
        uint8_t len = data[i];
        if (len == 0 || (uint16_t)i + len >= data_len) {
            break;
        }
        uint8_t type = data[i + 1];
        // Complete Local Name (0x09) or Shortened Local Name (0x08)
        if (type == 0x09 || type == 0x08) {
            uint8_t n = len - 1;
            if (n > MAX_NAME_LEN - 1) n = MAX_NAME_LEN - 1;
            memcpy(name_out, &data[i + 2], n);
            name_out[n] = '\0';
            *name_len_out = n;
            return;
        }
        i = i + 1 + len;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// NimBLE: GAP event handler
// ─────────────────────────────────────────────────────────────────────────────

static int gap_event_cb(struct ble_gap_event *event, void *arg)
{
    (void) arg;

    switch (event->type) {

    case BLE_GAP_EVENT_DISC:
        // Phase 2: send all advertisements to subscriber for Erlang-side dedup
        if (g_scan_subscriber_pid >= 0 && g_global != NULL) {
            const struct ble_gap_disc_desc *desc = &event->disc;
            // Parse name from advertisement
            char name[MAX_NAME_LEN] = {0};
            uint8_t name_len = 0;
            parse_adv_name(desc->data, desc->length_data, name, &name_len);

            // Message: {ble_scan_event, <<Addr:6/binary>>, AddrType, RSSI, <<Name/binary>>}
            #define SCAN_EVENT_HEAP_SIZE (TUPLE_SIZE(5) + TERM_BINARY_HEAP_SIZE(6) + TERM_BINARY_HEAP_SIZE(MAX_NAME_LEN))
            BEGIN_WITH_STACK_HEAP(SCAN_EVENT_HEAP_SIZE, heap);
            {
                term atom = globalcontext_make_atom(g_global, ble_scan_event_atom);
                term addr_bin = term_from_literal_binary(desc->addr.val, 6, &heap, g_global);
                term addr_type = term_from_int(desc->addr.type);
                term rssi = term_from_int(desc->rssi);
                term name_bin = term_from_literal_binary(
                    (const void *) name, strlen(name), &heap, g_global);

                term msg = port_heap_create_tuple_n(&heap, 5,
                    (term[]){atom, addr_bin, addr_type, rssi, name_bin});

                port_send_message_from_task(g_global,
                    term_from_local_process_id(g_scan_subscriber_pid), msg);
            }
            END_WITH_STACK_HEAP(heap, g_global);
        }
        return 0;

    case BLE_GAP_EVENT_DISC_COMPLETE:
        ESP_LOGI(TAG, "scan complete");
        g_scanning = false;
        // Send {ble_scan_complete} to subscriber
        if (g_scan_subscriber_pid >= 0 && g_global != NULL) {
            BEGIN_WITH_STACK_HEAP(TUPLE_SIZE(1), heap);
            {
                term atom = globalcontext_make_atom(g_global, ble_scan_complete_atom);
                term msg = port_heap_create_tuple_n(&heap, 1, (term[]){atom});
                port_send_message_from_task(g_global,
                    term_from_local_process_id(g_scan_subscriber_pid), msg);
            }
            END_WITH_STACK_HEAP(heap, g_global);
        }
        return 0;

    case BLE_GAP_EVENT_CONNECT: {
        uint16_t handle = event->connect.conn_handle;
        int status = event->connect.status;
        ESP_LOGI(TAG, "connect event: handle=%u status=%d", handle, status);

        // Send {ble_connected, ConnHandle, Status} to subscriber
        if (g_scan_subscriber_pid >= 0 && g_global != NULL) {
            BEGIN_WITH_STACK_HEAP(TUPLE_SIZE(3), heap);
            {
                term atom = globalcontext_make_atom(g_global, ble_connected_atom);
                term t_handle = term_from_int(handle);
                term t_status = term_from_int(status);
                term msg = port_heap_create_tuple_n(&heap, 3,
                    (term[]){atom, t_handle, t_status});
                port_send_message_from_task(g_global,
                    term_from_local_process_id(g_scan_subscriber_pid), msg);
            }
            END_WITH_STACK_HEAP(heap, g_global);
        }
        return 0;
    }

    case BLE_GAP_EVENT_DISCONNECT: {
        uint16_t handle = event->disconnect.conn.conn_handle;
        int reason = event->disconnect.reason;
        ESP_LOGI(TAG, "disconnect: handle=%u reason=%d", handle, reason);

        // Send {ble_disconnected, ConnHandle, Reason} to subscriber
        if (g_scan_subscriber_pid >= 0 && g_global != NULL) {
            BEGIN_WITH_STACK_HEAP(TUPLE_SIZE(3), heap);
            {
                term atom = globalcontext_make_atom(g_global, ble_disconnected_atom);
                term t_handle = term_from_int(handle);
                term t_reason = term_from_int(reason);
                term msg = port_heap_create_tuple_n(&heap, 3,
                    (term[]){atom, t_handle, t_reason});
                port_send_message_from_task(g_global,
                    term_from_local_process_id(g_scan_subscriber_pid), msg);
            }
            END_WITH_STACK_HEAP(heap, g_global);
        }
        return 0;
    }

    case BLE_GAP_EVENT_ENC_CHANGE: {
        uint16_t handle = event->enc_change.conn_handle;
        int status = event->enc_change.status;
        ESP_LOGI(TAG, "encryption change: handle=%u status=%d", handle, status);

        // Send {ble_enc_change, ConnHandle, Status} to subscriber
        if (g_scan_subscriber_pid >= 0 && g_global != NULL) {
            BEGIN_WITH_STACK_HEAP(TUPLE_SIZE(3), heap);
            {
                term atom = globalcontext_make_atom(g_global, ble_enc_change_atom);
                term t_handle = term_from_int(handle);
                term t_status = term_from_int(status);
                term msg = port_heap_create_tuple_n(&heap, 3,
                    (term[]){atom, t_handle, t_status});
                port_send_message_from_task(g_global,
                    term_from_local_process_id(g_scan_subscriber_pid), msg);
            }
            END_WITH_STACK_HEAP(heap, g_global);
        }
        return 0;
    }

    case BLE_GAP_EVENT_REPEAT_PAIRING: {
        // Delete old bond and allow re-pairing
        struct ble_gap_conn_desc desc;
        ble_gap_conn_find(event->repeat_pairing.conn_handle, &desc);
        ble_store_util_delete_peer(&desc.peer_id_addr);
        return BLE_GAP_REPEAT_PAIRING_RETRY;
    }

    case BLE_GAP_EVENT_CONN_UPDATE: {
        int status = event->conn_update.status;
        uint16_t handle = event->conn_update.conn_handle;
        if (status == 0) {
            struct ble_gap_conn_desc desc;
            ble_gap_conn_find(handle, &desc);
            ESP_LOGI(TAG, "conn update OK: handle=%u itvl=%u latency=%u timeout=%u",
                     handle, desc.conn_itvl, desc.conn_latency, desc.supervision_timeout);
        } else {
            ESP_LOGW(TAG, "conn update FAILED: handle=%u status=%d", handle, status);
        }
        return 0;
    }

    case BLE_GAP_EVENT_CONN_UPDATE_REQ: {
        // Auto-accept any peer-initiated param update requests
        ESP_LOGI(TAG, "conn update req from peer: handle=%u",
                 event->conn_update_req.conn_handle);
        return 0;
    }

    default:
        return 0;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// NimBLE: GATT client callbacks (Phase 4: async — send results as messages)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Callback for ble_gattc_read_by_uuid.
 * Called once with data (status==0), then once with BLE_HS_EDONE.
 * We accumulate data on the first call, send the message on completion.
 */
static uint8_t g_async_read_buf[MAX_GATT_READ];
static uint16_t g_async_read_len;
static uint16_t g_async_read_conn;

static int gatt_read_by_uuid_cb(uint16_t conn_handle,
                                const struct ble_gatt_error *error,
                                struct ble_gatt_attr *attr, void *arg)
{
    (void) arg;

    if (error->status == 0 && attr != NULL) {
        // Data received — accumulate
        g_async_read_len = OS_MBUF_PKTLEN(attr->om);
        if (g_async_read_len > MAX_GATT_READ) {
            g_async_read_len = MAX_GATT_READ;
        }
        os_mbuf_copydata(attr->om, 0, g_async_read_len, g_async_read_buf);
        g_async_read_conn = conn_handle;
        return 0;
    }

    // Completion callback — send result to subscriber
    if (g_scan_subscriber_pid >= 0 && g_global != NULL) {
        int status = 0;
        if (error->status == BLE_HS_EDONE) {
            status = (g_async_read_len == 0) ? BLE_HS_ENOENT : 0;
        } else {
            status = error->status;
            g_async_read_len = 0;
        }

        // Message: {ble_gatt_read, ConnHandle, Status, Data}
        #define GATT_READ_HEAP_SIZE (TUPLE_SIZE(4) + TERM_BINARY_HEAP_SIZE(MAX_GATT_READ))
        BEGIN_WITH_STACK_HEAP(GATT_READ_HEAP_SIZE, heap);
        {
            term atom = globalcontext_make_atom(g_global, ble_gatt_read_atom);
            term t_handle = term_from_int(conn_handle);
            term t_status = term_from_int(status);
            term t_data = term_from_literal_binary(
                g_async_read_buf, g_async_read_len, &heap, g_global);

            term msg = port_heap_create_tuple_n(&heap, 4,
                (term[]){atom, t_handle, t_status, t_data});

            port_send_message_from_task(g_global,
                term_from_local_process_id(g_scan_subscriber_pid), msg);
        }
        END_WITH_STACK_HEAP(heap, g_global);
    }

    g_async_read_len = 0;
    return 0;
}

/**
 * Callback for ble_gattc_write_flat.
 * Sends {ble_gatt_write, ConnHandle, Status} to subscriber.
 */
static int gatt_write_cb(uint16_t conn_handle,
                         const struct ble_gatt_error *error,
                         struct ble_gatt_attr *attr, void *arg)
{
    (void) attr;
    (void) arg;

    if (g_scan_subscriber_pid >= 0 && g_global != NULL) {
        // Message: {ble_gatt_write, ConnHandle, Status}
        BEGIN_WITH_STACK_HEAP(TUPLE_SIZE(3), heap);
        {
            term atom = globalcontext_make_atom(g_global, ble_gatt_write_atom);
            term t_handle = term_from_int(conn_handle);
            term t_status = term_from_int(error->status);

            term msg = port_heap_create_tuple_n(&heap, 3,
                (term[]){atom, t_handle, t_status});

            port_send_message_from_task(g_global,
                term_from_local_process_id(g_scan_subscriber_pid), msg);
        }
        END_WITH_STACK_HEAP(heap, g_global);
    }

    return 0;
}

/**
 * Callback for ble_gattc_disc_all_chrs.
 * Accumulates results, sends {ble_disc_complete, ConnHandle, Status, Data}
 * on completion.
 */
static int disc_all_chrs_cb(uint16_t conn_handle,
                            const struct ble_gatt_error *error,
                            const struct ble_gatt_chr *chr, void *arg)
{
    (void) arg;

    if (error->status == 0 && chr != NULL) {
        // Accumulate characteristic
        if (g_disc_count < MAX_DISC_CHARS && chr->uuid.u.type == BLE_UUID_TYPE_128) {
            struct disc_chr_entry *entry = &g_disc_results[g_disc_count];
            // Convert from NimBLE little-endian to big-endian (natural)
            for (int i = 0; i < 16; i++) {
                entry->uuid_be[i] = ((ble_uuid128_t *)&chr->uuid)->value[15 - i];
            }
            entry->val_handle = chr->val_handle;
            entry->properties = chr->properties;
            g_disc_count++;
        }
        return 0;
    }

    // Discovery complete — send results to subscriber
    if (g_scan_subscriber_pid >= 0 && g_global != NULL) {
        int status = (error->status == BLE_HS_EDONE) ? 0 : error->status;

        // Pack results as binary: <<Count:16/little, (UUID:16/bytes, ValHandle:16/little, Props:8)*>>
        size_t data_len = 2 + (size_t)g_disc_count * 19;  // 16 + 2 + 1 per entry
        uint8_t data_buf[2 + MAX_DISC_CHARS * 19];
        data_buf[0] = g_disc_count & 0xFF;
        data_buf[1] = (g_disc_count >> 8) & 0xFF;
        for (uint16_t i = 0; i < g_disc_count; i++) {
            uint8_t *p = &data_buf[2 + i * 19];
            memcpy(p, g_disc_results[i].uuid_be, 16);
            p[16] = g_disc_results[i].val_handle & 0xFF;
            p[17] = (g_disc_results[i].val_handle >> 8) & 0xFF;
            p[18] = g_disc_results[i].properties;
        }

        // Message: {ble_disc_complete, ConnHandle, Status, Data}
        #define DISC_HEAP_SIZE (TUPLE_SIZE(4) + TERM_BINARY_HEAP_SIZE(2 + MAX_DISC_CHARS * 19))
        BEGIN_WITH_STACK_HEAP(DISC_HEAP_SIZE, heap);
        {
            term atom = globalcontext_make_atom(g_global, ble_disc_complete_atom);
            term t_handle = term_from_int(conn_handle);
            term t_status = term_from_int(status);
            term t_data = term_from_literal_binary(data_buf, data_len, &heap, g_global);

            term msg = port_heap_create_tuple_n(&heap, 4,
                (term[]){atom, t_handle, t_status, t_data});

            port_send_message_from_task(g_global,
                term_from_local_process_id(g_scan_subscriber_pid), msg);
        }
        END_WITH_STACK_HEAP(heap, g_global);
    }

    return 0;
}

// ─────────────────────────────────────────────────────────────────────────────
// NimBLE: host sync and task
// ─────────────────────────────────────────────────────────────────────────────

static void on_sync(void)
{
    int rc = ble_hs_id_infer_auto(0, &g_own_addr_type);
    ESP_LOGI(TAG, "ble_hs_id_infer_auto rc=%d addr_type=%u", rc, g_own_addr_type);
}

static void host_task(void *param)
{
    (void) param;
    nimble_port_run();
    nimble_port_freertos_deinit();
}

// ─────────────────────────────────────────────────────────────────────────────
// UUID helpers
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Parse a 16-byte UUID from the request buffer into a ble_uuid128_t.
 * The bytes in the request are in big-endian (natural) order;
 * NimBLE stores 128-bit UUIDs in little-endian.
 */
static void uuid128_from_be(const uint8_t *be_bytes, ble_uuid128_t *uuid)
{
    uuid->u.type = BLE_UUID_TYPE_128;
    for (int i = 0; i < 16; i++) {
        uuid->value[15 - i] = be_bytes[i];
    }
}

/**
 * Resolve a 128-bit service/characteristic UUID to a GATT attribute handle
 * using ble_gattc_disc_all_chrs synchronously.
 *
 * For simplicity, we use ble_gattc_read_by_uuid which reads by UUID directly —
 * this avoids needing to cache handles.
 */

// ─────────────────────────────────────────────────────────────────────────────
// Opcode handlers
// ─────────────────────────────────────────────────────────────────────────────

static term handle_init(Context *ctx)
{
    if (g_ble_initialized) {
        return make_ok(ctx);
    }

    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        nvs_flash_erase();
        err = nvs_flash_init();
    }
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "nvs_flash_init failed: %d", (int) err);
        return make_error(ctx, RSP_ERR_STATE);
    }

    nimble_port_init();

    // Configure security: enable bonding, MITM not required, prefer Secure Connections
    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.sm_io_cap = BLE_SM_IO_CAP_NO_IO;
    ble_hs_cfg.sm_bonding = 1;
    ble_hs_cfg.sm_mitm = 0;
    ble_hs_cfg.sm_sc = 1;  // Prefer LESC; falls back to Legacy if peer doesn't support SC
    ble_hs_cfg.sm_our_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.sm_their_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.store_read_cb = ble_store_config_read;
    ble_hs_cfg.store_write_cb = ble_store_config_write;
    ble_hs_cfg.store_delete_cb = ble_store_config_delete;

    g_ble_initialized = true;
    nimble_port_freertos_init(host_task);

    ESP_LOGI(TAG, "BLE initialized");
    return make_ok(ctx);
}

static term make_error_with_rc(Context *ctx, uint8_t code, int rc)
{
    uint8_t payload[2] = {code, (uint8_t) rc};
    return make_response(ctx, RSP_ERR, payload, 2);
}

static term handle_scan_start(Context *ctx, const uint8_t *data, size_t len)
{
    if (!g_ble_initialized) {
        return make_error(ctx, RSP_ERR_STATE);
    }

    // Optional: duration in seconds (default=10)
    uint8_t duration_sec = 10;
    if (len >= 2) {
        duration_sec = data[1];
    }

    // Defensively cancel any prior scan/connect to free the GAP
    if (g_scanning) {
        ESP_LOGW(TAG, "scan still active, cancelling before restart");
        ble_gap_disc_cancel();
        g_scanning = false;
    }

    struct ble_gap_disc_params params;
    memset(&params, 0, sizeof(params));
    params.passive = 0;  // active scan to get names
    params.itvl = 0x0100;   // 160ms interval — leaves gaps for WiFi
    params.window = 0x0030;  // 30ms window — ~19% BLE duty cycle
    params.filter_duplicates = 0;

    int32_t duration_ms = (int32_t) duration_sec * 1000;
    int rc = ble_gap_disc(g_own_addr_type, duration_ms, &params, gap_event_cb, NULL);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_gap_disc failed: rc=%d", rc);
        return make_error_with_rc(ctx, RSP_ERR_BLE, rc);
    }

    g_scanning = true;
    ESP_LOGI(TAG, "scan started for %u seconds", duration_sec);
    return make_ok(ctx);
}

static term handle_scan_stop(Context *ctx)
{
    if (!g_ble_initialized) {
        return make_error(ctx, RSP_ERR_STATE);
    }
    if (g_scanning) {
        ble_gap_disc_cancel();
        g_scanning = false;
    }
    return make_ok(ctx);
}

/**
 * Subscribe calling process to receive async scan events.
 * Request: <<OP_SUBSCRIBE_SCAN>>
 * Effect: Each advertisement will send {ble_scan_event, Addr, AddrType, RSSI, Name}
 *         to the calling process asynchronously from NimBLE's task.
 */
static term handle_subscribe_scan(Context *ctx, term caller_pid)
{
    if (!g_ble_initialized) {
        return make_error(ctx, RSP_ERR_STATE);
    }
    g_scan_subscriber_pid = term_to_local_process_id(caller_pid);
    ESP_LOGI(TAG, "scan subscriber registered: pid=%d", (int) g_scan_subscriber_pid);
    return make_ok(ctx);
}

/**
 * Connect to a device.
 * Request: <<OP_CONNECT, Addr:6/bytes, AddrType:8>>
 */
static term handle_connect(Context *ctx, const uint8_t *data, size_t len)
{
    if (!g_ble_initialized) {
        return make_error(ctx, RSP_ERR_STATE);
    }
    if (len < 8) { // opcode + 6 addr + addr_type
        return make_error(ctx, RSP_ERR_ARGS);
    }

    const uint8_t *addr = &data[1];
    uint8_t addr_type = data[7];

    // Stop scanning if active (can't scan and connect simultaneously)
    if (g_scanning) {
        ble_gap_disc_cancel();
        g_scanning = false;
    }

    ble_addr_t peer_addr;
    peer_addr.type = addr_type;
    memcpy(peer_addr.val, addr, 6);

    // Use fast connection parameters initially.
    // Pairing (LESC) requires multiple SM round-trips, so we need
    // a short interval here. After bonding succeeds, Erlang calls
    // OP_UPDATE_PARAMS to switch to slow params for WiFi coexistence.
    struct ble_gap_conn_params conn_params = {
        .scan_itvl = 16,              // 10ms scan interval during connect
        .scan_window = 16,            // 10ms scan window
        .itvl_min = 24,               // 30ms min — fast for SM handshake
        .itvl_max = 40,               // 50ms max
        .latency = 0,                 // no latency during pairing
        .supervision_timeout = 200,   // 2s supervision timeout
        .min_ce_len = 0,
        .max_ce_len = 0,
    };

    int rc = ble_gap_connect(g_own_addr_type, &peer_addr, 30000,
                             &conn_params, gap_event_cb, NULL);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_gap_connect failed: rc=%d", rc);
        return make_error_with_rc(ctx, RSP_ERR_BLE, rc);
    }

    ESP_LOGI(TAG, "connect initiated");
    return make_ok(ctx);
}

/**
 * Disconnect by connection handle.
 * Request: <<OP_DISCONNECT, Handle:16/little>>
 */
static term handle_disconnect(Context *ctx, const uint8_t *data, size_t len)
{
    if (!g_ble_initialized) {
        return make_error(ctx, RSP_ERR_STATE);
    }
    if (len < 3) { // opcode + handle(2)
        return make_error(ctx, RSP_ERR_ARGS);
    }

    uint16_t handle = data[1] | ((uint16_t)data[2] << 8);
    int rc = ble_gap_terminate(handle, BLE_ERR_REM_USER_CONN_TERM);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_gap_terminate failed: %d", rc);
        return make_error(ctx, RSP_ERR_BLE);
    }
    return make_ok(ctx);
}

/**
 * Initiate security (pairing/bonding) on an active connection.
 * Request: <<OP_SECURITY, Handle:16/little>>
 */
static term handle_security(Context *ctx, const uint8_t *data, size_t len)
{
    if (!g_ble_initialized) {
        return make_error(ctx, RSP_ERR_STATE);
    }
    if (len < 3) { // opcode + handle(2)
        return make_error(ctx, RSP_ERR_ARGS);
    }

    uint16_t handle = data[1] | ((uint16_t)data[2] << 8);
    int rc = ble_gap_security_initiate(handle);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_gap_security_initiate failed: %d", rc);
        return make_error(ctx, RSP_ERR_BLE);
    }
    ESP_LOGI(TAG, "security initiated: handle=%u", handle);
    return make_ok(ctx);
}

/**
 * Update connection parameters on an active connection.
 * Used after bonding to switch from fast (pairing) to slow (WiFi-friendly) params.
 * Request: <<OP_UPDATE_PARAMS, Handle:16/little>>
 */
static term handle_update_params(Context *ctx, const uint8_t *data, size_t len)
{
    if (!g_ble_initialized) {
        return make_error(ctx, RSP_ERR_STATE);
    }
    if (len < 3) { // opcode + handle(2)
        return make_error(ctx, RSP_ERR_ARGS);
    }

    uint16_t handle = data[1] | ((uint16_t)data[2] << 8);

    struct ble_gap_upd_params params = {
        .itvl_min = 320,              // 400ms — WiFi-friendly
        .itvl_max = 640,              // 800ms
        .latency = 4,                 // skip up to 4 events when idle
        .supervision_timeout = 1000,  // 10s
        .min_ce_len = 0,
        .max_ce_len = 0,
    };

    int rc = ble_gap_update_params(handle, &params);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_gap_update_params failed: %d", rc);
        return make_error(ctx, RSP_ERR_BLE);
    }
    ESP_LOGI(TAG, "conn params update requested: handle=%u itvl=320-640", handle);
    return make_ok(ctx);
}

/**
 * GATT Read by UUID (async).
 * Request: <<OP_GATT_READ, ConnHandle:16/little, ChrUUID:16/bytes>>
 * Response: <<RSP_OK>> immediately.
 * Result sent async as: {ble_gatt_read, ConnHandle, Status, Data}
 */
static term handle_gatt_read(Context *ctx, const uint8_t *data, size_t len)
{
    // opcode(1) + conn_handle(2) + char_uuid(16) = 19 minimum
    // For backward compat also accept svc_uuid(16) + char_uuid(16) = 35
    if (len < 19) {
        return make_error(ctx, RSP_ERR_ARGS);
    }

    uint16_t conn_handle = data[1] | ((uint16_t)data[2] << 8);

    // ChrUUID is at offset 19 if SvcUUID present (35-byte format),
    // or at offset 3 if only ChrUUID present (19-byte format)
    const uint8_t *chr_uuid_be;
    if (len >= 35) {
        chr_uuid_be = &data[19];  // skip SvcUUID for backward compat
    } else {
        chr_uuid_be = &data[3];
    }

    ble_uuid128_t char_uuid;
    uuid128_from_be(chr_uuid_be, &char_uuid);

    g_async_read_len = 0;

    int rc = ble_gattc_read_by_uuid(conn_handle,
                                    1, 0xFFFF,
                                    &char_uuid.u,
                                    gatt_read_by_uuid_cb, NULL);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_gattc_read_by_uuid failed: %d", rc);
        return make_error(ctx, RSP_ERR_BLE);
    }

    return make_ok(ctx);
}

/**
 * GATT Write (async, takes ValHandle directly).
 * Request: <<OP_GATT_WRITE, ConnHandle:16/little, ValHandle:16/little, Value/bytes>>
 * Response: <<RSP_OK>> immediately.
 * Result sent async as: {ble_gatt_write, ConnHandle, Status}
 *
 * GATT Write No-Response (sync, takes ValHandle directly).
 * Request: <<OP_GATT_WRITE_NR, ConnHandle:16/little, ValHandle:16/little, Value/bytes>>
 * Response: <<RSP_OK>> immediately (no async result).
 */
static term handle_gatt_write(Context *ctx, const uint8_t *data, size_t len, bool with_response)
{
    // opcode(1) + conn_handle(2) + val_handle(2) + value(1+) = 6 minimum
    if (len < 6) {
        return make_error(ctx, RSP_ERR_ARGS);
    }

    uint16_t conn_handle = data[1] | ((uint16_t)data[2] << 8);
    uint16_t val_handle  = data[3] | ((uint16_t)data[4] << 8);
    const uint8_t *value = &data[5];
    size_t value_len = len - 5;

    int rc;
    if (with_response) {
        rc = ble_gattc_write_flat(conn_handle, val_handle,
                                  value, value_len, gatt_write_cb, NULL);
        if (rc != 0) {
            ESP_LOGE(TAG, "ble_gattc_write_flat failed: %d", rc);
            return make_error(ctx, RSP_ERR_BLE);
        }
    } else {
        rc = ble_gattc_write_no_rsp_flat(conn_handle, val_handle,
                                         value, value_len);
        if (rc != 0) {
            ESP_LOGE(TAG, "ble_gattc_write_no_rsp_flat failed: %d", rc);
            return make_error(ctx, RSP_ERR_BLE);
        }
    }

    return make_ok(ctx);
}

/**
 * Discover all characteristics on a connection (async).
 * Request: <<OP_DISC_SVCS, ConnHandle:16/little>>
 * Response: <<RSP_OK>> immediately.
 * Result sent async as: {ble_disc_complete, ConnHandle, Status, Data}
 * where Data = <<Count:16/little, (ChrUUID:16/bytes, ValHandle:16/little, Props:8)*>>
 */
static term handle_disc_svcs(Context *ctx, const uint8_t *data, size_t len)
{
    if (len < 3) {  // opcode + conn_handle(2)
        return make_error(ctx, RSP_ERR_ARGS);
    }

    uint16_t conn_handle = data[1] | ((uint16_t)data[2] << 8);

    g_disc_count = 0;
    g_disc_conn_handle = conn_handle;

    int rc = ble_gattc_disc_all_chrs(conn_handle, 1, 0xFFFF,
                                     disc_all_chrs_cb, NULL);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_gattc_disc_all_chrs failed: %d", rc);
        return make_error(ctx, RSP_ERR_BLE);
    }

    return make_ok(ctx);
}

// ─────────────────────────────────────────────────────────────────────────────
// Port message dispatch
// ─────────────────────────────────────────────────────────────────────────────

static term handle_call(Context *ctx, term req, term caller_pid)
{
    if (!term_is_binary(req)) {
        return make_error(ctx, RSP_ERR_ARGS);
    }

    const uint8_t *data = (const uint8_t *) term_binary_data(req);
    size_t len = term_binary_size(req);

    if (len < 1) {
        return make_error(ctx, RSP_ERR_ARGS);
    }

    uint8_t opcode = data[0];

    switch (opcode) {
    case OP_INIT:
        return handle_init(ctx);

    case OP_SCAN_START:
        return handle_scan_start(ctx, data, len);

    case OP_SCAN_STOP:
        return handle_scan_stop(ctx);

    case OP_SUBSCRIBE_SCAN:
        return handle_subscribe_scan(ctx, caller_pid);

    case OP_CONNECT:
        return handle_connect(ctx, data, len);

    case OP_DISCONNECT:
        return handle_disconnect(ctx, data, len);

    case OP_SECURITY:
        return handle_security(ctx, data, len);

    case OP_UPDATE_PARAMS:
        return handle_update_params(ctx, data, len);

    case OP_GATT_READ:
        return handle_gatt_read(ctx, data, len);

    case OP_GATT_WRITE:
        return handle_gatt_write(ctx, data, len, true);

    case OP_GATT_WRITE_NR:
        return handle_gatt_write(ctx, data, len, false);

    case OP_DISC_SVCS:
        return handle_disc_svcs(ctx, data, len);

    default:
        return make_error(ctx, RSP_ERR_ARGS);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// AtomVM port driver interface
// ─────────────────────────────────────────────────────────────────────────────

static NativeHandlerResult ble_port_native_handler(Context *ctx)
{
    term msg;

    if (!mailbox_peek(ctx, &msg)) {
        return NativeContinue;
    }

    mailbox_remove_message(&ctx->mailbox, &ctx->heap);

    GenMessage gen_message;
    enum GenMessageParseResult parse_result = port_parse_gen_message(msg, &gen_message);

    if (parse_result != GenCallMessage) {
        return NativeContinue;
    }

    term reply = handle_call(ctx, gen_message.req, gen_message.pid);
    port_send_reply(ctx, gen_message.pid, gen_message.ref, reply);

    return NativeContinue;
}

void ble_port_init(GlobalContext *global)
{
    (void) global;
    TRACE("ble_port_init\n");
}

void ble_port_destroy(GlobalContext *global)
{
    (void) global;
    TRACE("ble_port_destroy\n");
}

Context *ble_port_create_port(GlobalContext *global, term opts)
{
    (void) opts;

    Context *ctx = context_new(global);
    if (!ctx) {
        return NULL;
    }

    ctx->native_handler = ble_port_native_handler;
    g_global = global;
    return ctx;
}

REGISTER_PORT_DRIVER(ble_port, ble_port_init, ble_port_destroy, ble_port_create_port);

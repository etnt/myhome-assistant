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
#include "freertos/semphr.h"

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

    // GATT operations
    OP_GATT_READ    = 0x30,
    OP_GATT_WRITE   = 0x31,
    OP_GATT_WRITE_NR = 0x32,  // write no-response
    OP_SUBSCRIBE    = 0x33,
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
// Synchronization for async BLE operations
// ─────────────────────────────────────────────────────────────────────────────

static SemaphoreHandle_t g_op_sem;      // signals operation completion
static SemaphoreHandle_t g_data_lock;   // protects shared state
static int g_op_rc;                     // result code from async op

// GATT read result buffer
#define MAX_GATT_READ 128
#define GATT_TIMEOUT_MS 10000
static uint8_t g_read_buf[MAX_GATT_READ];
static uint16_t g_read_len;

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

    default:
        return 0;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// NimBLE: GATT client callbacks
// ─────────────────────────────────────────────────────────────────────────────

static int gatt_read_cb(uint16_t conn_handle,
                        const struct ble_gatt_error *error,
                        struct ble_gatt_attr *attr, void *arg)
{
    (void) conn_handle;
    (void) arg;

    if (error->status == 0) {
        g_read_len = OS_MBUF_PKTLEN(attr->om);
        if (g_read_len > MAX_GATT_READ) {
            g_read_len = MAX_GATT_READ;
        }
        os_mbuf_copydata(attr->om, 0, g_read_len, g_read_buf);
        g_op_rc = 0;
    } else {
        g_op_rc = error->status;
        g_read_len = 0;
    }

    xSemaphoreGive(g_op_sem);
    return 0;
}

static int gatt_write_cb(uint16_t conn_handle,
                         const struct ble_gatt_error *error,
                         struct ble_gatt_attr *attr, void *arg)
{
    (void) conn_handle;
    (void) attr;
    (void) arg;

    g_op_rc = error->status;
    xSemaphoreGive(g_op_sem);
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

    g_op_sem = xSemaphoreCreateBinary();
    g_data_lock = xSemaphoreCreateMutex();

    nimble_port_init();

    // Configure security: enable bonding, MITM not required, Legacy Pairing
    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.sm_io_cap = BLE_SM_IO_CAP_NO_IO;
    ble_hs_cfg.sm_bonding = 1;
    ble_hs_cfg.sm_mitm = 0;
    ble_hs_cfg.sm_sc = 0;  // Legacy Pairing — required by some Hue firmware
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

    struct ble_gap_disc_params params;
    memset(&params, 0, sizeof(params));
    params.passive = 0;  // active scan to get names
    params.itvl = 0x0100;   // 160ms interval — leaves gaps for WiFi
    params.window = 0x0030;  // 30ms window — ~19% BLE duty cycle
    params.filter_duplicates = 0;

    int32_t duration_ms = (int32_t) duration_sec * 1000;
    int rc = ble_gap_disc(g_own_addr_type, duration_ms, &params, gap_event_cb, NULL);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_gap_disc failed: %d", rc);
        return make_error(ctx, RSP_ERR_BLE);
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

    int rc = ble_gap_connect(g_own_addr_type, &peer_addr, 30000,
                             NULL, gap_event_cb, NULL);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_gap_connect failed: %d", rc);
        return make_error(ctx, RSP_ERR_BLE);
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
 * GATT Read by UUID.
 * Request: <<OP_GATT_READ, ConnHandle:16/little, ServiceUUID:16/bytes, CharUUID:16/bytes>>
 * Response: <<RSP_OK, Data/bytes>>
 *
 * Uses ble_gattc_read_long with service discovery. For simplicity,
 * we read using the characteristic UUID directly with ble_gattc_read_by_uuid.
 */
static int gatt_read_by_uuid_cb(uint16_t conn_handle,
                                const struct ble_gatt_error *error,
                                struct ble_gatt_attr *attr, void *arg)
{
    (void) conn_handle;
    (void) arg;

    if (error->status == 0 && attr != NULL) {
        g_read_len = OS_MBUF_PKTLEN(attr->om);
        if (g_read_len > MAX_GATT_READ) {
            g_read_len = MAX_GATT_READ;
        }
        os_mbuf_copydata(attr->om, 0, g_read_len, g_read_buf);
        g_op_rc = 0;
        // Don't signal yet — wait for the completion call (status != 0)
        return 0;
    }

    // Final callback with status indicating end
    if (error->status == BLE_HS_EDONE) {
        // Already got the data in a previous call
        if (g_read_len == 0) {
            g_op_rc = BLE_HS_ENOENT;
        }
    } else if (error->status != 0) {
        g_op_rc = error->status;
        g_read_len = 0;
    }

    xSemaphoreGive(g_op_sem);
    return 0;
}

static term handle_gatt_read(Context *ctx, const uint8_t *data, size_t len)
{
    // opcode(1) + conn_handle(2) + service_uuid(16) + char_uuid(16) = 35
    if (len < 35) {
        return make_error(ctx, RSP_ERR_ARGS);
    }

    uint16_t conn_handle = data[1] | ((uint16_t)data[2] << 8);

    ble_uuid128_t char_uuid;
    uuid128_from_be(&data[19], &char_uuid);  // char UUID at offset 3+16=19

    g_read_len = 0;
    g_op_rc = -1;

    // Drain any stale semaphore from a previous timed-out operation
    xSemaphoreTake(g_op_sem, 0);

    int rc = ble_gattc_read_by_uuid(conn_handle,
                                    1, 0xFFFF,  // search all handles
                                    &char_uuid.u,
                                    gatt_read_by_uuid_cb, NULL);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_gattc_read_by_uuid failed: %d", rc);
        return make_error(ctx, RSP_ERR_BLE);
    }

    if (xSemaphoreTake(g_op_sem, pdMS_TO_TICKS(GATT_TIMEOUT_MS)) != pdTRUE) {
        return make_error(ctx, RSP_ERR_TIMEOUT);
    }

    if (g_op_rc != 0) {
        uint8_t err = (uint8_t) g_op_rc;
        return make_response(ctx, RSP_ERR, &err, 1);
    }

    return make_ok_payload(ctx, g_read_buf, g_read_len);
}

/**
 * GATT Write (with response).
 * Request: <<OP_GATT_WRITE, ConnHandle:16/little, ServiceUUID:16/bytes, CharUUID:16/bytes, Value/bytes>>
 *
 * We discover the characteristic handle first via disc_all_chrs, then write.
 * For simplicity, we use a two-step approach: discover handle, then write.
 */

// State for characteristic handle discovery
static uint16_t g_disc_char_handle;
static ble_uuid128_t g_disc_target_uuid;

static int disc_chr_cb(uint16_t conn_handle,
                       const struct ble_gatt_error *error,
                       const struct ble_gatt_chr *chr, void *arg)
{
    (void) conn_handle;
    (void) arg;

    if (error->status == 0 && chr != NULL) {
        if (ble_uuid_cmp(&chr->uuid.u, &g_disc_target_uuid.u) == 0) {
            g_disc_char_handle = chr->val_handle;
            g_op_rc = 0;
        }
        return 0;
    }

    // Discovery complete
    if (error->status == BLE_HS_EDONE) {
        if (g_disc_char_handle == 0) {
            g_op_rc = BLE_HS_ENOENT;
        }
    } else {
        g_op_rc = error->status;
    }

    xSemaphoreGive(g_op_sem);
    return 0;
}

static int discover_char_handle(uint16_t conn_handle, const uint8_t *svc_uuid_be,
                                const uint8_t *chr_uuid_be, uint16_t *out_handle)
{
    ble_uuid128_t svc_uuid;
    uuid128_from_be(svc_uuid_be, &svc_uuid);
    uuid128_from_be(chr_uuid_be, &g_disc_target_uuid);

    g_disc_char_handle = 0;
    g_op_rc = -1;

    // Drain any stale semaphore from a previous timed-out operation
    xSemaphoreTake(g_op_sem, 0);

    int rc = ble_gattc_disc_all_chrs(conn_handle, 1, 0xFFFF, disc_chr_cb, NULL);
    if (rc != 0) {
        return rc;
    }

    if (xSemaphoreTake(g_op_sem, pdMS_TO_TICKS(GATT_TIMEOUT_MS)) != pdTRUE) {
        return BLE_HS_ETIMEOUT;
    }

    if (g_op_rc != 0) {
        return g_op_rc;
    }

    *out_handle = g_disc_char_handle;
    return 0;
}

static term handle_gatt_write(Context *ctx, const uint8_t *data, size_t len, bool with_response)
{
    // opcode(1) + conn_handle(2) + service_uuid(16) + char_uuid(16) + value(1+)
    if (len < 36) {
        return make_error(ctx, RSP_ERR_ARGS);
    }

    uint16_t conn_handle = data[1] | ((uint16_t)data[2] << 8);

    const uint8_t *svc_uuid = &data[3];
    const uint8_t *chr_uuid = &data[19];
    const uint8_t *value = &data[35];
    size_t value_len = len - 35;

    // Discover the characteristic handle
    uint16_t val_handle;
    int rc = discover_char_handle(conn_handle, svc_uuid, chr_uuid, &val_handle);
    if (rc != 0) {
        ESP_LOGE(TAG, "characteristic discovery failed: %d", rc);
        return make_error(ctx, RSP_ERR_BLE);
    }

    if (with_response) {
        g_op_rc = -1;

        // Drain any stale semaphore from a previous timed-out operation
        xSemaphoreTake(g_op_sem, 0);

        rc = ble_gattc_write_flat(conn_handle, val_handle,
                                  value, value_len, gatt_write_cb, NULL);
        if (rc != 0) {
            ESP_LOGE(TAG, "ble_gattc_write_flat failed: %d", rc);
            return make_error(ctx, RSP_ERR_BLE);
        }

        if (xSemaphoreTake(g_op_sem, pdMS_TO_TICKS(GATT_TIMEOUT_MS)) != pdTRUE) {
            return make_error(ctx, RSP_ERR_TIMEOUT);
        }

        if (g_op_rc != 0) {
            return make_error(ctx, RSP_ERR_BLE);
        }
    } else {
        // Write without response (faster, used for light control)
        rc = ble_gattc_write_no_rsp_flat(conn_handle, val_handle,
                                         value, value_len);
        if (rc != 0) {
            ESP_LOGE(TAG, "ble_gattc_write_no_rsp_flat failed: %d", rc);
            return make_error(ctx, RSP_ERR_BLE);
        }
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

    case OP_GATT_READ:
        return handle_gatt_read(ctx, data, len);

    case OP_GATT_WRITE:
        return handle_gatt_write(ctx, data, len, true);

    case OP_GATT_WRITE_NR:
        return handle_gatt_write(ctx, data, len, false);

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

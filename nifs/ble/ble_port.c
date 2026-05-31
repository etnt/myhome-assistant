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
    OP_SCAN_RESULTS = 0x12,

    // Connection
    OP_CONNECT      = 0x20,
    OP_DISCONNECT   = 0x21,
    OP_CONN_STATE   = 0x22,

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
// Connection state
// ─────────────────────────────────────────────────────────────────────────────

#define MAX_CONNECTIONS 2
#define OP_TIMEOUT_MS   10000  // 10s timeout for BLE operations

typedef enum {
    CONN_STATE_IDLE = 0,
    CONN_STATE_CONNECTING,
    CONN_STATE_CONNECTED,
    CONN_STATE_BONDED,
} conn_state_t;

typedef struct {
    bool in_use;
    uint8_t addr[6];
    uint8_t addr_type;
    uint16_t conn_handle;
    conn_state_t state;
} connection_t;

static connection_t g_conns[MAX_CONNECTIONS];

// ─────────────────────────────────────────────────────────────────────────────
// Scan results cache
// ─────────────────────────────────────────────────────────────────────────────

#define MAX_SCAN_RESULTS 16
#define MAX_NAME_LEN     32

typedef struct {
    bool in_use;
    uint8_t addr[6];
    uint8_t addr_type;
    int8_t rssi;
    char name[MAX_NAME_LEN];
    uint8_t name_len;
} scan_result_t;

static scan_result_t g_scan_results[MAX_SCAN_RESULTS];
static int g_scan_count = 0;
static bool g_scanning = false;

// ─────────────────────────────────────────────────────────────────────────────
// Synchronization for async BLE operations
// ─────────────────────────────────────────────────────────────────────────────

static SemaphoreHandle_t g_op_sem;      // signals operation completion
static SemaphoreHandle_t g_data_lock;   // protects shared state
static int g_op_rc;                     // result code from async op

// GATT read result buffer
#define MAX_GATT_READ 128
static uint8_t g_read_buf[MAX_GATT_READ];
static uint16_t g_read_len;

// NimBLE state
static bool g_ble_initialized = false;
static uint8_t g_own_addr_type;

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
// Connection management
// ─────────────────────────────────────────────────────────────────────────────

static int conn_find_by_addr(const uint8_t addr[6])
{
    for (int i = 0; i < MAX_CONNECTIONS; i++) {
        if (g_conns[i].in_use && memcmp(g_conns[i].addr, addr, 6) == 0) {
            return i;
        }
    }
    return -1;
}

static int conn_find_by_handle(uint16_t handle)
{
    for (int i = 0; i < MAX_CONNECTIONS; i++) {
        if (g_conns[i].in_use && g_conns[i].conn_handle == handle) {
            return i;
        }
    }
    return -1;
}

static int conn_alloc(const uint8_t addr[6], uint8_t addr_type)
{
    // Check if already exists
    int idx = conn_find_by_addr(addr);
    if (idx >= 0) {
        return idx;
    }
    // Allocate new slot
    for (int i = 0; i < MAX_CONNECTIONS; i++) {
        if (!g_conns[i].in_use) {
            memset(&g_conns[i], 0, sizeof(connection_t));
            g_conns[i].in_use = true;
            memcpy(g_conns[i].addr, addr, 6);
            g_conns[i].addr_type = addr_type;
            g_conns[i].state = CONN_STATE_IDLE;
            return i;
        }
    }
    return -1;
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

static void scan_add_result(const struct ble_gap_disc_desc *desc)
{
    char name[MAX_NAME_LEN] = {0};
    uint8_t name_len = 0;
    parse_adv_name(desc->data, desc->length_data, name, &name_len);

    xSemaphoreTake(g_data_lock, portMAX_DELAY);

    // Update existing or add new
    for (int i = 0; i < g_scan_count; i++) {
        if (memcmp(g_scan_results[i].addr, desc->addr.val, 6) == 0) {
            g_scan_results[i].rssi = desc->rssi;
            if (name_len > 0) {
                memcpy(g_scan_results[i].name, name, name_len + 1);
                g_scan_results[i].name_len = name_len;
            }
            xSemaphoreGive(g_data_lock);
            return;
        }
    }

    if (g_scan_count < MAX_SCAN_RESULTS) {
        scan_result_t *r = &g_scan_results[g_scan_count];
        memcpy(r->addr, desc->addr.val, 6);
        r->addr_type = desc->addr.type;
        r->rssi = desc->rssi;
        r->in_use = true;
        if (name_len > 0) {
            memcpy(r->name, name, name_len + 1);
            r->name_len = name_len;
        }
        g_scan_count++;
    }

    xSemaphoreGive(g_data_lock);
}

// ─────────────────────────────────────────────────────────────────────────────
// NimBLE: GAP event handler
// ─────────────────────────────────────────────────────────────────────────────

static int gap_event_cb(struct ble_gap_event *event, void *arg)
{
    (void) arg;

    switch (event->type) {

    case BLE_GAP_EVENT_DISC:
        scan_add_result(&event->disc);
        return 0;

    case BLE_GAP_EVENT_DISC_COMPLETE:
        ESP_LOGI(TAG, "scan complete");
        g_scanning = false;
        return 0;

    case BLE_GAP_EVENT_CONNECT: {
        uint16_t handle = event->connect.conn_handle;
        int status = event->connect.status;
        ESP_LOGI(TAG, "connect event: handle=%u status=%d", handle, status);

        if (status == 0) {
            // Find the connecting entry and update its handle
            for (int i = 0; i < MAX_CONNECTIONS; i++) {
                if (g_conns[i].in_use && g_conns[i].state == CONN_STATE_CONNECTING) {
                    g_conns[i].conn_handle = handle;
                    g_conns[i].state = CONN_STATE_CONNECTED;
                    break;
                }
            }
            // Initiate security (pairing/bonding) — Hue bulbs require it
            ble_gap_security_initiate(handle);
        }

        g_op_rc = status;
        xSemaphoreGive(g_op_sem);
        return 0;
    }

    case BLE_GAP_EVENT_DISCONNECT: {
        uint16_t handle = event->disconnect.conn.conn_handle;
        ESP_LOGI(TAG, "disconnect: handle=%u reason=%d",
                 handle, event->disconnect.reason);

        int idx = conn_find_by_handle(handle);
        if (idx >= 0) {
            g_conns[idx].state = CONN_STATE_IDLE;
            g_conns[idx].conn_handle = 0;
        }
        return 0;
    }

    case BLE_GAP_EVENT_ENC_CHANGE: {
        uint16_t handle = event->enc_change.conn_handle;
        int status = event->enc_change.status;
        ESP_LOGI(TAG, "encryption change: handle=%u status=%d", handle, status);

        if (status == 0) {
            int idx = conn_find_by_handle(handle);
            if (idx >= 0) {
                g_conns[idx].state = CONN_STATE_BONDED;
            }
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

    memset(g_conns, 0, sizeof(g_conns));
    memset(g_scan_results, 0, sizeof(g_scan_results));
    g_scan_count = 0;

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

    // Clear previous results
    xSemaphoreTake(g_data_lock, portMAX_DELAY);
    memset(g_scan_results, 0, sizeof(g_scan_results));
    g_scan_count = 0;
    xSemaphoreGive(g_data_lock);

    // Optional: duration in seconds (default=10)
    uint8_t duration_sec = 10;
    if (len >= 2) {
        duration_sec = data[1];
    }

    struct ble_gap_disc_params params;
    memset(&params, 0, sizeof(params));
    params.passive = 0;  // active scan to get names
    params.itvl = 0x0010;
    params.window = 0x0010;
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
 * Returns scan results as binary:
 * <<Count:8, [<<Addr:6/bytes, AddrType:8, RSSI:8/signed, NameLen:8, Name/bytes>>]>>
 */
static term handle_scan_results(Context *ctx)
{
    if (!g_ble_initialized) {
        return make_error(ctx, RSP_ERR_STATE);
    }

    xSemaphoreTake(g_data_lock, portMAX_DELAY);

    // Calculate total size
    size_t total = 1; // count byte
    for (int i = 0; i < g_scan_count; i++) {
        total += 6 + 1 + 1 + 1 + g_scan_results[i].name_len; // addr + addr_type + rssi + name_len + name
    }

    term bin = term_create_uninitialized_binary(1 + total, &ctx->heap, ctx->global);
    uint8_t *out = (uint8_t *) term_binary_data(bin);
    out[0] = RSP_OK;

    uint8_t *p = out + 1;
    *p++ = (uint8_t) g_scan_count;

    for (int i = 0; i < g_scan_count; i++) {
        scan_result_t *r = &g_scan_results[i];
        memcpy(p, r->addr, 6); p += 6;
        *p++ = r->addr_type;
        *p++ = (uint8_t) r->rssi;
        *p++ = r->name_len;
        if (r->name_len > 0) {
            memcpy(p, r->name, r->name_len);
            p += r->name_len;
        }
    }

    xSemaphoreGive(g_data_lock);
    return bin;
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

    int idx = conn_alloc(addr, addr_type);
    if (idx < 0) {
        ESP_LOGE(TAG, "no free connection slots");
        return make_error(ctx, RSP_ERR_NOMEM);
    }

    // If already connected, return ok
    if (g_conns[idx].state >= CONN_STATE_CONNECTED) {
        uint8_t payload[1] = { (uint8_t) idx };
        return make_ok_payload(ctx, payload, 1);
    }

    g_conns[idx].state = CONN_STATE_CONNECTING;

    ble_addr_t peer_addr;
    peer_addr.type = addr_type;
    memcpy(peer_addr.val, addr, 6);

    int rc = ble_gap_connect(g_own_addr_type, &peer_addr, OP_TIMEOUT_MS,
                             NULL, gap_event_cb, NULL);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_gap_connect failed: %d", rc);
        g_conns[idx].state = CONN_STATE_IDLE;
        return make_error(ctx, RSP_ERR_BLE);
    }

    // Wait for connect event
    if (xSemaphoreTake(g_op_sem, pdMS_TO_TICKS(OP_TIMEOUT_MS)) != pdTRUE) {
        ESP_LOGE(TAG, "connect timeout");
        ble_gap_conn_cancel();
        g_conns[idx].state = CONN_STATE_IDLE;
        return make_error(ctx, RSP_ERR_TIMEOUT);
    }

    if (g_op_rc != 0) {
        ESP_LOGE(TAG, "connect failed: rc=%d", g_op_rc);
        g_conns[idx].state = CONN_STATE_IDLE;
        return make_error(ctx, RSP_ERR_BLE);
    }

    // Connection established. Return conn index.
    uint8_t payload[1] = { (uint8_t) idx };
    ESP_LOGI(TAG, "connected: slot=%d handle=%u", idx, g_conns[idx].conn_handle);
    return make_ok_payload(ctx, payload, 1);
}

/**
 * Disconnect.
 * Request: <<OP_DISCONNECT, ConnIdx:8>>
 */
static term handle_disconnect(Context *ctx, const uint8_t *data, size_t len)
{
    if (len < 2) {
        return make_error(ctx, RSP_ERR_ARGS);
    }

    uint8_t idx = data[1];
    if (idx >= MAX_CONNECTIONS || !g_conns[idx].in_use) {
        return make_error(ctx, RSP_ERR_ARGS);
    }

    if (g_conns[idx].state >= CONN_STATE_CONNECTED) {
        ble_gap_terminate(g_conns[idx].conn_handle, BLE_ERR_REM_USER_CONN_TERM);
    }

    g_conns[idx].state = CONN_STATE_IDLE;
    g_conns[idx].in_use = false;
    return make_ok(ctx);
}

/**
 * Get connection state.
 * Request: <<OP_CONN_STATE, ConnIdx:8>>
 * Response: <<RSP_OK, State:8>>
 */
static term handle_conn_state(Context *ctx, const uint8_t *data, size_t len)
{
    if (len < 2) {
        return make_error(ctx, RSP_ERR_ARGS);
    }

    uint8_t idx = data[1];
    if (idx >= MAX_CONNECTIONS || !g_conns[idx].in_use) {
        return make_error(ctx, RSP_ERR_ARGS);
    }

    uint8_t state = (uint8_t) g_conns[idx].state;
    return make_ok_payload(ctx, &state, 1);
}

/**
 * GATT Read by UUID.
 * Request: <<OP_GATT_READ, ConnIdx:8, ServiceUUID:16/bytes, CharUUID:16/bytes>>
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
    // opcode(1) + conn_idx(1) + service_uuid(16) + char_uuid(16) = 34
    if (len < 34) {
        return make_error(ctx, RSP_ERR_ARGS);
    }

    uint8_t idx = data[1];
    if (idx >= MAX_CONNECTIONS || !g_conns[idx].in_use ||
        g_conns[idx].state < CONN_STATE_CONNECTED) {
        return make_error(ctx, RSP_ERR_STATE);
    }

    ble_uuid128_t char_uuid;
    uuid128_from_be(&data[18], &char_uuid);  // char UUID at offset 18

    g_read_len = 0;
    g_op_rc = -1;

    int rc = ble_gattc_read_by_uuid(g_conns[idx].conn_handle,
                                    1, 0xFFFF,  // search all handles
                                    &char_uuid.u,
                                    gatt_read_by_uuid_cb, NULL);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_gattc_read_by_uuid failed: %d", rc);
        return make_error(ctx, RSP_ERR_BLE);
    }

    if (xSemaphoreTake(g_op_sem, pdMS_TO_TICKS(OP_TIMEOUT_MS)) != pdTRUE) {
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
 * Request: <<OP_GATT_WRITE, ConnIdx:8, ServiceUUID:16/bytes, CharUUID:16/bytes, Value/bytes>>
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

    int rc = ble_gattc_disc_all_chrs(conn_handle, 1, 0xFFFF, disc_chr_cb, NULL);
    if (rc != 0) {
        return rc;
    }

    if (xSemaphoreTake(g_op_sem, pdMS_TO_TICKS(OP_TIMEOUT_MS)) != pdTRUE) {
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
    // opcode(1) + conn_idx(1) + service_uuid(16) + char_uuid(16) + value(1+)
    if (len < 35) {
        return make_error(ctx, RSP_ERR_ARGS);
    }

    uint8_t idx = data[1];
    if (idx >= MAX_CONNECTIONS || !g_conns[idx].in_use ||
        g_conns[idx].state < CONN_STATE_CONNECTED) {
        return make_error(ctx, RSP_ERR_STATE);
    }

    const uint8_t *svc_uuid = &data[2];
    const uint8_t *chr_uuid = &data[18];
    const uint8_t *value = &data[34];
    size_t value_len = len - 34;

    // Discover the characteristic handle
    uint16_t val_handle;
    int rc = discover_char_handle(g_conns[idx].conn_handle, svc_uuid, chr_uuid, &val_handle);
    if (rc != 0) {
        ESP_LOGE(TAG, "characteristic discovery failed: %d", rc);
        return make_error(ctx, RSP_ERR_BLE);
    }

    if (with_response) {
        g_op_rc = -1;
        rc = ble_gattc_write_flat(g_conns[idx].conn_handle, val_handle,
                                  value, value_len, gatt_write_cb, NULL);
        if (rc != 0) {
            ESP_LOGE(TAG, "ble_gattc_write_flat failed: %d", rc);
            return make_error(ctx, RSP_ERR_BLE);
        }

        if (xSemaphoreTake(g_op_sem, pdMS_TO_TICKS(OP_TIMEOUT_MS)) != pdTRUE) {
            return make_error(ctx, RSP_ERR_TIMEOUT);
        }

        if (g_op_rc != 0) {
            return make_error(ctx, RSP_ERR_BLE);
        }
    } else {
        // Write without response (faster, used for light control)
        rc = ble_gattc_write_no_rsp_flat(g_conns[idx].conn_handle, val_handle,
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

static term handle_call(Context *ctx, term req)
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

    case OP_SCAN_RESULTS:
        return handle_scan_results(ctx);

    case OP_CONNECT:
        return handle_connect(ctx, data, len);

    case OP_DISCONNECT:
        return handle_disconnect(ctx, data, len);

    case OP_CONN_STATE:
        return handle_conn_state(ctx, data, len);

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

    term reply = handle_call(ctx, gen_message.req);
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
    return ctx;
}

REGISTER_PORT_DRIVER(ble_port, ble_port_init, ble_port_destroy, ble_port_create_port);

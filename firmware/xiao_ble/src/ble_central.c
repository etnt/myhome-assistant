/**
 * ble_central.c — BLE Central role: scanning (Phase 2).
 *
 * Handles BLE scan start/stop and queues scan results as events
 * for the ESP32 to drain via I2C.
 */

#include <zephyr/kernel.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/hci.h>
#include <zephyr/settings/settings.h>
#include <zephyr/logging/log.h>
#include <string.h>

#include "ble_central.h"
#include "i2c_target.h"
#include "event_queue.h"

LOG_MODULE_REGISTER(ble_central, LOG_LEVEL_INF);

static volatile bool scanning;
static struct k_work_delayable scan_timeout_work;

/* Scan parameters: active scan, 100ms interval, 50ms window, filter duplicates */
static const struct bt_le_scan_param scan_params = {
    .type = BT_LE_SCAN_TYPE_ACTIVE,
    .options = BT_LE_SCAN_OPT_FILTER_DUPLICATE,
    .interval = BT_GAP_SCAN_FAST_INTERVAL,  /* 60ms */
    .window = BT_GAP_SCAN_FAST_WINDOW,      /* 30ms */
};

/**
 * Called for each advertising report during a scan.
 * Queues EVT_SCAN_RESULT with: [addr 6B, addr_type, rssi, name_len, name...]
 */
static void scan_recv_cb(const struct bt_le_scan_recv_info *info,
                         struct net_buf_simple *buf)
{
    /* Extract device name from AD data if present */
    char name[29] = {0};  /* Max BLE short name we can fit in 60B payload */
    uint8_t name_len = 0;

    /* Parse AD structures looking for name */
    struct net_buf_simple_state state;
    net_buf_simple_save(buf, &state);

    while (buf->len > 1) {
        uint8_t ad_len = net_buf_simple_pull_u8(buf);
        if (ad_len == 0 || ad_len > buf->len) {
            break;
        }
        uint8_t ad_type = net_buf_simple_pull_u8(buf);
        ad_len--;  /* type byte consumed */

        if (ad_type == BT_DATA_NAME_COMPLETE || ad_type == BT_DATA_NAME_SHORTENED) {
            name_len = (ad_len < sizeof(name)) ? ad_len : sizeof(name) - 1;
            memcpy(name, buf->data, name_len);
            break;
        }
        net_buf_simple_pull(buf, ad_len);
    }

    net_buf_simple_restore(buf, &state);

    /* Build event payload: [addr 6B, type 1B, rssi 1B (signed), name_len 1B, name...] */
    uint8_t payload[9 + 29];  /* max: 6+1+1+1+29 = 38 bytes */
    uint8_t payload_len = 9 + name_len;

    /* Address (little-endian, 6 bytes) */
    memcpy(&payload[0], info->addr->a.val, 6);
    payload[6] = info->addr->type;
    payload[7] = (uint8_t)(int8_t)info->rssi;
    payload[8] = name_len;
    if (name_len > 0) {
        memcpy(&payload[9], name, name_len);
    }

    event_queue_push(EVT_SCAN_RESULT, payload, payload_len);

    LOG_DBG("Scan: %02x:%02x:%02x:%02x:%02x:%02x rssi=%d name=%s",
            info->addr->a.val[5], info->addr->a.val[4],
            info->addr->a.val[3], info->addr->a.val[2],
            info->addr->a.val[1], info->addr->a.val[0],
            info->rssi, name);
}

static void scan_timeout_handler(struct k_work *work)
{
    if (scanning) {
        LOG_INF("Scan duration elapsed");
        bt_le_scan_stop();
        scanning = false;
        event_queue_push_simple(EVT_SCAN_DONE);
    }
}

static struct bt_le_scan_cb scan_callbacks = {
    .recv = scan_recv_cb,
};

/* Pairing callbacks — forward-declared so ble_central_init() can register them */
static void auth_cancel(struct bt_conn *conn);
static void pairing_complete(struct bt_conn *conn, bool bonded);
static void pairing_failed(struct bt_conn *conn, enum bt_security_err reason);

static struct bt_conn_auth_cb auth_cb = {
    .cancel = auth_cancel,
};

static struct bt_conn_auth_info_cb auth_info_cb = {
    .pairing_complete = pairing_complete,
    .pairing_failed = pairing_failed,
};

int ble_central_init(void)
{
    int err;

    err = bt_enable(NULL);
    if (err) {
        LOG_ERR("BLE init failed: %d", err);
        return err;
    }

    /* Load stored BLE settings (bonds, keys) — required when CONFIG_BT_SETTINGS=y */
    err = settings_load();
    if (err) {
        LOG_WRN("Settings load failed: %d (continuing)", err);
    }

    LOG_INF("BLE stack initialized");

    bt_le_scan_cb_register(&scan_callbacks);
    k_work_init_delayable(&scan_timeout_work, scan_timeout_handler);

    /* Register pairing/auth callbacks */
    bt_conn_auth_cb_register(&auth_cb);
    bt_conn_auth_info_cb_register(&auth_info_cb);

    return 0;
}

int ble_central_scan_start(uint8_t duration_sec)
{
    if (scanning) {
        LOG_WRN("Scan already active, stopping first");
        bt_le_scan_stop();
        k_work_cancel_delayable(&scan_timeout_work);
    }

    int err = bt_le_scan_start(&scan_params, NULL);
    if (err) {
        LOG_ERR("Scan start failed: %d", err);
        return err;
    }

    scanning = true;
    LOG_INF("BLE scan started (duration=%u s)", duration_sec);

    /* Schedule scan timeout */
    if (duration_sec > 0) {
        k_work_schedule(&scan_timeout_work, K_SECONDS(duration_sec));
    }

    return 0;
}

int ble_central_scan_stop(void)
{
    if (!scanning) {
        return -EALREADY;
    }

    k_work_cancel_delayable(&scan_timeout_work);
    bt_le_scan_stop();
    scanning = false;

    event_queue_push_simple(EVT_SCAN_DONE);
    LOG_INF("BLE scan stopped");

    return 0;
}

bool ble_central_is_scanning(void)
{
    return scanning;
}

/*
 * Connection Management (Phase 3)
 */

/* Track active connections: handle → address mapping */
#define MAX_CONNECTIONS CONFIG_BT_MAX_CONN

struct conn_entry {
    struct bt_conn *conn;
    uint16_t handle;
    bt_addr_le_t addr;
    bool bonded;
};

static struct conn_entry connections[MAX_CONNECTIONS];
static uint8_t conn_count;

static struct conn_entry *find_conn_entry(struct bt_conn *conn)
{
    for (int i = 0; i < MAX_CONNECTIONS; i++) {
        if (connections[i].conn == conn) {
            return &connections[i];
        }
    }
    return NULL;
}

static struct conn_entry *find_free_entry(void)
{
    for (int i = 0; i < MAX_CONNECTIONS; i++) {
        if (connections[i].conn == NULL) {
            return &connections[i];
        }
    }
    return NULL;
}

static uint16_t conn_to_handle(struct bt_conn *conn)
{
    struct conn_entry *entry = find_conn_entry(conn);
    return entry ? entry->handle : 0xFFFF;
}

/* Connection callbacks */
static void connected_cb(struct bt_conn *conn, uint8_t err)
{
    char addr_str[BT_ADDR_LE_STR_LEN];
    bt_addr_le_to_str(bt_conn_get_dst(conn), addr_str, sizeof(addr_str));

    if (err) {
        LOG_ERR("Connection failed to %s: %u", addr_str, err);
        /* Queue error event */
        uint8_t payload[1] = {err};
        event_queue_push(EVT_CMD_ERROR, payload, 1);
        return;
    }

    struct conn_entry *entry = find_free_entry();
    if (!entry) {
        LOG_ERR("No free connection slots");
        bt_conn_disconnect(conn, BT_HCI_ERR_REMOTE_USER_TERM_CONN);
        return;
    }

    entry->conn = bt_conn_ref(conn);
    entry->handle = (uint16_t)(entry - connections);  /* index as handle */
    memcpy(&entry->addr, bt_conn_get_dst(conn), sizeof(bt_addr_le_t));
    entry->bonded = false;
    conn_count++;

    LOG_INF("Connected [%u]: %s", entry->handle, addr_str);

    /* Queue EVT_CONNECTED: [handle_lo, handle_hi, addr 6B] */
    uint8_t payload[8];
    payload[0] = entry->handle & 0xFF;
    payload[1] = (entry->handle >> 8) & 0xFF;
    memcpy(&payload[2], entry->addr.a.val, 6);
    event_queue_push(EVT_CONNECTED, payload, 8);
}

static void disconnected_cb(struct bt_conn *conn, uint8_t reason)
{
    struct conn_entry *entry = find_conn_entry(conn);
    if (!entry) {
        return;
    }

    LOG_INF("Disconnected [%u]: reason 0x%02x", entry->handle, reason);

    /* Queue EVT_DISCONNECTED: [handle_lo, handle_hi, reason] */
    uint8_t payload[3];
    payload[0] = entry->handle & 0xFF;
    payload[1] = (entry->handle >> 8) & 0xFF;
    payload[2] = reason;
    event_queue_push(EVT_DISCONNECTED, payload, 3);

    bt_conn_unref(entry->conn);
    memset(entry, 0, sizeof(*entry));
    conn_count--;
}

static void security_changed_cb(struct bt_conn *conn, bt_security_t level,
                                 enum bt_security_err err)
{
    struct conn_entry *entry = find_conn_entry(conn);
    uint16_t handle = entry ? entry->handle : 0xFFFF;

    if (err) {
        LOG_ERR("Security change failed [%u]: err %d", handle, err);
        /* Queue EVT_BOND_COMPLETE with error */
        uint8_t payload[3] = {handle & 0xFF, (handle >> 8) & 0xFF, (uint8_t)err};
        event_queue_push(EVT_BOND_COMPLETE, payload, 3);
        return;
    }

    LOG_INF("Security level %u established [%u]", level, handle);

    if (entry) {
        entry->bonded = (level >= BT_SECURITY_L2);
    }

    /* Queue EVT_ENC_CHANGE: [handle_lo, handle_hi, status=0 (success)] */
    uint8_t payload[3] = {handle & 0xFF, (handle >> 8) & 0xFF, 0};
    event_queue_push(EVT_ENC_CHANGE, payload, 3);
}

BT_CONN_CB_DEFINE(conn_callbacks) = {
    .connected = connected_cb,
    .disconnected = disconnected_cb,
    .security_changed = security_changed_cb,
};

/* Pairing callbacks */
static void auth_cancel(struct bt_conn *conn)
{
    LOG_WRN("Pairing cancelled");
}

static void pairing_complete(struct bt_conn *conn, bool bonded)
{
    struct conn_entry *entry = find_conn_entry(conn);
    uint16_t handle = entry ? entry->handle : 0xFFFF;

    LOG_INF("Pairing complete [%u], bonded=%d", handle, bonded);

    if (entry) {
        entry->bonded = bonded;
    }

    /* Queue EVT_BOND_COMPLETE: [handle_lo, handle_hi, status=0] */
    uint8_t payload[3] = {handle & 0xFF, (handle >> 8) & 0xFF, 0};
    event_queue_push(EVT_BOND_COMPLETE, payload, 3);
}

static void pairing_failed(struct bt_conn *conn, enum bt_security_err reason)
{
    struct conn_entry *entry = find_conn_entry(conn);
    uint16_t handle = entry ? entry->handle : 0xFFFF;

    LOG_ERR("Pairing failed [%u]: reason %d", handle, reason);

    /* Queue EVT_BOND_COMPLETE with error */
    uint8_t payload[3] = {handle & 0xFF, (handle >> 8) & 0xFF, (uint8_t)reason};
    event_queue_push(EVT_BOND_COMPLETE, payload, 3);
}

/*
 * Public Connection API
 */

int ble_central_connect(const uint8_t *addr, uint8_t addr_type)
{
    /* Stop scanning if active (can't scan and connect simultaneously) */
    if (scanning) {
        bt_le_scan_stop();
        scanning = false;
        k_work_cancel_delayable(&scan_timeout_work);
        event_queue_push_simple(EVT_SCAN_DONE);
    }

    bt_addr_le_t peer;
    peer.type = addr_type;
    memcpy(peer.a.val, addr, 6);

    char addr_str[BT_ADDR_LE_STR_LEN];
    bt_addr_le_to_str(&peer, addr_str, sizeof(addr_str));
    LOG_INF("Connecting to %s...", addr_str);

    struct bt_conn *conn = NULL;
    int err = bt_conn_le_create(&peer, BT_CONN_LE_CREATE_CONN,
                                BT_LE_CONN_PARAM_DEFAULT, &conn);
    if (err) {
        LOG_ERR("Connect failed: %d", err);
        return err;
    }

    /* conn reference will be handled in connected_cb */
    if (conn) {
        bt_conn_unref(conn);
    }

    return 0;
}

int ble_central_disconnect(uint16_t conn_handle)
{
    if (conn_handle >= MAX_CONNECTIONS) {
        return -EINVAL;
    }

    struct conn_entry *entry = &connections[conn_handle];
    if (!entry->conn) {
        return -ENOTCONN;
    }

    return bt_conn_disconnect(entry->conn, BT_HCI_ERR_REMOTE_USER_TERM_CONN);
}

int ble_central_bond(uint16_t conn_handle)
{
    if (conn_handle >= MAX_CONNECTIONS) {
        return -EINVAL;
    }

    struct conn_entry *entry = &connections[conn_handle];
    if (!entry->conn) {
        return -ENOTCONN;
    }

    LOG_INF("Requesting security level 2 (bonding) on handle %u", conn_handle);
    return bt_conn_set_security(entry->conn, BT_SECURITY_L2);
}

int ble_central_get_handle(const uint8_t *addr)
{
    for (int i = 0; i < MAX_CONNECTIONS; i++) {
        if (connections[i].conn &&
            memcmp(connections[i].addr.a.val, addr, 6) == 0) {
            return i;
        }
    }
    return -1;
}

uint8_t ble_central_connection_count(void)
{
    return conn_count;
}

struct bt_conn *ble_central_get_conn(uint16_t conn_handle)
{
    if (conn_handle >= MAX_CONNECTIONS) {
        return NULL;
    }
    return connections[conn_handle].conn;
}

uint16_t ble_central_conn_to_handle(struct bt_conn *conn)
{
    struct conn_entry *entry = find_conn_entry(conn);
    return entry ? entry->handle : 0xFFFF;
}

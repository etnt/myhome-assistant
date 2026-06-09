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

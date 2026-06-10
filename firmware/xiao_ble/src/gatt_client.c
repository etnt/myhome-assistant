/**
 * gatt_client.c — GATT client operations (Phase 4).
 *
 * Provides service/characteristic discovery, read, write, and subscribe.
 * Results are queued as events for the ESP32 to drain via I2C.
 */

#include <zephyr/kernel.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/logging/log.h>
#include <string.h>

#include "gatt_client.h"
#include "ble_central.h"
#include "i2c_target.h"
#include "event_queue.h"

LOG_MODULE_REGISTER(gatt_client, LOG_LEVEL_INF);

/*
 * Discovery state — only one discovery at a time.
 */
static uint16_t discover_conn_handle;
static struct bt_gatt_discover_params discover_params;
static struct bt_uuid_16 discover_uuid;

/*
 * Read state
 */
static struct bt_gatt_read_params read_params;
static uint16_t read_conn_handle;
static uint16_t read_attr_handle;

/*
 * Write state
 */
static uint16_t write_conn_handle;
static uint16_t write_attr_handle;

/*
 * Subscribe state
 */
static struct bt_gatt_subscribe_params subscribe_params;

/* ================================================================
 * GATT Discovery
 * ================================================================ */

static uint8_t discover_cb(struct bt_conn *conn,
                           const struct bt_gatt_attr *attr,
                           struct bt_gatt_discover_params *params)
{
    if (!attr) {
        LOG_INF("Discovery complete [%u]", discover_conn_handle);
        /* Signal discovery done with a zero-length characteristic event */
        uint8_t payload[4];
        payload[0] = discover_conn_handle & 0xFF;
        payload[1] = (discover_conn_handle >> 8) & 0xFF;
        payload[2] = 0;  /* handle = 0 means "done" */
        payload[3] = 0;
        event_queue_push(EVT_GATT_SERVICES, payload, 4);
        return BT_GATT_ITER_STOP;
    }

    struct bt_gatt_chrc *chrc = (struct bt_gatt_chrc *)attr->user_data;

    /*
     * Build event payload:
     *   [conn_handle:2, value_handle:2, properties:1, uuid_len:1, uuid...]
     *
     * For 128-bit UUIDs: uuid_len = 16
     * For 16-bit UUIDs: uuid_len = 2
     */
    uint8_t payload[6 + 16];  /* max: 2+2+1+1+16 = 22 bytes */
    uint8_t uuid_len;

    payload[0] = discover_conn_handle & 0xFF;
    payload[1] = (discover_conn_handle >> 8) & 0xFF;
    payload[2] = chrc->value_handle & 0xFF;
    payload[3] = (chrc->value_handle >> 8) & 0xFF;
    payload[4] = chrc->properties;

    if (chrc->uuid->type == BT_UUID_TYPE_128) {
        uuid_len = 16;
        /* BT_UUID_128 stores bytes in little-endian order */
        memcpy(&payload[6], BT_UUID_128(chrc->uuid)->val, 16);
    } else {
        uuid_len = 2;
        payload[6] = BT_UUID_16(chrc->uuid)->val & 0xFF;
        payload[7] = (BT_UUID_16(chrc->uuid)->val >> 8) & 0xFF;
    }
    payload[5] = uuid_len;

    event_queue_push(EVT_GATT_SERVICES, payload, 6 + uuid_len);

    LOG_DBG("  Char handle=0x%04x props=0x%02x uuid_len=%u",
            chrc->value_handle, chrc->properties, uuid_len);

    return BT_GATT_ITER_CONTINUE;
}

int gatt_client_discover(uint16_t conn_handle)
{
    struct bt_conn *conn = ble_central_get_conn(conn_handle);
    if (!conn) {
        LOG_ERR("Discover: invalid handle %u", conn_handle);
        return -EINVAL;
    }

    discover_conn_handle = conn_handle;

    /* Discover all characteristics (no UUID filter) */
    discover_params.uuid = NULL;
    discover_params.func = discover_cb;
    discover_params.start_handle = BT_ATT_FIRST_ATTRIBUTE_HANDLE;
    discover_params.end_handle = BT_ATT_LAST_ATTRIBUTE_HANDLE;
    discover_params.type = BT_GATT_DISCOVER_CHARACTERISTIC;

    int err = bt_gatt_discover(conn, &discover_params);
    if (err) {
        LOG_ERR("Discover start failed: %d", err);
    } else {
        LOG_INF("GATT discovery started [%u]", conn_handle);
    }

    return err;
}

/* ================================================================
 * GATT Read
 * ================================================================ */

static uint8_t read_cb(struct bt_conn *conn, uint8_t err,
                       struct bt_gatt_read_params *params,
                       const void *data, uint16_t length)
{
    if (err) {
        LOG_ERR("Read failed [%u] handle=0x%04x: err=%u",
                read_conn_handle, read_attr_handle, err);
        /* Queue error response */
        uint8_t payload[5];
        payload[0] = read_conn_handle & 0xFF;
        payload[1] = (read_conn_handle >> 8) & 0xFF;
        payload[2] = read_attr_handle & 0xFF;
        payload[3] = (read_attr_handle >> 8) & 0xFF;
        payload[4] = err;
        event_queue_push(EVT_GATT_READ_RSP, payload, 5);
        return BT_GATT_ITER_STOP;
    }

    if (!data || length == 0) {
        /* End of read — for single reads this shouldn't happen with data=NULL
         * unless there's nothing to read. Queue empty response. */
        if (length == 0) {
            uint8_t payload[4];
            payload[0] = read_conn_handle & 0xFF;
            payload[1] = (read_conn_handle >> 8) & 0xFF;
            payload[2] = read_attr_handle & 0xFF;
            payload[3] = (read_attr_handle >> 8) & 0xFF;
            event_queue_push(EVT_GATT_READ_RSP, payload, 4);
        }
        return BT_GATT_ITER_STOP;
    }

    /* Queue read response: [conn_handle:2, attr_handle:2, data...] */
    uint8_t payload[4 + 56];  /* max data that fits in event payload */
    uint16_t copy_len = (length > 56) ? 56 : length;

    payload[0] = read_conn_handle & 0xFF;
    payload[1] = (read_conn_handle >> 8) & 0xFF;
    payload[2] = read_attr_handle & 0xFF;
    payload[3] = (read_attr_handle >> 8) & 0xFF;
    memcpy(&payload[4], data, copy_len);

    event_queue_push(EVT_GATT_READ_RSP, payload, 4 + copy_len);

    LOG_INF("Read response [%u] handle=0x%04x len=%u",
            read_conn_handle, read_attr_handle, length);

    return BT_GATT_ITER_STOP;
}

int gatt_client_read(uint16_t conn_handle, uint16_t attr_handle)
{
    struct bt_conn *conn = ble_central_get_conn(conn_handle);
    if (!conn) {
        LOG_ERR("Read: invalid conn handle %u", conn_handle);
        return -EINVAL;
    }

    read_conn_handle = conn_handle;
    read_attr_handle = attr_handle;

    read_params.func = read_cb;
    read_params.handle_count = 1;
    read_params.single.handle = attr_handle;
    read_params.single.offset = 0;

    int err = bt_gatt_read(conn, &read_params);
    if (err) {
        LOG_ERR("Read start failed: %d", err);
    } else {
        LOG_INF("GATT read started [%u] handle=0x%04x", conn_handle, attr_handle);
    }

    return err;
}

/* ================================================================
 * GATT Write (with response)
 * ================================================================ */

static void write_cb(struct bt_conn *conn, uint8_t err,
                     struct bt_gatt_write_params *params)
{
    /* Queue write response: [conn_handle:2, attr_handle:2, status:1] */
    uint8_t payload[5];
    payload[0] = write_conn_handle & 0xFF;
    payload[1] = (write_conn_handle >> 8) & 0xFF;
    payload[2] = write_attr_handle & 0xFF;
    payload[3] = (write_attr_handle >> 8) & 0xFF;
    payload[4] = err;

    event_queue_push(EVT_GATT_WRITE_RSP, payload, 5);

    if (err) {
        LOG_ERR("Write failed [%u] handle=0x%04x: err=%u",
                write_conn_handle, write_attr_handle, err);
    } else {
        LOG_INF("Write done [%u] handle=0x%04x", write_conn_handle, write_attr_handle);
    }
}

/* Static buffer to hold write data (persists until callback fires) */
static uint8_t write_data_buf[56];
static struct bt_gatt_write_params write_params;

int gatt_client_write(uint16_t conn_handle, uint16_t attr_handle,
                      const uint8_t *data, uint16_t len)
{
    struct bt_conn *conn = ble_central_get_conn(conn_handle);
    if (!conn) {
        LOG_ERR("Write: invalid conn handle %u", conn_handle);
        return -EINVAL;
    }

    if (len > sizeof(write_data_buf)) {
        LOG_ERR("Write data too large: %u", len);
        return -EINVAL;
    }

    write_conn_handle = conn_handle;
    write_attr_handle = attr_handle;

    /* Copy data to static buffer (must persist until callback) */
    memcpy(write_data_buf, data, len);

    write_params.func = write_cb;
    write_params.handle = attr_handle;
    write_params.offset = 0;
    write_params.data = write_data_buf;
    write_params.length = len;

    int err = bt_gatt_write(conn, &write_params);
    if (err) {
        LOG_ERR("Write start failed: %d", err);
    } else {
        LOG_INF("GATT write started [%u] handle=0x%04x len=%u",
                conn_handle, attr_handle, len);
    }

    return err;
}

/* ================================================================
 * GATT Write Without Response
 * ================================================================ */

int gatt_client_write_nr(uint16_t conn_handle, uint16_t attr_handle,
                         const uint8_t *data, uint16_t len)
{
    struct bt_conn *conn = ble_central_get_conn(conn_handle);
    if (!conn) {
        LOG_ERR("Write NR: invalid conn handle %u", conn_handle);
        return -EINVAL;
    }

    int err = bt_gatt_write_without_response(conn, attr_handle, data, len, false);
    if (err) {
        LOG_ERR("Write NR failed: %d", err);
    } else {
        LOG_DBG("Write NR done [%u] handle=0x%04x len=%u",
                conn_handle, attr_handle, len);
    }

    return err;
}

/* ================================================================
 * GATT Subscribe (Notifications/Indications)
 * ================================================================ */

static uint8_t notify_cb(struct bt_conn *conn,
                         struct bt_gatt_subscribe_params *params,
                         const void *data, uint16_t length)
{
    if (!data) {
        /* Subscription removed */
        LOG_INF("Subscription removed");
        return BT_GATT_ITER_STOP;
    }

    /* Find connection handle */
    uint16_t ch = ble_central_conn_to_handle(conn);

    /* Queue notification event: [conn_handle:2, attr_handle:2, data...] */
    uint8_t payload[4 + 56];
    uint16_t copy_len = (length > 56) ? 56 : length;

    payload[0] = ch & 0xFF;
    payload[1] = (ch >> 8) & 0xFF;
    payload[2] = params->value_handle & 0xFF;
    payload[3] = (params->value_handle >> 8) & 0xFF;
    memcpy(&payload[4], data, copy_len);

    event_queue_push(EVT_GATT_NOTIFY, payload, 4 + copy_len);

    LOG_DBG("Notify [%u] handle=0x%04x len=%u", ch, params->value_handle, length);

    return BT_GATT_ITER_CONTINUE;
}

int gatt_client_subscribe(uint16_t conn_handle, uint16_t attr_handle,
                          uint8_t type)
{
    struct bt_conn *conn = ble_central_get_conn(conn_handle);
    if (!conn) {
        LOG_ERR("Subscribe: invalid conn handle %u", conn_handle);
        return -EINVAL;
    }

    subscribe_params.notify = notify_cb;
    subscribe_params.value_handle = attr_handle;
    /* CCC handle is typically value_handle + 1 */
    subscribe_params.ccc_handle = attr_handle + 1;
    subscribe_params.value = (type == 2) ? BT_GATT_CCC_INDICATE : BT_GATT_CCC_NOTIFY;

    int err = bt_gatt_subscribe(conn, &subscribe_params);
    if (err) {
        LOG_ERR("Subscribe failed: %d", err);
    } else {
        LOG_INF("Subscribed [%u] handle=0x%04x type=%u",
                conn_handle, attr_handle, type);
    }

    return err;
}

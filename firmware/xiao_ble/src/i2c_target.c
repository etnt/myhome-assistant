/**
 * i2c_target.c — Register-based I2C target handler (buffer mode).
 *
 * The ESP32-S3 (controller) communicates with this XIAO nRF52840 (target)
 * using a simple register interface:
 *
 *   Write REG_CMD:       receive a command (first byte = cmd ID)
 *   Read  REG_STATUS:    return [version, events_pending]
 *   Read  REG_CMD_STATUS: return [last_seq, result]
 *   Read  REG_EVENT_LEN: return [event_type, payload_len] of next event
 *   Read  REG_EVENT:     return next event payload (and pop from queue)
 *
 * Uses Zephyr's I2C target BUFFER MODE API (required by nRF TWIS driver).
 * The TWIS DMA receives/transmits entire buffers, not byte-by-byte.
 */

#include <zephyr/kernel.h>
#include <zephyr/drivers/i2c.h>
#include <zephyr/sys/reboot.h>
#include <zephyr/logging/log.h>
#include <string.h>

#include "i2c_target.h"
#include "event_queue.h"

LOG_MODULE_REGISTER(i2c_target, LOG_LEVEL_INF);

/* State */
static uint8_t current_reg;            /* register selected by last write */
static uint8_t last_cmd_seq;           /* sequence tracking */
static uint8_t last_cmd_result;        /* result of last command */
static volatile bool ping_received;    /* flag for watchdog feed */

/* Response buffer for reads */
static uint8_t resp_buf[MAX_PAYLOAD_SIZE + 4];
static uint32_t resp_len;

/* Forward declarations */
static void handle_command(const uint8_t *data, uint8_t len);

/*
 * Buffer-mode I2C target callbacks (required by nRF TWIS DMA driver).
 */

/**
 * Called when the controller has finished writing data to us.
 * buf[0] = register address, buf[1..] = payload (if any).
 */
static void target_buf_write_received(struct i2c_target_config *config,
                                       uint8_t *buf, uint32_t len)
{
    if (len == 0) {
        return;
    }

    /* First byte is always the register address */
    current_reg = buf[0];

    /* If writing to REG_CMD with payload, process command */
    if (current_reg == REG_CMD && len > 1) {
        handle_command(&buf[1], len - 1);
    }
}

/**
 * Called when the controller wants to read from us.
 * We fill resp_buf based on current_reg (set by prior write) and
 * provide the pointer and length.
 */
static int target_buf_read_requested(struct i2c_target_config *config,
                                      uint8_t **buf, uint32_t *buf_size)
{
    resp_len = 0;

    switch (current_reg) {
    case REG_STATUS:
        resp_buf[0] = FIRMWARE_VERSION;
        resp_buf[1] = event_queue_count();
        resp_len = 2;
        break;

    case REG_CMD_STATUS:
        resp_buf[0] = last_cmd_seq;
        resp_buf[1] = last_cmd_result;
        resp_len = 2;
        break;

    case REG_EVENT_LEN: {
        const struct event_entry *evt = event_queue_peek();
        if (evt) {
            resp_buf[0] = evt->type;
            resp_buf[1] = evt->payload_len;
        } else {
            resp_buf[0] = 0;
            resp_buf[1] = 0;
        }
        resp_len = 2;
        break;
    }

    case REG_EVENT: {
        const struct event_entry *evt = event_queue_pop();
        if (evt) {
            resp_buf[0] = evt->type;
            resp_buf[1] = evt->payload_len;
            if (evt->payload_len > 0) {
                memcpy(&resp_buf[2], evt->payload, evt->payload_len);
            }
            resp_len = 2 + evt->payload_len;
        } else {
            resp_buf[0] = 0;
            resp_buf[1] = 0;
            resp_len = 2;
        }
        break;
    }

    default:
        resp_buf[0] = 0xFF;  /* unknown register */
        resp_len = 1;
        break;
    }

    *buf = resp_buf;
    *buf_size = resp_len;
    return 0;
}

/* I2C target callback table (buffer mode) */
static const struct i2c_target_callbacks target_callbacks = {
    .buf_write_received = target_buf_write_received,
    .buf_read_requested = target_buf_read_requested,
};

static struct i2c_target_config target_config = {
    .address = XIAO_I2C_ADDR,
    .callbacks = &target_callbacks,
};

/*
 * Command handler
 */
static void handle_command(const uint8_t *data, uint8_t len)
{
    if (len == 0) {
        return;
    }

    uint8_t cmd_id = data[0];
    last_cmd_seq++;

    LOG_INF("CMD 0x%02x (len=%u)", cmd_id, len);

    switch (cmd_id) {
    case CMD_PING: {
        /* Reply with PONG event: [version, active_connections] */
        uint8_t pong_payload[2] = {FIRMWARE_VERSION, 0};  /* 0 connections in Phase 1 */
        event_queue_push(EVT_PONG, pong_payload, sizeof(pong_payload));
        last_cmd_result = CMD_RESULT_OK;
        ping_received = true;
        break;
    }

    case CMD_RESET:
        last_cmd_result = CMD_RESULT_OK;
        /* Delay briefly to allow I2C transaction to complete */
        k_msleep(10);
        sys_reboot(SYS_REBOOT_COLD);
        break;

    default:
        /* Phase 1: only PING and RESET are implemented */
        LOG_WRN("Unknown command 0x%02x", cmd_id);
        last_cmd_result = CMD_RESULT_UNKNOWN;
        break;
    }
}

/*
 * Public API
 */

int i2c_target_init(void)
{
    const struct device *i2c_dev = DEVICE_DT_GET(DT_NODELABEL(i2c0));

    if (!device_is_ready(i2c_dev)) {
        LOG_ERR("I2C device not ready");
        return -ENODEV;
    }

    int ret = i2c_target_register(i2c_dev, &target_config);
    if (ret < 0) {
        LOG_ERR("Failed to register I2C target: %d", ret);
        return ret;
    }

    LOG_INF("I2C target registered at address 0x%02x", XIAO_I2C_ADDR);
    return 0;
}

void i2c_target_ping_received(void)
{
    /* Reset the flag — called by main loop to check */
}

bool i2c_target_check_ping(void)
{
    bool got_ping = ping_received;
    ping_received = false;
    return got_ping;
}

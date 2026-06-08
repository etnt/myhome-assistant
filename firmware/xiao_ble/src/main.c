/**
 * main.c — XIAO nRF52840 BLE offload firmware (Phase 1: I2C + PING/PONG)
 *
 * Initializes:
 *   - I2C target interface (address 0x08)
 *   - Event queue with IRQ signalling (D3 / P0.29)
 *   - Reset trigger input (D2 / P0.28)
 *   - Software watchdog (reboots if no PING in 30s)
 *
 * Queues a READY event on boot so the ESP32 knows we're alive.
 */

#include <zephyr/kernel.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/sys/reboot.h>
#include <zephyr/logging/log.h>

#include "i2c_target.h"
#include "event_queue.h"

LOG_MODULE_REGISTER(main, LOG_LEVEL_INF);

/* Red LED (P0.26) — used as heartbeat indicator */
#define LED_NODE DT_ALIAS(led0)
static const struct gpio_dt_spec led = GPIO_DT_SPEC_GET(LED_NODE, gpios);

/* Reset input pin — D2 is P0.28 on XIAO nRF52840 */
#define RST_GPIO_NODE DT_NODELABEL(gpio0)
#define RST_PIN       28

/* Watchdog timeout: reboot if no PING for this many seconds */
#define WDT_TIMEOUT_SEC 30

static const struct device *rst_gpio_dev;
static struct gpio_callback rst_cb_data;

/* Reset pin interrupt callback */
static void rst_pin_handler(const struct device *dev,
                            struct gpio_callback *cb,
                            uint32_t pins)
{
    LOG_WRN("Reset triggered by ESP32 via D2");
    k_msleep(5);  /* brief delay for signal stability */
    sys_reboot(SYS_REBOOT_COLD);
}

static int init_reset_pin(void)
{
    rst_gpio_dev = DEVICE_DT_GET(RST_GPIO_NODE);
    if (!device_is_ready(rst_gpio_dev)) {
        LOG_ERR("RST GPIO device not ready");
        return -ENODEV;
    }

    int ret = gpio_pin_configure(rst_gpio_dev, RST_PIN,
                                  GPIO_INPUT | GPIO_PULL_UP);
    if (ret < 0) {
        LOG_ERR("Failed to configure RST pin: %d", ret);
        return ret;
    }

    ret = gpio_pin_interrupt_configure(rst_gpio_dev, RST_PIN,
                                        GPIO_INT_EDGE_TO_ACTIVE);
    if (ret < 0) {
        LOG_ERR("Failed to configure RST interrupt: %d", ret);
        return ret;
    }

    gpio_init_callback(&rst_cb_data, rst_pin_handler, BIT(RST_PIN));
    gpio_add_callback(rst_gpio_dev, &rst_cb_data);

    LOG_INF("Reset pin (D2/P0.%d) ready", RST_PIN);
    return 0;
}

/* Declared in i2c_target.c */
extern bool i2c_target_check_ping(void);

int main(void)
{
    int ret;

    LOG_INF("XIAO BLE offload firmware v%d starting", FIRMWARE_VERSION);

    /* Configure heartbeat LED */
    if (gpio_is_ready_dt(&led)) {
        gpio_pin_configure_dt(&led, GPIO_OUTPUT_ACTIVE);
    }

    /* Initialize event queue (includes IRQ GPIO setup) */
    ret = event_queue_init();
    if (ret < 0) {
        LOG_ERR("Event queue init failed: %d", ret);
        return ret;
    }

    /* Initialize I2C target */
    ret = i2c_target_init();
    if (ret < 0) {
        LOG_ERR("I2C target init failed: %d", ret);
        return ret;
    }

    /* Initialize reset input pin */
    ret = init_reset_pin();
    if (ret < 0) {
        LOG_WRN("Reset pin init failed (non-fatal): %d", ret);
    }

    /* Queue READY event — ESP32 will see IRQ go LOW */
    event_queue_push_simple(EVT_READY);
    LOG_INF("READY event queued, waiting for ESP32");

    /*
     * Main loop: software watchdog.
     * If we don't receive a PING within WDT_TIMEOUT_SEC, reboot.
     */
    int64_t last_ping_time = k_uptime_get();

    while (1) {
        k_msleep(1000);  /* check every second */

        /* Toggle LED as heartbeat */
        if (gpio_is_ready_dt(&led)) {
            gpio_pin_toggle_dt(&led);
        }

        if (i2c_target_check_ping()) {
            last_ping_time = k_uptime_get();
            LOG_DBG("PING received, watchdog fed");
        }

        int64_t elapsed_ms = k_uptime_get() - last_ping_time;
        if (elapsed_ms > (WDT_TIMEOUT_SEC * 1000)) {
            LOG_ERR("No PING for %d seconds, rebooting!", WDT_TIMEOUT_SEC);
            sys_reboot(SYS_REBOOT_COLD);
        }
    }

    return 0;
}

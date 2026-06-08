/**
 * event_queue.c — FIFO event queue with IRQ GPIO signalling.
 *
 * Events are queued by BLE callbacks (or PING handler in Phase 1)
 * and drained by the ESP32 reading REG_EVENT via I2C.
 *
 * IRQ pin (D3 / P0.29): HIGH = idle, LOW = events pending.
 */

#include <zephyr/kernel.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/logging/log.h>
#include <string.h>

#include "event_queue.h"

LOG_MODULE_REGISTER(event_queue, LOG_LEVEL_INF);

/* IRQ GPIO — D3 is P0.29 on XIAO nRF52840 */
#define IRQ_NODE DT_NODELABEL(gpio0)
#define IRQ_PIN  29

static const struct device *gpio_dev;

/* Circular buffer */
static struct event_entry queue[EVENT_QUEUE_SIZE];
static uint8_t head;  /* next read position */
static uint8_t tail;  /* next write position */
static uint8_t count;

static struct k_spinlock lock;

static void irq_pin_set(bool events_pending)
{
    if (gpio_dev) {
        /* Active LOW: events pending = pin LOW */
        gpio_pin_set(gpio_dev, IRQ_PIN, events_pending ? 0 : 1);
    }
}

int event_queue_init(void)
{
    gpio_dev = DEVICE_DT_GET(IRQ_NODE);
    if (!device_is_ready(gpio_dev)) {
        LOG_ERR("GPIO device not ready");
        return -ENODEV;
    }

    int ret = gpio_pin_configure(gpio_dev, IRQ_PIN,
                                  GPIO_OUTPUT_HIGH);  /* idle = HIGH */
    if (ret < 0) {
        LOG_ERR("Failed to configure IRQ pin: %d", ret);
        return ret;
    }

    head = 0;
    tail = 0;
    count = 0;

    LOG_INF("Event queue initialized (IRQ on P0.%d)", IRQ_PIN);
    return 0;
}

int event_queue_push(uint8_t type, const uint8_t *payload, uint8_t len)
{
    if (len > EVENT_MAX_PAYLOAD) {
        len = EVENT_MAX_PAYLOAD;
    }

    k_spinlock_key_t key = k_spin_lock(&lock);

    if (count >= EVENT_QUEUE_SIZE) {
        k_spin_unlock(&lock, key);
        LOG_WRN("Event queue full, dropping event 0x%02x", type);
        return -ENOMEM;
    }

    struct event_entry *entry = &queue[tail];
    entry->type = type;
    entry->payload_len = len;
    if (payload && len > 0) {
        memcpy(entry->payload, payload, len);
    }

    tail = (tail + 1) % EVENT_QUEUE_SIZE;
    count++;

    /* Assert IRQ if this is the first event */
    if (count == 1) {
        irq_pin_set(true);
    }

    k_spin_unlock(&lock, key);

    LOG_DBG("Pushed event 0x%02x (len=%u, pending=%u)", type, len, count);
    return 0;
}

const struct event_entry *event_queue_peek(void)
{
    k_spinlock_key_t key = k_spin_lock(&lock);

    const struct event_entry *entry = NULL;
    if (count > 0) {
        entry = &queue[head];
    }

    k_spin_unlock(&lock, key);
    return entry;
}

const struct event_entry *event_queue_pop(void)
{
    k_spinlock_key_t key = k_spin_lock(&lock);

    if (count == 0) {
        k_spin_unlock(&lock, key);
        return NULL;
    }

    const struct event_entry *entry = &queue[head];
    head = (head + 1) % EVENT_QUEUE_SIZE;
    count--;

    /* Release IRQ if queue is now empty */
    if (count == 0) {
        irq_pin_set(false);
    }

    k_spin_unlock(&lock, key);

    LOG_DBG("Popped event 0x%02x (remaining=%u)", entry->type, count);
    return entry;
}

uint8_t event_queue_count(void)
{
    k_spinlock_key_t key = k_spin_lock(&lock);
    uint8_t n = count;
    k_spin_unlock(&lock, key);
    return n;
}

#ifndef EVENT_QUEUE_H
#define EVENT_QUEUE_H

#include <stdint.h>
#include <stdbool.h>

/* Maximum events in the FIFO queue */
#define EVENT_QUEUE_SIZE 32

/* Maximum event payload size */
#define EVENT_MAX_PAYLOAD 60

/* Single event entry */
struct event_entry {
    uint8_t type;
    uint8_t payload_len;
    uint8_t payload[EVENT_MAX_PAYLOAD];
};

/**
 * Initialize the event queue and IRQ GPIO pin.
 * Returns 0 on success.
 */
int event_queue_init(void);

/**
 * Push an event onto the queue. Asserts IRQ LOW if queue was empty.
 * Returns 0 on success, -ENOMEM if queue full.
 */
int event_queue_push(uint8_t type, const uint8_t *payload, uint8_t len);

/**
 * Peek at the next event (for REG_EVENT_LEN reads).
 * Returns NULL if queue is empty.
 */
const struct event_entry *event_queue_peek(void);

/**
 * Pop the next event from the queue.
 * Releases IRQ HIGH if queue becomes empty.
 * Returns NULL if queue is empty.
 */
const struct event_entry *event_queue_pop(void);

/**
 * Get the number of pending events.
 */
uint8_t event_queue_count(void);

/**
 * Push a simple event with no payload.
 */
static inline int event_queue_push_simple(uint8_t type)
{
    return event_queue_push(type, NULL, 0);
}

#endif /* EVENT_QUEUE_H */

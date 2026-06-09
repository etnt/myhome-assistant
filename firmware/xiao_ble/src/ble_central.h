#ifndef BLE_CENTRAL_H
#define BLE_CENTRAL_H

#include <stdint.h>
#include <stdbool.h>

/**
 * Initialize the BLE stack (must be called from main thread).
 * Returns 0 on success.
 */
int ble_central_init(void);

/**
 * Start BLE scanning for the given duration (seconds).
 * Scan results are queued as EVT_SCAN_RESULT events.
 * EVT_SCAN_DONE is queued when duration expires or scan_stop() called.
 * Returns 0 on success.
 */
int ble_central_scan_start(uint8_t duration_sec);

/**
 * Stop an active scan immediately.
 * Queues EVT_SCAN_DONE.
 * Returns 0 on success, -EALREADY if not scanning.
 */
int ble_central_scan_stop(void);

/**
 * Returns true if a scan is currently active.
 */
bool ble_central_is_scanning(void);

#endif /* BLE_CENTRAL_H */

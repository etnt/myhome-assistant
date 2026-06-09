#ifndef BLE_CENTRAL_H
#define BLE_CENTRAL_H

#include <stdint.h>
#include <stdbool.h>

/**
 * Initialize the BLE stack (must be called from main thread).
 * Returns 0 on success.
 */
int ble_central_init(void);

/*
 * Scanning
 */

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

/*
 * Connections
 */

/**
 * Connect to a BLE device by address.
 * addr: 6-byte BLE address (little-endian)
 * addr_type: 0 = public, 1 = random
 * Queues EVT_CONNECTED on success, EVT_CMD_ERROR on failure.
 * Returns 0 if connection attempt started.
 */
int ble_central_connect(const uint8_t *addr, uint8_t addr_type);

/**
 * Disconnect a connection by handle.
 * Queues EVT_DISCONNECTED.
 * Returns 0 on success.
 */
int ble_central_disconnect(uint16_t conn_handle);

/**
 * Initiate bonding (pairing + key storage) on a connection.
 * Requires an active connection. Queues EVT_BOND_COMPLETE.
 * Returns 0 if bonding started.
 */
int ble_central_bond(uint16_t conn_handle);

/**
 * Get connection handle for an address. Returns -1 if not connected.
 */
int ble_central_get_handle(const uint8_t *addr);

/**
 * Get number of active connections.
 */
uint8_t ble_central_connection_count(void);

#endif /* BLE_CENTRAL_H */

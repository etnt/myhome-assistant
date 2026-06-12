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
 * Delete the stored bond (LTK) for a peer address.
 * addr: 6-byte BLE address (little-endian)
 * addr_type: 0 = public, 1 = random
 * No connection required; clears the key from settings/NVS.
 * Returns 0 on success (or if no bond existed).
 */
int ble_central_unpair(const uint8_t *addr, uint8_t addr_type);

/**
 * Delete all stored bonds.
 * Returns 0 on success.
 */
int ble_central_unpair_all(void);

/**
 * Get connection handle for an address. Returns -1 if not connected.
 */
int ble_central_get_handle(const uint8_t *addr);

/**
 * Get number of active connections.
 */
uint8_t ble_central_connection_count(void);

/**
 * Get the bt_conn pointer for a connection handle.
 * Returns NULL if handle is invalid or not connected.
 * Used by gatt_client to issue GATT operations.
 */
struct bt_conn *ble_central_get_conn(uint16_t conn_handle);

/**
 * Map a bt_conn pointer back to our connection handle index.
 * Returns 0xFFFF if not found.
 */
uint16_t ble_central_conn_to_handle(struct bt_conn *conn);

/*
 * Persistent auto-reconnect (Phase 5)
 */

/**
 * Populate the filter accept list from stored bonds and begin background
 * auto-connection to every bonded bulb. Bonded devices are then kept
 * persistently connected (and re-encrypted) without any command from the
 * ESP32, reconnecting automatically whenever they advertise.
 *
 * Call once after ble_central_init(). Safe to call again to refresh the
 * accept list after bonds change. Returns 0 on success.
 */
int ble_central_autoconnect_start(void);

#endif /* BLE_CENTRAL_H */

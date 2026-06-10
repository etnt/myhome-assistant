#ifndef GATT_CLIENT_H
#define GATT_CLIENT_H

#include <stdint.h>

/**
 * Discover all services and characteristics on a connection.
 * Results are queued as EVT_GATT_SERVICES events, one per characteristic:
 *   [conn_handle:2, char_handle:2, properties:1, uuid_len:1, uuid:uuid_len]
 *
 * Returns 0 if discovery started.
 */
int gatt_client_discover(uint16_t conn_handle);

/**
 * Read a characteristic by its ATT value handle.
 * Result queued as EVT_GATT_READ_RSP:
 *   [conn_handle:2, attr_handle:2, data...]
 *
 * Returns 0 if read started.
 */
int gatt_client_read(uint16_t conn_handle, uint16_t attr_handle);

/**
 * Write a characteristic (with response) by ATT value handle.
 * Result queued as EVT_GATT_WRITE_RSP:
 *   [conn_handle:2, attr_handle:2, status:1]
 *
 * Returns 0 if write started.
 */
int gatt_client_write(uint16_t conn_handle, uint16_t attr_handle,
                      const uint8_t *data, uint16_t len);

/**
 * Write without response (no acknowledgment from remote).
 * No event is queued on success.
 * Returns 0 on success.
 */
int gatt_client_write_nr(uint16_t conn_handle, uint16_t attr_handle,
                         const uint8_t *data, uint16_t len);

/**
 * Subscribe to notifications/indications on a characteristic.
 * type: 1 = notify, 2 = indicate
 * Returns 0 if subscribe started.
 */
int gatt_client_subscribe(uint16_t conn_handle, uint16_t attr_handle,
                          uint8_t type);

#endif /* GATT_CLIENT_H */

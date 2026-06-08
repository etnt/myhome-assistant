#ifndef I2C_TARGET_H
#define I2C_TARGET_H

#include <stdint.h>
#include <stdbool.h>

/* I2C target address */
#define XIAO_I2C_ADDR 0x08

/* Register addresses */
#define REG_STATUS      0x00
#define REG_CMD         0x01
#define REG_CMD_STATUS  0x02
#define REG_EVENT       0x10
#define REG_EVENT_LEN   0x11

/* Command IDs */
#define CMD_PING             0x01
#define CMD_SCAN_START       0x02
#define CMD_SCAN_STOP        0x03
#define CMD_CONNECT          0x10
#define CMD_DISCONNECT       0x11
#define CMD_BOND             0x12
#define CMD_GATT_DISCOVER    0x13
#define CMD_GATT_READ        0x20
#define CMD_GATT_WRITE       0x21
#define CMD_GATT_WRITE_NR    0x22
#define CMD_SUBSCRIBE        0x23
#define CMD_GET_BONDS        0x30
#define CMD_DELETE_BOND      0x31
#define CMD_DELETE_ALL_BONDS 0x32
#define CMD_RESET            0xFF

/* Event IDs */
#define EVT_PONG          0x81
#define EVT_READY         0x82
#define EVT_SCAN_RESULT   0x83
#define EVT_SCAN_DONE     0x84
#define EVT_CONNECTED     0x85
#define EVT_DISCONNECTED  0x86
#define EVT_BOND_COMPLETE 0x87
#define EVT_GATT_SERVICES 0x88
#define EVT_GATT_READ_RSP 0x89
#define EVT_GATT_WRITE_RSP 0x8A
#define EVT_GATT_NOTIFY   0x8B
#define EVT_ENC_CHANGE    0x8C
#define EVT_CMD_ERROR     0xFE

/* CMD_STATUS result codes */
#define CMD_RESULT_OK       0x00
#define CMD_RESULT_UNKNOWN  0x01
#define CMD_RESULT_BUSY     0x02
#define CMD_RESULT_ERROR    0x03

/* Max payload per I2C transaction */
#define MAX_PAYLOAD_SIZE 62

/* Firmware version (Phase 1) */
#define FIRMWARE_VERSION 0x01

/**
 * Initialize the I2C target interface.
 * Returns 0 on success.
 */
int i2c_target_init(void);

/**
 * Called when the watchdog is fed (PING received).
 */
void i2c_target_ping_received(void);

/**
 * Get the last command sequence number.
 */
uint8_t i2c_target_last_seq(void);

#endif /* I2C_TARGET_H */

# XIAO nRF52840 BLE Offload Firmware

Zephyr-based firmware for the Seeed Studio XIAO nRF52840, acting as a
dedicated BLE co-processor for the myhome-assistant ESP32-S3.

## Communication

- **I2C target** at address `0x08` (shared bus with SparkFun sensors)
- **IRQ** on pin D3 (P0.29) — active LOW when events are pending
- **RST** on pin D2 (P0.28) — falling edge triggers software reboot

## Building

Requires Zephyr SDK. Install with:

```bash
# Install west (Zephyr's meta-tool)
pip install west

# Initialize Zephyr workspace (first time only)
west init ~/zephyrproject
cd ~/zephyrproject
west update
west zephyr-export
pip install -r zephyr/scripts/requirements.txt
```

Then build this firmware:

```bash
cd /path/to/myhome-assistant/nifs/xiao_ble
west build -b xiao_nrf52840 .
```

## Flashing

Connect the XIAO nRF52840 via USB-C, then:

```bash
west flash
```

If the board is in bootloader mode (double-tap reset button), it appears
as a USB mass storage device — you can also copy the UF2 file:

```bash
cp build/zephyr/zephyr.uf2 /Volumes/XIAO-SENSE/
```

## Phase 1 Behavior

1. Boots and initializes I2C target + IRQ GPIO
2. Queues a READY event (IRQ goes LOW)
3. Responds to PING commands with PONG events
4. Reboots if no PING received within 30 seconds
5. Reboots if ESP32 pulls D2 LOW

## Pin Mapping

| Function | XIAO Pin | nRF52840 GPIO |
|----------|----------|---------------|
| SDA      | D4       | P0.04         |
| SCL      | D5       | P0.05         |
| IRQ out  | D3       | P0.29         |
| RST in   | D2       | P0.28         |

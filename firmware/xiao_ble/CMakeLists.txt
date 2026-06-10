cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(xiao_ble)

target_sources(app PRIVATE
    src/main.c
    src/i2c_target.c
    src/event_queue.c
    src/ble_central.c
    src/gatt_client.c
)

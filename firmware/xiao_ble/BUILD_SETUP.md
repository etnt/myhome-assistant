# XIAO nRF52840 — Zephyr Build Environment Setup

How to set up the Zephyr toolchain on macOS (Apple Silicon) to build the
XIAO BLE offload firmware.

## Prerequisites

- macOS with Homebrew
- Python 3.x (system or Homebrew)
- CMake (`brew install cmake`)
- Ninja (`brew install ninja`)
- `dtc` device-tree compiler (`brew install dtc`)
- wget (`brew install wget`)

## 1. Create a Python Virtual Environment

Zephyr's `west` meta-tool and build dependencies require several Python
packages. Use a venv to avoid polluting the system Python:

```bash
cd /Users/ttornkvi/git/myhome-assistant
python3 -m venv .venv
source .venv/bin/activate
```

## 2. Install West

```bash
pip install west
```

Verify:
```bash
west --version
# west, version 1.5.0
```

## 3. Initialize the Zephyr Workspace

```bash
cd ~
west init zephyrproject
cd zephyrproject
west update --narrow -o=--depth=1
```

> **Note:** `--narrow -o=--depth=1` performs shallow clones to save disk
> space (~3 GB vs ~15 GB for full history). The update takes 5–10 minutes.

This creates `~/zephyrproject/` with:
- `zephyr/` — main Zephyr repository (v4.4.99 / main)
- `modules/` — HALs, libraries, CMSIS, etc.

## 4. Install Zephyr Python Dependencies

```bash
source /Users/ttornkvi/git/myhome-assistant/.venv/bin/activate
pip install -r ~/zephyrproject/zephyr/scripts/requirements.txt
```

## 5. Install Zephyr SDK 1.0.1

Zephyr main (v4.4+) requires SDK >= 1.0. Download the minimal (no
toolchains) bundle and select only `arm-zephyr-eabi`:

```bash
cd ~
wget https://github.com/zephyrproject-rtos/sdk-ng/releases/download/v1.0.1/zephyr-sdk-1.0.1_macos-aarch64_minimal.tar.xz
tar xf zephyr-sdk-1.0.1_macos-aarch64_minimal.tar.xz
cd zephyr-sdk-1.0.1
./setup.sh
```

Interactive prompts — answer as follows:

| Prompt | Answer |
|--------|--------|
| Install GNU toolchain? | **y** |
| Install GNU toolchains for all targets? | **n** |
| Install 'arm-zephyr-eabi' GNU toolchain? | **y** |
| (all other toolchains) | **n** |
| Install LLVM toolchain? | **n** |
| Install host tools? | **y** |
| Register Zephyr SDK CMake package? | **y** |
| Create symbolic links for bisectability? | **n** |

The ARM toolchain (~86 MB) is downloaded automatically. The CMake package
is registered at `~/.cmake/packages/Zephyr-sdk`.

> **macOS note:** Host tools are listed as "not available yet" on macOS —
> this is fine. CMake and Ninja from Homebrew are used instead.

## 6. Build the Firmware

```bash
source /Users/ttornkvi/git/myhome-assistant/.venv/bin/activate
export ZEPHYR_BASE=~/zephyrproject/zephyr
export ZEPHYR_SDK_INSTALL_DIR=~/zephyr-sdk-1.0.1

cd /Users/ttornkvi/git/myhome-assistant/firmware/xiao_ble
west build -b xiao_ble .
```

Output:
```
Memory region         Used Size  Region Size  %age Used
           FLASH:       63564 B       788 KB      7.88%
             RAM:       18168 B       256 KB      6.93%

Converted to uf2, output size: 127488, start address: 0x27000
Wrote 127488 bytes to zephyr.uf2
```

The flashable binary is at `build/zephyr/zephyr.uf2`.

### Rebuild (after code changes)

```bash
west build    # incremental rebuild (same directory)
```

### Clean Rebuild

```bash
rm -rf build && west build -b xiao_ble .
```

## 7. Flash the XIAO nRF52840

### Option A: UF2 (USB Mass Storage)

1. Connect the XIAO to USB-C
2. Double-tap the tiny reset button — the board enters UF2 bootloader
   mode and mounts as a USB drive (typically named `XIAO-SENSE`)
3. Copy the firmware:
   ```bash
   cp build/zephyr/zephyr.uf2 /Volumes/XIAO-SENSE/
   ```
4. The board reboots automatically into the new firmware

### Option B: Serial DFU (when USB storage is blocked)

Enterprise-managed Macs often block USB mass storage devices. The XIAO's
Adafruit bootloader also exposes a **USB CDC serial port** which can be
used for DFU flashing instead.

1. Install `adafruit-nrfutil` in the venv:
   ```bash
   source .venv/bin/activate
   pip install adafruit-nrfutil
   ```

2. Create a DFU package from the hex file:
   ```bash
   cd firmware/xiao_ble
   adafruit-nrfutil dfu genpkg \
       --dev-type 0x0052 \
       --application build/zephyr/zephyr.hex \
       build/zephyr/dfu_package.zip
   ```

3. Find the serial port (with XIAO plugged in):
   ```bash
   ls /dev/cu.usbmodem*
   # e.g. /dev/cu.usbmodem11101
   ```

4. Double-tap the reset button to enter bootloader mode

5. Flash via serial DFU:
   ```bash
   adafruit-nrfutil dfu serial \
       --package build/zephyr/dfu_package.zip \
       -p /dev/cu.usbmodem11101 \
       -b 115200
   ```

   Expected output:
   ```
   Upgrading target on /dev/cu.usbmodem11101 with DFU package ...
   ########################################
   Activating new firmware
   Device programmed.
   ```

6. The board reboots automatically into the new firmware

> **Note:** The serial port name may change between normal mode and
> bootloader mode. Re-check with `ls /dev/cu.usbmodem*` after double-
> tapping reset if the flash command fails to connect.

## Gotchas & Fixes

### Board name is `xiao_ble`, not `xiao_nrf52840`

Zephyr's board identifier is `xiao_ble` (with SoC qualifier `nrf52840`).
The full target shown in build output is `xiao_ble/nrf52840`.

### Overlay filename must match board name

Application device-tree overlays in the `boards/` directory must be named
after the board: `boards/xiao_ble.overlay`. Zephyr v4.x will NOT find
`boards/xiao_nrf52840.overlay`.

### TWIS driver requires `I2C_TARGET_BUFFER_MODE`

The Nordic nRF TWIS (I2C target) driver has three Kconfig dependencies:
```
CONFIG_I2C=y
CONFIG_I2C_TARGET=y
CONFIG_I2C_TARGET_BUFFER_MODE=y   ← easy to miss
```

Without `I2C_TARGET_BUFFER_MODE`, the TWIS driver isn't compiled and the
linker fails with `undefined reference to '__device_dts_ord_XX'`.

### `sys_reboot()` needs an explicit include

```c
#include <zephyr/sys/reboot.h>   // for sys_reboot() and SYS_REBOOT_COLD
```

### SDK version mismatch

Zephyr main (v4.4+) requires SDK >= 1.0. The older SDK 0.17.0 will fail
at CMake configure time with:
```
The SDK version you are using is not supported, please update your SDK.
```

## Directory Layout (post-setup)

```
~/zephyrproject/           ← Zephyr workspace (west-managed)
  zephyr/                  ← Zephyr RTOS source
  modules/                 ← HALs, libraries

~/zephyr-sdk-1.0.1/       ← Zephyr SDK (toolchains + host tools)
  gnu/arm-zephyr-eabi/     ← ARM cross-compiler (GCC 14.3)
  cmake/                   ← CMake package files

~/git/myhome-assistant/
  .venv/                   ← Python venv (west + Zephyr deps)
  firmware/xiao_ble/       ← This firmware project
    build/                 ← Build output (gitignored)
      zephyr/zephyr.uf2   ← Flashable binary
```

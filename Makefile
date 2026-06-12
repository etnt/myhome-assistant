# MyHome Assistant - Build & Flash
#
# Targets:
#   make atomvm          Build AtomVM firmware (BLE offloaded to XIAO nRF52840)
#   make flash-firmware  Flash AtomVM firmware to ESP32-S3
#   make app             Compile Erlang sources and create .avm packbeam
#   make flash-app       Build and flash the Erlang application
#   make flash           Flash everything (firmware + app)
#   make monitor         Open serial console (screen)
#   make clean           Remove build artifacts
#   make help            Show targets and current configuration
#
# Configuration (override via env or command line):
#   PORT         Serial port        (default: /dev/cu.usbmodem11101)
#   IDF_PATH     ESP-IDF location   (default: ~/esp/esp-idf)
#   APP_OFFSET   App flash offset   (default: 0x250000)

SHELL := /bin/bash
IDF_PATH ?= $(HOME)/esp/esp-idf
PORT ?= /dev/cu.usbmodem5B414826621
XIAO_PORT ?= /dev/cu.usbmodem1101
ATOMVM_DIR := AtomVM
ESP32_DIR := $(ATOMVM_DIR)/src/platforms/esp32
APP_OFFSET ?= 0x250000
IP ?= 192.168.68.50

.PHONY: atomvm flash-firmware app flash-app flash monitor clean all help

## Build AtomVM firmware (BLE disabled on-chip; offloaded to XIAO nRF52840)
atomvm: install-esptool  $(ESP32_DIR)/build/atomvm-esp32s3.img

install-esptool: .venv

.venv:
	python3 -m venv .venv
	source .venv/bin/activate && pip install esptool

$(ATOMVM_DIR):
	git clone --depth 1 git@github.com:etnt/AtomVM.git

$(ESP32_DIR)/build/atomvm-esp32s3.img: $(ATOMVM_DIR) patches/sdkconfig.defaults.in.patch
	@# Remove the legacy NimBLE port-driver symlink if a previous checkout created it
	@if [ -L $(ESP32_DIR)/components/ble_port ]; then \
		rm $(ESP32_DIR)/components/ble_port; \
	fi
	@if ! grep -q "CONFIG_SPIRAM=y" $(ESP32_DIR)/sdkconfig.defaults.in 2>/dev/null; then \
		cd $(ATOMVM_DIR) && git checkout -- src/platforms/esp32/sdkconfig.defaults.in && \
		git apply ../patches/sdkconfig.defaults.in.patch; \
	fi
	@if [ ! -f $(ESP32_DIR)/build/CMakeCache.txt ]; then \
		rm -rf $(ESP32_DIR)/build; \
	fi
	cd $(ESP32_DIR) && \
		source $(IDF_PATH)/export.sh && \
		idf.py set-target esp32s3 && \
		idf.py build && \
		esptool.py --chip esp32s3 merge_bin \
			--flash_mode dio --flash_freq 80m --flash_size 4MB \
			-o build/atomvm-esp32s3.img \
			0x0 build/bootloader/bootloader.bin \
			0x8000 build/partition_table/partition-table.bin \
			0x10000 build/atomvm-esp32.bin

## Flash AtomVM firmware to ESP32-S3
flash-firmware: atomvm
	source .venv/bin/activate && \
	esptool.py --chip esp32s3 --port $(PORT) --baud 921600 \
		write_flash 0x0 $(ESP32_DIR)/build/atomvm-esp32s3.img

## Build the Erlang application
app:
	rebar3 compile
	rebar3 atomvm packbeam

## Flash the Erlang application
flash-app: app
	source $(IDF_PATH)/export.sh && \
	rebar3 atomvm esp32_flash --port $(PORT) --offset $(APP_OFFSET)
	@echo ">>> Press RESET on the ESP32 to start the new app <<<"

## Build and flash everything (firmware + app)
flash: flash-firmware flash-app
monitor:
	minicom -D $(PORT) -b 115200

.PHONY: monitor-xiao
monitor-xiao:
	minicom -D $(XIAO_PORT) -b 115200

.PHONY: test
test:
	rebar3 eunit

## Build and flash everything
all: flash

## Some nice short commands
.PHONY: logs status scan doscan ppscan discover state state% on on% off off%
logs:
	@curl -s http://$(IP):8080/api/logs | jq -r '.logs | reverse[] | "\(.ts) [\(.level)] \(.msg)"'

status:
	@curl -s http://$(IP):8080/api/status | jq

.PHONY: ppstatus
ppstatus:
	@curl -s http://$(IP):8080/api/status | jq -r '.bulbs[] | "\(.name) (\(.display_name)): power=\(.power) brightness=\(.brightness) color_temp=\(.color_temp) connected=\(.connected)"'

scan:
	@curl -s http://$(IP):8080/api/scan?named=true

doscan:
	@curl -s -X POST http://$(IP):8080/api/scan 

ppscan:
	@curl -s http://$(IP):8080/api/scan | jq -r '.scan.results | if type == "array" then map(select(.name != "")) | sort_by(.rssi) | reverse[] | "\(.addr)  \(.rssi)dBm  \(.name)" else "No scan results. Run: curl -X POST http://$(IP):8080/api/scan" end'

discover:
	@curl -s -X POST http://$(IP):8080/api/discover

state: state1 state2 state3

state%:
	@curl -s http://$(IP):8080/api/bulb/$*/state | jq -r '"Bulb $*: power=\(.power) brightness=\(.brightness) color_temp=\(.color_temp) status=\(.status)"'

on: on1 on2 on3

on%:
	@curl -s -X POST http://$(IP):8080/api/bulb/$*/power -d '{"on":true}'

off: off1 off2 off3

off%:
	@curl -s -X POST http://$(IP):8080/api/bulb/$*/power -d '{"on":false}'

refresh%:
	@curl -s -X POST http://$(IP):8080/api/bulb/$*/refresh

.PHONY: dump restore
dump:
	@curl -s http://$(IP):8080/api/nvs/dump > myhome_assistant_dump.json

restore:
	@curl -s -X POST http://$(IP):8080/api/nvs/restore --data-binary @myhome_assistant_dump.json

.PHONY: policies enable-policy disable-policy 
policies:
	@curl -s http://$(IP):8080/api/policies | jq -r '.policies[] | "\(.id)|\(if .enabled then "enabled" else "disabled" end)|\(if .active then "ACTIVE" else "-" end)|\(.rule_count) rules|\(if .last_fired_ago_s then "\(.last_fired_ago_s)s ago" else "never" end)"' | column -t -s'|'

enable-policy:
ifndef POLICY
	$(error Usage: make enable-policy POLICY=<policy-id>)
endif
	@curl -s -X POST http://$(IP):8080/api/policies/$(POLICY)/enable

disable-policy:
ifndef POLICY
	$(error Usage: make disable-policy POLICY=<policy-id>)
endif
	@curl -s -X POST http://$(IP):8080/api/policies/$(POLICY)/disable

## Show available targets
help:
	@echo "make atomvm          - Build AtomVM firmware (BLE offloaded to XIAO)"
	@echo "make flash-firmware  - Flash AtomVM firmware to ESP32-S3"
	@echo "make app             - Build Erlang application"
	@echo "make flash-app       - Build and flash Erlang app"
	@echo "make flash           - Flash everything (firmware + app)"
	@echo "make monitor         - Open serial monitor (screen)"
	@echo "make clean           - Remove build artifacts"
	@echo ""
	@echo "XIAO nRF52840:"
	@echo "  make xiao          - Build XIAO firmware (incremental)"
	@echo "  make xiao-clean    - Clean rebuild XIAO firmware"
	@echo "  make xiao-pkg      - Build + create DFU package"
	@echo "  make xiao-flash    - Build + package + flash via serial DFU"
	@echo ""
	@echo "Configuration:"
	@echo "  PORT=$(PORT)"
	@echo "  XIAO_PORT=$(XIAO_PORT)"
	@echo "  IDF_PATH=$(IDF_PATH)"
	@echo "  APP_OFFSET=$(APP_OFFSET)"

## Clean build artifacts
clean:
	rm -rf _build
	cd $(ESP32_DIR) 2>/dev/null && \
		source $(IDF_PATH)/export.sh && \
		idf.py fullclean || true

##############################################################################
# XIAO nRF52840 (Zephyr firmware)
##############################################################################

XIAO_DIR := firmware/xiao_ble
XIAO_PORT ?= /dev/cu.usbmodem11101
ZEPHYR_BASE ?= $(HOME)/zephyrproject/zephyr
ZEPHYR_SDK_INSTALL_DIR ?= $(HOME)/zephyr-sdk-1.0.1
VENV := source .venv/bin/activate

.PHONY: xiao xiao-clean xiao-flash xiao-pkg

## Build XIAO nRF52840 firmware
xiao:
	$(VENV) && \
	export ZEPHYR_BASE=$(ZEPHYR_BASE) && \
	export ZEPHYR_SDK_INSTALL_DIR=$(ZEPHYR_SDK_INSTALL_DIR) && \
	cd $(XIAO_DIR) && west build -b xiao_ble .

## Clean rebuild XIAO firmware
xiao-clean:
	rm -rf $(XIAO_DIR)/build
	$(VENV) && \
	export ZEPHYR_BASE=$(ZEPHYR_BASE) && \
	export ZEPHYR_SDK_INSTALL_DIR=$(ZEPHYR_SDK_INSTALL_DIR) && \
	cd $(XIAO_DIR) && west build -b xiao_ble .

## Create DFU package for serial flashing
xiao-pkg: xiao
	$(VENV) && \
	adafruit-nrfutil dfu genpkg --dev-type 0x0052 \
		--application $(XIAO_DIR)/build/zephyr/zephyr.hex \
		$(XIAO_DIR)/build/zephyr/dfu_package.zip

## Flash XIAO via serial DFU (double-tap reset first!)
xiao-flash: xiao-pkg
	@echo "Make sure to double-tap the reset button on the XIAO to enter DFU mode before running this command!"
	$(VENV) && \
	adafruit-nrfutil dfu serial \
		--package $(XIAO_DIR)/build/zephyr/dfu_package.zip \
		-p $(XIAO_PORT) -b 115200

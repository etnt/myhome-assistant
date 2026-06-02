# MyHome Assistant - Build & Flash
#
# Targets:
#   make atomvm          Build AtomVM firmware with BLE port driver
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
ATOMVM_DIR := AtomVM
ESP32_DIR := $(ATOMVM_DIR)/src/platforms/esp32
APP_OFFSET ?= 0x250000
IP ?= 192.168.1.115

.PHONY: atomvm flash-firmware app flash-app flash monitor clean all help

## Build AtomVM firmware with BLE component
atomvm: install-esptool  $(ESP32_DIR)/build/atomvm-esp32s3.img

install-esptool: .venv

.venv:
	python3 -m venv .venv
	source .venv/bin/activate && pip install esptool

$(ATOMVM_DIR):
	git clone --depth 1 git@github.com:etnt/AtomVM.git

$(ESP32_DIR)/build/atomvm-esp32s3.img: $(ATOMVM_DIR) nifs/ble/ble_port.c sdkconfig.defaults
	@if [ ! -L $(ESP32_DIR)/components/ble_port ]; then \
		ln -s $$(pwd)/nifs/ble $(ESP32_DIR)/components/ble_port; \
	fi
	@if ! grep -q "BT_NIMBLE_ENABLED" $(ESP32_DIR)/sdkconfig.defaults.in 2>/dev/null; then \
		cat sdkconfig.defaults >> $(ESP32_DIR)/sdkconfig.defaults.in; \
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

## Build and flash everything (firmware + app)
flash: flash-firmware flash-app
monitor:
	minicom -D $(PORT) -b 115200

## Build and flash everything
all: flash

## Some nice short commands
.PHONY: logs status scan ppscan
logs:
	curl -s http://$(IP):8080/api/logs | jq -r '.logs[] | "\(.ts) [\(.level)] \(.msg)"'

status:
	curl -s http://$(IP):8080/api/status | jq

scan:
	curl -s http://$(IP):8080/api/scan | jq -r '.scan.results | sort_by(.rssi) | reverse[] | "\(.addr)  \(.rssi)dBm  \(.name)"'

ppscan:
	curl -s http://$(IP):8080/api/scan | jq -r '.scan.results | map(select(.name != "")) | sort_by(.rssi) | reverse[] | "\(.addr)  \(.rssi)dBm  \(.name)"'


## Show available targets
help:
	@echo "make atomvm         - Build AtomVM firmware with BLE"
	@echo "make flash-firmware  - Flash AtomVM firmware to ESP32-S3"
	@echo "make app             - Build Erlang application"
	@echo "make flash-app       - Build and flash Erlang app"
	@echo "make flash           - Flash everything (firmware + app)"
	@echo "make monitor         - Open serial monitor (screen)"
	@echo "make clean           - Remove build artifacts"
	@echo ""
	@echo "Configuration:"
	@echo "  PORT=$(PORT)"
	@echo "  IDF_PATH=$(IDF_PATH)"
	@echo "  APP_OFFSET=$(APP_OFFSET)"

## Clean build artifacts
clean:
	rm -rf _build
	cd $(ESP32_DIR) 2>/dev/null && \
		source $(IDF_PATH)/export.sh && \
		idf.py fullclean || true

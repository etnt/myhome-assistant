idf_component_register(
  SRCS
    "ble_port.c"
  INCLUDE_DIRS
    "include"
  PRIV_REQUIRES
    libatomvm
    avm_sys
    bt
    nvs_flash
  WHOLE_ARCHIVE)

# NimBLE headers are not exposed transitively by the bt component
set(NIMBLE_BASE "$ENV{IDF_PATH}/components/bt/host/nimble/nimble")
set(NIMBLE_PORT "$ENV{IDF_PATH}/components/bt/host/nimble")
target_include_directories(${COMPONENT_LIB} PRIVATE
  "${NIMBLE_BASE}/nimble/host/include"
  "${NIMBLE_BASE}/nimble/host/services/gap/include"
  "${NIMBLE_BASE}/nimble/host/util/include"
  "${NIMBLE_BASE}/nimble/include"
  "${NIMBLE_BASE}/porting/nimble/include"
  "${NIMBLE_BASE}/porting/npl/freertos/include"
  "${NIMBLE_BASE}/nimble/transport/include"
  "${NIMBLE_BASE}/nimble/host/store/config/include"
  "${NIMBLE_PORT}/port/include"
)

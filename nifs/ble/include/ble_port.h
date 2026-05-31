#ifndef __BLE_PORT_H__
#define __BLE_PORT_H__

#include <context.h>
#include <globalcontext.h>
#include <term.h>

#ifdef __cplusplus
extern "C" {
#endif

void ble_port_init(GlobalContext *global);
void ble_port_destroy(GlobalContext *global);
Context *ble_port_create_port(GlobalContext *global, term opts);

#ifdef __cplusplus
}
#endif

#endif /* __BLE_PORT_H__ */

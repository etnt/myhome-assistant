# Sensor Integration Plan

## Overview

Integrate I2C sensor data (BME680, SGP30, VEML6030) from the `atomvm_sensors`
library into the myhome_assistant system, exposing readings via the HTTP API
and displaying them in the web UI.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  myhome_sup                         │
│                                                     │
│  ┌──────────────┐   ┌────────────────────────────┐  │
│  │ myhome_http  │   │ myhome_sensors (new)       │  │
│  │              │   │   - opens I2C bus          │  │
│  │ GET /api/    │   │   - inits configured       │  │
│  │   sensors    │◄──│     sensor drivers         │  │
│  │              │   │   - polls on interval      │  │
│  └──────────────┘   │   - caches latest readings │  │
│                     │   - publishes to event_bus │  │
│                     └────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

## 1. Configuration

Add sensor configuration to `myhome_config.erl`:

```erlang
-export([sensors/0]).

sensors() ->
    #{
        i2c => #{sda => 40, scl => 39, speed_hz => 100000},
        devices => [
            #{type => bme680,   addr => 16#76},
            #{type => sgp30,    addr => 16#58},
            #{type => veml6030, addr => 16#10}
        ],
        poll_interval_ms => 5000
    }.
```

**Note:** SDA=GPIO40, SCL=GPIO39 on ESP32-S3. These are valid I2C-capable
pins (any GPIO on ESP32-S3 can be routed to I2C via the GPIO matrix).
Verify with `i2c_scanner` after flashing.

The `devices` list declares which sensors to initialise. If a sensor fails
to init (not present on the bus), it is skipped with a warning log — the
system continues with whatever sensors respond.

## 2. New Module: `myhome_sensors`

A `gen_server` responsible for:

1. **init/1** — Open the I2C bus, iterate over configured devices, call
   each driver's `init/2`, store handles for those that succeed.
2. **Periodic polling** — Every `poll_interval_ms`, read all active sensors
   and cache the latest values in process state.
3. **API** — `myhome_sensors:get_readings/0` returns the latest cached map.
4. **Event bus** — After each poll cycle, publish a
   `{sensor_update, Readings}` event so other components can react
   (e.g., future automation rules).

### State shape

```erlang
-record(state, {
    i2c,                %% I2C bus handle
    devices = [],       %% [{type, handle}]
    readings = #{},     %% #{bme680 => #{temp => ..., ...}, ...}
    interval            %% poll interval in ms
}).
```

### Reading format

```erlang
#{
    bme680 => #{
        temperature_c => 23.4,
        pressure_hpa => 1013.2,
        humidity_pct => 45.1,
        gas_ohms => 125000.0,
        ts => 1717500000
    },
    sgp30 => #{
        eco2_ppm => 412,
        tvoc_ppb => 15,
        ts => 1717500000
    },
    veml6030 => #{
        lux => 342.5,
        white_lux => 410.2,
        ts => 1717500000
    }
}
```

## 3. HTTP API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/sensors` | All latest readings (JSON) |
| `GET` | `/api/sensors/bme680` | Single sensor readings |
| `GET` | `/api/sensors/sgp30` | Single sensor readings |
| `GET` | `/api/sensors/veml6030` | Single sensor readings |

### Example response: `GET /api/sensors`

```json
{
  "status": "ok",
  "sensors": {
    "bme680": {
      "temperature_c": 23.4,
      "pressure_hpa": 1013.2,
      "humidity_pct": 45.1,
      "gas_ohms": 125000.0,
      "ts": 1717500000
    },
    "sgp30": {
      "eco2_ppm": 412,
      "tvoc_ppb": 15,
      "ts": 1717500000
    },
    "veml6030": {
      "lux": 342.5,
      "white_lux": 410.2,
      "ts": 1717500000
    }
  }
}
```

## 4. UI Design

Add a **Sensors** section to the dashboard with one card per active sensor.
The cards auto-update every 5 seconds (matching the poll interval).

### BME680 Card

```
┌─────────────────────────────────┐
│  🌡  Environment (BME680)       │
│                                 │
│  Temperature    23.4 °C         │
│  Humidity       45.1 %          │
│  Pressure       1013.2 hPa      │
│  Gas (VOC)      125 kΩ          │
└─────────────────────────────────┘
```

### SGP30 Card

```
┌─────────────────────────────────┐
│  🌬  Air Quality (SGP30)        │
│                                 │
│  eCO₂           412 ppm         │
│  TVOC           15 ppb          │
│                                 │
│  ██████░░░░  Good               │
└─────────────────────────────────┘
```

Quality indicator thresholds:
- eCO₂ < 600 → Good (green)
- eCO₂ 600–1000 → Moderate (yellow)
- eCO₂ > 1000 → Poor (red)

### VEML6030 Card

```
┌─────────────────────────────────┐
│  ☀  Light (VEML6030)            │
│                                 │
│  Ambient        342 lux         │
│  White          410 lux         │
└─────────────────────────────────┘
```

### Auto-refresh

```javascript
setInterval(async () => {
  const data = await api('GET', '/api/sensors');
  if (data && data.sensors) renderSensors(data.sensors);
}, 5000);
```

## 5. Supervisor Integration

Add `myhome_sensors` as a child of `myhome_sup`, started **after** the
BLE/HTTP workers so the HTTP server is ready when sensor data arrives:

```erlang
SensorsSpec = #{
    id => myhome_sensors,
    start => {myhome_sensors, start_link, []},
    restart => permanent,
    shutdown => 5000,
    type => worker
},
```

## 6. Implementation Order

1. **`myhome_sensors` gen_server** — I2C init, polling loop, cached state
2. **`myhome_config` update** — add `sensors/0` export
3. **HTTP handler** — add `GET /api/sensors` routes
4. **UI** — sensor cards with auto-refresh
5. **Event bus integration** — publish readings for future automations

## 7. Error Handling

- **Sensor not present:** Log warning at startup, exclude from poll loop.
- **Read failure mid-operation:** Log error, keep previous cached value,
  retry on next poll cycle.
- **I2C bus failure:** Log error, attempt bus re-open on next poll.
  Mark all readings as stale (add `stale: true` in JSON if reading
  age exceeds 3× poll interval).
- **SGP30 warm-up:** First 15s returns eCO₂=400, TVOC=0. The UI should
  show "Warming up..." until real values arrive.

## 8. Future Extensions

- **History:** Ring buffer of last N readings for sparkline graphs in UI.
- **Alerts:** Threshold-based notifications (e.g., CO₂ > 1200 ppm).
- **Baseline persistence:** Save/restore SGP30 baseline to NVS every hour.
- **Dynamic scan:** `POST /api/sensors/scan` to run `i2c_scanner` on demand.

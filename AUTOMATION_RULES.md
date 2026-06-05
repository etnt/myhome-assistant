# Automation Rules

The automation rules engine (`myhome_rules`) reacts to sensor readings and
time-of-day to control lights automatically. Rules are defined in
`myhome_config:policies/0` and evaluated every time a sensor reading arrives
(~5 seconds) or on a one-minute timer tick.

## Concepts

### Policies

Rules are grouped into **policies**. A policy is a named collection of rules
that can be enabled or disabled as a unit — e.g. disable `evening_comfort`
when on holiday, or enable `energy_saver` during winter months.

```erlang
#{id => policy_name, enabled => true | false, rules => [Rule, ...]}
```

### Rules

Each rule has:

| Field       | Type     | Description |
|-------------|----------|-------------|
| `id`        | atom     | Unique name within the policy |
| `trigger`   | `sensor \| timer` | When to evaluate: on sensor update or timer tick |
| `condition` | fun/1    | `fun(Context) -> boolean()` — decides whether to fire |
| `action`    | fun/0    | `fun() -> ok` — what to do when the rule fires |
| `cooldown`  | integer  | Minimum milliseconds between consecutive firings |

### Context Map

The condition function receives a context map combining sensor readings with
local clock state:

```erlang
#{
    lux         => float(),      %% from VEML6030
    temperature => float(),      %% from BME680 (°C)
    humidity    => float(),      %% from BME680 (%)
    hour        => 0..23,        %% local time (timezone-aware)
    minute      => 0..59
}
```

Every rule has access to both time and lux, which is essential at Swedish
latitudes where sunset varies from 15:00 (December) to never (midsummer).

## Writing Rules

Rules are defined in `src/myhome_config.erl` inside the `policies/0` function.

### Minimal Example

```erlang
#{id => my_policy, enabled => true, rules => [
    #{id => my_rule,
      trigger => sensor,
      condition => fun(#{lux := Lux}) -> Lux < 30 end,
      action => fun() ->
          myhome_hue_ble:set_power(bulb_1, true)
      end,
      cooldown => 60000}   %% 1 minute
]}
```

### Combining Time + Lux

Pure time-window rules would be wrong half the year in Sweden. Combine a
**time window** (when the rule is eligible) with a **lux threshold** (actual
darkness):

```erlang
#{id => lights_on_dark,
  trigger => sensor,
  condition => fun(#{lux := Lux, hour := H}) ->
      %% Eligible 14:00–23:00; fires when actually dark.
      %% In June this won't fire until ~22:00 (lux finally drops).
      %% In December it fires around 15:00.
      H >= 14 andalso H < 23 andalso Lux < 50
  end,
  action => fun() ->
      lists:foreach(fun(Bulb) ->
          myhome_hue_ble:set_power(Bulb, true),
          myhome_hue_ble:set_brightness(Bulb, 204)  %% ~80%
      end, myhome_config:bulb_names())
  end,
  cooldown => 300000}   %% 5 minutes
```

### Timer-Based Rules

Use `trigger => timer` for rules evaluated every 60 seconds rather than on
each sensor reading. Good for actions that don't need sensor-speed response:

```erlang
#{id => lights_off_night,
  trigger => timer,
  condition => fun(#{hour := H, lux := Lux}) ->
      %% After midnight AND dark (not a bright midsummer night)
      H >= 0 andalso H < 6 andalso Lux < 100
  end,
  action => fun() ->
      lists:foreach(fun(Bulb) ->
          myhome_hue_ble:set_power(Bulb, false)
      end, myhome_config:bulb_names())
  end,
  cooldown => 600000}   %% 10 minutes
```

## Built-in Policies

| Policy | Default | Description |
|--------|---------|-------------|
| `evening_comfort` | enabled | Turns lights on when dark (14:00–23:00), off when bright |
| `night_shutoff` | enabled | Turns off lights after midnight if dark |
| `morning_assist` | enabled | Turns on lights at reduced brightness on dark mornings (06:00–09:00) |
| `energy_saver` | disabled | Turns off all lights during work hours (08:00–17:00) |

## Runtime Control

Policies can be enabled/disabled at runtime via the HTTP API (changes don't
survive reboot):

```bash
# List policies and their status
curl http://<esp-ip>:8080/api/policies

# Enable a policy
curl -X POST http://<esp-ip>:8080/api/policies/energy_saver/enable

# Disable a policy
curl -X POST http://<esp-ip>:8080/api/policies/evening_comfort/disable
```

Or from the Erlang shell:

```erlang
myhome_rules:enable_policy(energy_saver).
myhome_rules:disable_policy(evening_comfort).
myhome_rules:list_policies().
```

## Cooldown & Hysteresis

The `cooldown` field prevents flapping — e.g. lights toggling every 5 seconds
when lux hovers around the threshold. Set it to at least a few minutes for
light controls.

Additionally, use a **deadband** between on and off thresholds:
- Turn on at lux < 50
- Turn off at lux > 200

The 150 lux gap prevents oscillation when clouds pass.

## Timezone

Local time is derived from UTC (synced via SNTP) using a POSIX TZ string
configured in `myhome_config:timezone/0`:

```erlang
timezone() -> "CET-1CEST,M3.5.0,M10.5.0/3".
```

This encodes CET (UTC+1) with CEST (UTC+2) summer time, transitioning on
the last Sunday of March and last Sunday of October — matching Swedish time.

## Available Actions

| Function | Description |
|----------|-------------|
| `myhome_hue_ble:set_power(Name, true\|false)` | Turn bulb on/off |
| `myhome_hue_ble:set_brightness(Name, 1..254)` | Set brightness |
| `myhome_hue_ble:set_color_temp(Name, 153..500)` | Set color temperature (mirek) |
| `myhome_hue_ble:set_color_xy(Name, X, Y)` | Set CIE XY color |
| `myhome_hue_ble:set_state(Name, Map)` | Set multiple properties at once |

Use `myhome_config:bulb_names()` to iterate over all registered bulbs.

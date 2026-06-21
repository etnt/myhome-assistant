# Philips WiZ Lamp Control

## Overview

WiZ lamps are controlled over the local network with JSON-over-UDP on port
`38899` (no cloud, no hub). The ESP32-S3 brain already runs a WiFi stack for the
HTTP API, and AtomVM ships a working `gen_udp`. **WiZ control therefore needs no
new hardware and no new radio** — a single `myhome_wiz` gen_server on the S3 can
send `setPilot` packets directly to each lamp.

This plan leads with that direct-UDP design (Option A, recommended) and keeps a
dedicated-worker design (Option B) as a fallback only for the case where WiFi
must be physically isolated from the brain.

> **Reality check vs. earlier draft.** The previous version of this plan offloaded
> WiZ to a Raspberry Pi Pico W over UART. Two problems make that the wrong default:
> 1. **AtomVM has no `uart` module.** `uart:open/2`, `uart:write/2` and
>    `{uart, Port, Data}` messages do not exist. The project's established
>    inter-chip transport is **I2C + a GPIO interrupt line** (see
>    [myhome_ble_i2c.erl](../src/myhome_ble_i2c.erl), XIAO nRF52840 at `0x08`).
> 2. **The S3 already owns the WiFi radio** for the HTTP server, so sending a few
>    UDP datagrams adds negligible contention. The "radio isolation" argument that
>    justified a second chip is weak here.

## Recommended Architecture (Option A — direct UDP from the S3)

```
   +-------------------------------+
   |          ESP32-S3             |
   |          "The Brain"          |
   |                               |
   |  AtomVM / Erlang              |
   |  WiFi (already up)            |        local WiFi LAN
   |  HTTP API (myhome_http)       |   UDP :38899  +----------------+
   |  Event bus + rules            |==============>|   WiZ lamps    |
   |  myhome_wiz (gen_server) NEW  |   setPilot    | (Matter/WiFi)  |
   |  myhome_ble_i2c -> XIAO BLE   |               +----------------+
   +-------------------------------+
```

- No extra microcontroller, no UART, no I2C changes.
- `myhome_wiz` mirrors the structure of the existing
  [myhome_hue_ble.erl](../src/myhome_hue_ble.erl) controller: a `gen_server`
  with synchronous `gen_server:call/3` API, a state record, and `myhome_log`
  logging. This keeps the rules engine and HTTP handler integration identical to
  how Hue bulbs are already controlled.

WiZ is a natural fit for this codebase: it is purely fire-and-forget UDP, so
unlike the persistent-connection BLE bulbs it needs no connection state machine.

## WiZ Local UDP Protocol

WiZ lamps speak JSON over UDP on port `38899`.

| Action | Method | Params |
|--------|--------|--------|
| Power on/off | `setPilot` | `{"state": true\|false}` |
| Brightness | `setPilot` | `{"dimming": 10..100}` |
| Color temperature | `setPilot` | `{"temp": 2200..6500}` (Kelvin) |
| RGB | `setPilot` | `{"r":0..255,"g":0..255,"b":0..255}` |
| Scene | `setPilot` | `{"sceneId": 1..32}` |
| Read state | `getPilot` | `{}` (lamp replies with current state) |

Example request body: `{"method":"setPilot","params":{"state":true}}`. The lamp
returns `{"method":"setPilot","env":"pro","result":{"success":true}}`.

> **AtomVM gotchas baked into the code below**
> ([repo memory](../../../memories/repo/atomvm-compat.md)):
> - Build JSON payloads with `iolist_to_binary/1`, **not** `list_to_binary/1` on a
>   nested iolist — the latter hangs at the C level in AtomVM.
> - Avoid `io_lib:format` width/base specifiers; plain `integer_to_binary/1` is safe.
> - `myhome_log:log/2,3` only writes to the in-memory ring buffer (HTTP `/logs`).
>   Use `io:format/2` for live serial debugging on `minicom`.

## `myhome_wiz` Controller (src/myhome_wiz.erl)

A single gen_server holds one reusable UDP socket and exposes a clean API. It
follows the conventions in [myhome_hue_ble.erl](../src/myhome_hue_ble.erl):
synchronous calls, a state record, and `myhome_log` for diagnostics. Lamps are
addressed by logical name (`living_room`, `bedroom`, ...) resolved through
`myhome_config`, so callers never hardcode IPs.

```erlang
-module(myhome_wiz).
-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([set_power/2, set_brightness/2, set_color_temp/2, set_rgb/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(WIZ_PORT, 38899).
-define(CALL_TIMEOUT, 5000).

-record(state, {
    socket :: port() | undefined
}).

%% --- API --------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Name is a logical lamp name resolved via myhome_config:wiz_lamps/0.
set_power(Name, On) when is_boolean(On) ->
    gen_server:call(?MODULE, {pilot, Name, #{state => On}}, ?CALL_TIMEOUT).

set_brightness(Name, Bri) when Bri >= 10, Bri =< 100 ->
    gen_server:call(?MODULE, {pilot, Name, #{dimming => Bri}}, ?CALL_TIMEOUT).

set_color_temp(Name, Temp) when Temp >= 2200, Temp =< 6500 ->
    gen_server:call(?MODULE, {pilot, Name, #{temp => Temp}}, ?CALL_TIMEOUT).

set_rgb(Name, R, G, B) ->
    gen_server:call(?MODULE, {pilot, Name, #{r => R, g => G, b => B}}, ?CALL_TIMEOUT).

%% --- gen_server callbacks --------------------------------------------

init([]) ->
    %% One long-lived socket; bind to an ephemeral port.
    case gen_udp:open(0, [binary, {active, false}]) of
        {ok, Socket} ->
            myhome_log:log(info, "[myhome_wiz] ready"),
            {ok, #state{socket = Socket}};
        {error, Reason} ->
            myhome_log:log(error, "[myhome_wiz] udp open failed: ~p", [Reason]),
            {stop, Reason}
    end.

handle_call({pilot, Name, Params}, _From, State) ->
    Reply =
        case myhome_config:wiz_lamp_ip(Name) of
            {ok, IP} -> send_pilot(State#state.socket, IP, Params);
            error    -> {error, unknown_lamp}
        end,
    {reply, Reply, State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, #state{socket = undefined}) -> ok;
terminate(_Reason, #state{socket = Socket}) ->
    gen_udp:close(Socket),
    ok.

%% --- internal ---------------------------------------------------------

send_pilot(Socket, IP, Params) ->
    Payload = encode_pilot(Params),
    case gen_udp:send(Socket, IP, ?WIZ_PORT, Payload) of
        ok ->
            ok;
        {error, Reason} ->
            myhome_log:log(error, "[myhome_wiz] send to ~p failed: ~p", [IP, Reason]),
            {error, Reason}
    end.

%% Build {"method":"setPilot","params":{...}} as a binary.
%% Use iolist_to_binary/1 (list_to_binary/1 on iolists hangs in AtomVM).
encode_pilot(Params) ->
    Fields = maps:fold(fun(K, V, Acc) -> [encode_field(K, V) | Acc] end, [], Params),
    Body = lists:join($,, Fields),
    iolist_to_binary([<<"{\"method\":\"setPilot\",\"params\":{">>, Body, <<"}}">>]).

encode_field(state, true)  -> <<"\"state\":true">>;
encode_field(state, false) -> <<"\"state\":false">>;
encode_field(Key, Val) when is_integer(Val) ->
    [$", atom_to_binary(Key, utf8), <<"\":">>, integer_to_binary(Val)].
```

## Configuration (src/myhome_config.erl)

Config in this project lives in [myhome_config.erl](../src/myhome_config.erl) as
functions returning literals (WiFi creds, sensor map, automation policies), not
`sys.config`. Add a lamp registry and a resolver helper there:

```erlang
%% In myhome_config.erl
-export([wiz_lamps/0, wiz_lamp_ip/1]).

wiz_lamps() ->
    #{
        living_room => {192, 168, 1, 150},
        bedroom     => {192, 168, 1, 151},
        kitchen     => {192, 168, 1, 152}
    }.

wiz_lamp_ip(Name) ->
    maps:find(Name, wiz_lamps()).   %% {ok, IP} | error
```

Static lamp IPs are simplest; reserve them as DHCP leases on the router. If lamps
must be runtime-configurable, persist the map with `esp:nvs_set_binary(myhome,
wiz_lamps, term_to_binary(Map))` and read it back with `esp:nvs_get_binary/2`
(returns `binary() | undefined`, **not** `{ok, _}`; keys must be atoms).

## Supervision Tree (src/myhome_sup.erl)

The real tree is two levels (see [myhome_top_sup.erl](../src/myhome_top_sup.erl)
and [myhome_sup.erl](../src/myhome_sup.erl)):

- `myhome_top_sup` (`rest_for_one`): `myhome_log`, `myhome_event_bus`,
  `myhome_ble_i2c`, then `myhome_sup`.
- `myhome_sup` (`one_for_one`): `myhome_scanner`, `myhome_http`,
  `myhome_discovery`, `myhome_sensors`, `myhome_rules`, `myhome_lcd`.

`myhome_wiz` is a leaf worker with no hardware dependency, so it belongs in the
`one_for_one` `myhome_sup`, using the map-based child-spec style already in use:

```erlang
%% In myhome_sup.erl init/1, add to the child list:
WizSpec = #{
    id => myhome_wiz,
    start => {myhome_wiz, start_link, []},
    restart => permanent,
    shutdown => 5000,
    type => worker
},
{ok, {SupFlags, [ScannerSpec, HttpSpec, DiscoverySpec,
                 SensorsSpec, RulesSpec, LcdSpec, WizSpec]}}.
```

## HTTP API Integration (src/myhome_http_handler.erl)

Routes are dispatched in `do_handle/3` and return
`{StatusCode, HeadersMap, BodyBinary}`. Successful JSON replies go through the
existing `json_reply/1` helper (which sets `content-type`). Mirror the Hue
handlers:

```erlang
%% POST /api/wiz/<name>/power   Body: {"on": true|false}
do_handle(post, [<<"wiz">>, Name, <<"power">>], #{body := Body}) ->
    case parse_json_bool(Body, <<"on">>) of
        {ok, On} ->
            case myhome_wiz:set_power(lamp_name(Name), On) of
                ok              -> json_reply(#{status => ok});
                {error, Reason} -> json_reply(#{status => error, reason => to_bin(Reason)})
            end;
        error -> {400, #{}, <<"Bad Request">>}
    end;

%% POST /api/wiz/<name>/brightness   Body: {"brightness": 10..100}
do_handle(post, [<<"wiz">>, Name, <<"brightness">>], #{body := Body}) ->
    case parse_json_int(Body, <<"brightness">>) of
        {ok, Bri} ->
            case myhome_wiz:set_brightness(lamp_name(Name), Bri) of
                ok              -> json_reply(#{status => ok});
                {error, Reason} -> json_reply(#{status => error, reason => to_bin(Reason)})
            end;
        error -> {400, #{}, <<"Bad Request">>}
    end.

%% Resolve a path segment (binary) to the config atom key.
lamp_name(Bin) -> binary_to_atom(Bin, utf8).
```

> `binary_to_atom/2` on an untrusted path segment grows the atom table. The keys
> are bounded by `myhome_config:wiz_lamps/0`, and `myhome_wiz` returns
> `{error, unknown_lamp}` for anything not in the map, so an unknown name fails
> cleanly rather than actuating a lamp — but if the route is ever exposed beyond
> the LAN, validate the name against `wiz_lamps()` before converting.

## Rules Engine Integration

Automation actions live in `myhome_config:policies/0` and call device APIs
directly (the same way they call `myhome_hue_ble:set_power/2`). WiZ lamps slot in
with no new machinery:

```erlang
#{id => wiz_evening_warm,
  trigger => sensor,
  condition => fun(#{lux := Lux, hour := H}) -> H >= 18 andalso Lux < 40 end,
  action => fun() ->
      myhome_wiz:set_power(living_room, true),
      myhome_wiz:set_color_temp(living_room, 2700),
      myhome_wiz:set_brightness(living_room, 60)
  end,
  cooldown => 300000}
```

## Testing

### Host-side protocol check (fastest feedback)

Before flashing, confirm the lamp and payload format from any machine on the LAN:

```bash
# Turn a lamp on
echo -n '{"method":"setPilot","params":{"state":true}}' \
  | nc -u -w1 192.168.1.150 38899

# Read current state
echo -n '{"method":"getPilot","params":{}}' \
  | nc -u -w1 192.168.1.150 38899
```

### On-device

1. Add `myhome_wiz` to `myhome_sup`, build, and flash the S3.
2. Drive it from the HTTP API:
   ```bash
   curl -X POST http://<s3-ip>:8080/api/wiz/living_room/power \
     -H 'Content-Type: application/json' -d '{"on": true}'
   ```
3. Watch `myhome_log` output at `http://<s3-ip>:8080/logs`, or attach `minicom`
   and use `io:format/2` while iterating.

## Project Layout

```
src/
  myhome_wiz.erl     (NEW — UDP controller gen_server)
  myhome_config.erl  (add wiz_lamps/0, wiz_lamp_ip/1, optional policies)
  myhome_sup.erl     (add WizSpec child)
  myhome_http_handler.erl (add /api/wiz/* routes)
```

## Bill of Materials (Option A)

| Qty | Component | Notes |
|-----|-----------|-------|
| 1 | ESP32-S3 dev board | Already in use (the brain); WiFi already up |
| N | Philips WiZ lamps | Target devices on the same 2.4 GHz LAN |

No additional hardware is required.

---

## Option B — Dedicated WiFi worker (only if WiFi must be isolated)

Use this only if you have a hard requirement to keep the WiZ WiFi traffic off the
brain's radio. It adds real complexity for little benefit given the S3 already
runs WiFi.

**Transport.** Do **not** assume UART — AtomVM has no `uart` module. The
project's proven inter-chip transport is **I2C + a GPIO interrupt** line, exactly
as `myhome_ble_i2c` talks to the XIAO nRF52840 BLE bridge at address `0x08`. A
WiZ worker would be a second I2C slave (e.g. `0x09`) on the same bus:

```
   ESP32-S3 (brain) --- I2C (SDA/SCL) --- shared bus --- WiZ worker (0x09)
                          ^                                  |
                          |                              WiFi -> UDP :38899 -> lamps
                  myhome_ble_i2c owns the bus;
                  add a myhome_wiz_i2c client
```

**Worker chip choice.** The board must have its own WiFi:
- **Raspberry Pi Pico W** — supported by AtomVM, ~$6, has WiFi. Viable.
- **XIAO nRF52840** (the chip already used for BLE) — **no WiFi**, cannot do this job.

**Brain side.** Add a `myhome_wiz_i2c` module that borrows the shared bus handle
via `myhome_ble_i2c:get_i2c()` and writes command frames to the worker's address
with `i2c:write_bytes/3`. Note `i2c:write_bytes/3` does **not** surface a NAK, so
add an explicit ACK/error register the brain reads back with `i2c:read_bytes/3`,
and signal completion from the worker on a dedicated GPIO interrupt line
(`gpio:attach_interrupt(Pin, falling)`, message `{gpio_interrupt, Pin}`).

**Frame protocol (binary, not text).** Match the register/command style of
`myhome_ble_i2c` rather than newline CSV: `<<Reg, Cmd, Len, Payload/binary>>`
where the payload carries the packed lamp IP and parameters.

### Open questions (Option B only)

1. **Bus ownership** — confirm a second slave at `0x09` doesn't clash with the
   sensors (`0x77`, `0x48`), LCD (`0x27`/`0x3F`), or XIAO (`0x08`).
2. **WiFi credentials** — provision on the worker's flash, or push over I2C at init?
3. **ACK semantics** — ACK/NACK register layout and timeout handling.
4. **Discovery** — auto-discover lamps on the worker, or keep the static
   `myhome_config:wiz_lamps/0` map on the brain (recommended).

## Recommendation

Implement **Option A**. It reuses the existing WiFi stack, matches the
`myhome_hue_ble` controller pattern, requires zero new hardware, and integrates
with the rules engine and HTTP API with no new transport code. Revisit Option B
only if a measured radio-contention problem appears on the S3.


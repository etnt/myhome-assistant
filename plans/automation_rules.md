# Automation Rules Engine Plan

Add a lightweight rules engine that reacts to sensor readings and time-of-day
to control lights automatically.

## Motivation

The system already polls the VEML6030 lux sensor every 5 seconds and publishes
`{sensor_update, Readings}` on the event bus. Light control is available via
`myhome_hue_ble:set_power/2` and `myhome_hue_ble:set_brightness/2`. What's
missing is the glue: a process that subscribes to events, evaluates rules, and
fires actions.

## Example Rules

| Trigger | Condition | Action |
|---------|-----------|--------|
| `sensor_update` | Lux < 50 | Turn on all lamps at 80% brightness |
| `sensor_update` | Lux > 200 | Turn off all lamps |
| Timer (every minute) | Time >= 00:00 and Time < 06:00 | Turn off all lamps |
| Timer (every minute) | Time >= 07:00 and Lux < 80 | Turn on lamps at 50% |

## Architecture

### New Module: `myhome_rules.erl`

A gen_server that:
1. Subscribes to `myhome_event_bus` with a filter for `{sensor_update, _}`
2. Runs a one-minute timer for time-based rules
3. Evaluates a list of rules on each trigger
4. Fires actions (with deduplication to avoid repeated commands)

```
myhome_sup (one_for_one)
  ├── myhome_scanner
  ├── myhome_ble_conn
  ├── myhome_http
  ├── myhome_discovery
  ├── myhome_sensors
  └── myhome_rules         ← NEW
```

### Rule Data Structure

```erlang
-record(rule, {
    id         :: atom(),
    policy     :: atom(),         %% parent policy (for logging)
    trigger    :: sensor | timer,
    condition  :: fun((Context :: map()) -> boolean()),
    action     :: fun(() -> ok),
    cooldown   :: non_neg_integer(),  %% minimum ms between firings
    last_fired :: integer() | undefined
}).
```

The `Context` map passed to conditions combines sensor readings with
clock state — every condition has access to both:

```erlang
#{
    lux         => float(),      %% from veml6030
    temperature => float(),      %% from bme680 (°C)
    humidity    => float(),      %% from bme680 (%)
    hour        => 0..23,        %% from erlang:time() (SNTP-synced)
    minute      => 0..59
}
```

This means **every rule can use both time and lux** in its condition,
which is essential at Swedish latitudes where sunset varies from 15:00
(December) to never (midsummer in northern Sweden — the sun doesn't set).
Lux is the only reliable "is it dark?" signal; time merely bounds eligibility.

### Policies and Rules

Rules are grouped into **policies**. A policy is a named collection of rules
that can be enabled or disabled as a unit (via HTTP API or config). This makes
it easy to switch behaviour — e.g. disable `evening_comfort` when on holiday,
or enable `energy_saver` during winter months.

```erlang
-type policy() :: #{
    id      := atom(),
    enabled := boolean(),
    rules   := [rule()]
}.

-type rule() :: #{
    id        := atom(),
    trigger   := sensor | timer,
    condition := fun((context()) -> boolean()),
    action    := fun(() -> ok),
    cooldown  := non_neg_integer()   %% ms between firings
}.
```

### Configuration

Rules are defined in `myhome_config.erl` to keep everything in one place
(consistent with existing wifi/sensor config pattern).

Since Sweden has extreme seasonal variation (midsummer ~18h daylight,
midwinter ~6h), pure time-window rules would be wrong half the year.
Every light rule therefore combines a **time window** (when the rule is
eligible) with a **lux threshold** (actual darkness). The time window
prevents false triggers (e.g. a shadow at noon), while lux handles the
fact that "dark enough" arrives at 15:30 in December but 22:00 in June.

```erlang
policies() ->
    [
        #{id => evening_comfort, enabled => true, rules => [
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
              cooldown => 300000},  %% 5 min

            #{id => lights_off_bright,
              trigger => sensor,
              condition => fun(#{lux := Lux, hour := H}) ->
                  %% Turn off if it's bright AND within the evening window
                  %% (avoids turning off lights user turned on manually at night)
                  H >= 14 andalso H < 23 andalso Lux > 200
              end,
              action => fun() ->
                  lists:foreach(fun(Bulb) ->
                      myhome_hue_ble:set_power(Bulb, false)
                  end, myhome_config:bulb_names())
              end,
              cooldown => 300000}
        ]},

        #{id => night_shutoff, enabled => true, rules => [
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
              cooldown => 600000}  %% 10 min
        ]},

        #{id => morning_assist, enabled => true, rules => [
            #{id => lights_on_morning,
              trigger => timer,
              condition => fun(#{hour := H, minute := M, lux := Lux}) ->
                  %% Weekday mornings: if it's dark at wake-up time, help out.
                  %% In winter sunrise can be as late as 09:00.
                  H >= 6 andalso H < 9 andalso M < 30 andalso Lux < 40
              end,
              action => fun() ->
                  lists:foreach(fun(Bulb) ->
                      myhome_hue_ble:set_power(Bulb, true),
                      myhome_hue_ble:set_brightness(Bulb, 150)  %% ~60%
                  end, myhome_config:bulb_names())
              end,
              cooldown => 600000}
        ]},

        #{id => energy_saver, enabled => false, rules => [
            #{id => lights_off_away,
              trigger => timer,
              condition => fun(#{hour := H}) ->
                  %% Everything off during work hours (enable when away)
                  H >= 8 andalso H < 17
              end,
              action => fun() ->
                  lists:foreach(fun(Bulb) ->
                      myhome_hue_ble:set_power(Bulb, false)
                  end, myhome_config:bulb_names())
              end,
              cooldown => 1800000}  %% 30 min
        ]}
    ].
```

### Module Skeleton

```erlang
-module(myhome_rules).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    policies  :: list(),        %% list of policy maps (each contains rules with runtime state)
    readings  :: map()          %% latest sensor readings (cached)
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    myhome_event_bus:subscribe(self(), fun
        ({sensor_update, _}) -> true;
        (_) -> false
    end),
    erlang:send_after(60000, self(), tick),
    Policies = init_policies(myhome_config:policies()),
    {ok, #state{policies = Policies, readings = #{}}}.

handle_info({sensor_update, Readings}, State) ->
    NewState = State#state{readings = Readings},
    {noreply, evaluate_policies(sensor, NewState)};

handle_info(tick, State) ->
    erlang:send_after(60000, self(), tick),
    {noreply, evaluate_policies(timer, State)};

handle_info(_Msg, State) ->
    {noreply, State}.
```

### Policy API

```erlang
%% Runtime enable/disable (survives until reboot)
-export([enable_policy/1, disable_policy/1, list_policies/0]).

enable_policy(PolicyId) ->
    gen_server:call(?MODULE, {set_policy_enabled, PolicyId, true}).

disable_policy(PolicyId) ->
    gen_server:call(?MODULE, {set_policy_enabled, PolicyId, false}).

list_policies() ->
    gen_server:call(?MODULE, list_policies).
```

### Evaluation Logic

```erlang
evaluate_policies(Trigger, #state{policies = Policies, readings = Readings} = State) ->
    Now = erlang:system_time(millisecond),
    {Hour, Minute, _} = erlang:time(),
    Context = maps:merge(Readings, #{hour => Hour, minute => Minute}),
    NewPolicies = lists:map(fun(Policy) ->
        evaluate_policy(Trigger, Policy, Context, Now)
    end, Policies),
    State#state{policies = NewPolicies}.

evaluate_policy(_Trigger, #{enabled := false} = Policy, _Context, _Now) ->
    Policy;  %% skip disabled policies entirely
evaluate_policy(Trigger, #{rules := Rules} = Policy, Context, Now) ->
    NewRules = lists:map(fun(Rule) ->
        evaluate_one(Trigger, Rule, Context, Now)
    end, Rules),
    Policy#{rules => NewRules}.

evaluate_one(Trigger, #{trigger := T, condition := Cond, action := Act,
                        cooldown := CD, last_fired := Last} = Rule, Context, Now) ->
    ShouldFire = (T =:= Trigger) andalso
                 cooldown_expired(Last, CD, Now) andalso
                 safe_eval(Cond, Context),
    case ShouldFire of
        true ->
            io:format("[rules] Firing ~p/~p~n",
                      [maps:get(policy, Rule, unknown), maps:get(id, Rule)]),
            spawn(fun() -> Act() end),  %% non-blocking
            Rule#{last_fired => Now};
        false ->
            Rule
    end.

cooldown_expired(undefined, _CD, _Now) -> true;
cooldown_expired(Last, CD, Now) -> (Now - Last) >= CD.

safe_eval(Cond, Context) ->
    try Cond(Context) catch _:_ -> false end.
```

### Edge Handling / Hysteresis

To avoid flapping (lights toggling every 5 seconds around the threshold),
the cooldown mechanism provides basic hysteresis. For more sophisticated
control, a future enhancement could add:

- **Deadband**: only fire `lights_on` if lux < 50, but only fire `lights_off`
  if lux > 200 (150 lux gap prevents oscillation)
- **Sustained condition**: require condition to be true for N consecutive
  readings before firing

The initial cooldown approach is simple and sufficient for a first version.

## Implementation Steps

### Phase 1: Core Engine (Day 1)

1. Add `policies/0` and `bulb_names/0` to `myhome_config.erl`
2. Create `src/myhome_rules.erl` with the gen_server skeleton above
3. Add `myhome_rules` child spec to `myhome_sup.erl`
4. Test: verify sensor events are received and logged

### Phase 2: Policy Evaluation (Day 1-2)

5. Implement `evaluate_policies/2` with enabled/disabled filtering
6. Wire actions to `myhome_hue_ble` calls
7. Test: simulate low-lux reading in winter-like hour → verify bulb turns on
8. Test: same lux in summer midday → verify rule does NOT fire (time gate)
9. Test: verify cooldown prevents repeated commands

### Phase 3: Time + Lux Combined Rules (Day 2)

10. Implement tick-based evaluation (timer trigger)
11. Test: midnight + dark → lights off
12. Test: midnight + bright (midsummer) → lights stay on
13. Test: morning dark → lights on at reduced brightness

### Phase 4: HTTP Policy Control (Day 3)

14. Add `GET /api/policies` — list all policies with status
15. Add `POST /api/policies/{id}/enable` and `/disable`
16. Add `GET /api/policies/{id}/rules` — show rules with last_fired times
17. Add manual override flag: if user manually controlled a light via HTTP,
    suppress automation for that bulb for 1 hour

## Timezone Handling

AtomVM's `erlang:localtime/0` and `erlang:time()` currently return **UTC**
(not local time), and fixing this upstream is non-trivial due to underlying
library limitations. Since all rule conditions reason about local hour-of-day,
we need our own UTC→local conversion.

### Approach: POSIX TZ String

Add a timezone config entry using the standard POSIX TZ format:

```erlang
%% In myhome_config.erl
timezone() -> "CET-1CEST,M3.5.0,M10.5.0/3".
```

This encodes:
- Standard time: CET = UTC+1
- DST: CEST = UTC+2
- DST starts: last Sunday of March at 02:00
- DST ends: last Sunday of October at 03:00

### New Helper: `myhome_time.erl`

```erlang
-module(myhome_time).

-export([local_time/0, local_hour/0, local_minute/0, is_dst/0]).

from_my_config_timezone() ->
    "CET-1CEST,M3.5.0,M10.5.0/3".

%% @doc Return {Hour, Minute, Second} in configured local timezone.
local_time() ->
    UtcNow = erlang:universaltime(),  %% {{Y,M,D},{H,Min,S}}
    TzStr = from_my_config_timezone(),
    utc_to_local(UtcNow, parse_posix_tz(TzStr)).

local_hour() ->
    {H, _, _} = local_time(),
    H.

local_minute() ->
    {_, M, _} = local_time(),
    M.

%% @doc Return true if the current UTC moment falls within DST (summer time).
%% Useful for diagnostics/debug endpoints; not called by the rules engine
%% directly (local_time/0 handles the offset selection internally).
is_dst() ->
    UtcNow = erlang:universaltime(),
    TzStr = from_my_config_timezone(),
    in_dst(UtcNow, parse_posix_tz(TzStr)).

%%====================================================================
%% Internal: POSIX TZ parsing and conversion
%%====================================================================

-type transition() :: {integer(), integer(), integer(), integer()}.

-record(tz,
        {std_offset :: integer(),   %% seconds east of UTC (standard)
         dst_offset :: integer(),   %% seconds east of UTC (DST)
         dst_start :: transition(),
         dst_end :: transition()}).

%% transition() :: {Month, Week, DayOfWeek, Hour}
%%   Month 1-12, Week 1-5 (5=last), DayOfWeek 0=Sun, Hour 0-23

parse_posix_tz(Str) ->
    %% Parse "CET-1CEST,M3.5.0,M10.5.0/3"
    %% Minimal parser — supports the Mm.w.d format used in Europe
    {StdOff, DstOff, Start, End} = do_parse(Str),
    #tz{std_offset = StdOff,
        dst_offset = DstOff,
        dst_start = Start,
        dst_end = End}.

utc_to_local({{Y, Mo, D}, {H, Mi, S}}, #tz{} = Tz) ->
    UtcSecs = calendar:datetime_to_gregorian_seconds({{Y, Mo, D}, {H, Mi, S}}),
    Offset =
        case in_dst({{Y, Mo, D}, {H, Mi, S}}, Tz) of
            true ->
                Tz#tz.dst_offset;
            false ->
                Tz#tz.std_offset
        end,
    LocalSecs = UtcSecs + Offset,
    {{_, _, _}, Time} = calendar:gregorian_seconds_to_datetime(LocalSecs),
    Time.

in_dst(DateTime,
       #tz{dst_start = Start,
           dst_end = End,
           std_offset = StdOff}) ->
    %% Compare current date against DST transition dates for this year
    {{Y, _, _}, _} = DateTime,
    DstStartDT = transition_to_datetime(Y, Start, StdOff),
    DstEndDT = transition_to_datetime(Y, End, StdOff),
    DateTime >= DstStartDT andalso DateTime < DstEndDT.

do_parse(Str) ->
    %% Parse "CET-1CEST,M3.5.0,M10.5.0/3"
    [StdPart, Transitions] = string:split(Str, ","),
    %% Extract offset from "CET-1CEST" -> "-1"
    OffsetStr = extract_offset(StdPart),
    StdOff = list_to_integer(OffsetStr) * 3600,
    [StartStr, EndStr] = string:split(Transitions, ","),
    Start = parse_transition(StartStr),
    End = parse_transition(EndStr),
    DstOff = StdOff + 3600,
    {StdOff, DstOff, Start, End}.

extract_offset(Str) ->
    %% "CET-1CEST" -> "1" (POSIX TZ: negative means east of UTC, so flip sign)
    case string:split(Str, "-") of
        [_, Rest] ->
            extract_digits(Rest);
        _ ->
            case string:split(Str, "+") of
                [_, Rest] -> "-" ++ extract_digits(Rest);
                _ -> "0"
            end
    end.

extract_digits(Str) ->
    lists:takewhile(fun(C) -> C >= $0 andalso C =< $9 end, Str).

parse_transition(Str) ->
    %% Parse "M3.5.0" or "M10.5.0/3"
    case string:split(Str, "/") of
        [MStr] -> Hour = 2, MStr2 = MStr;
        [MStr2, HStr] -> Hour = list_to_integer(HStr)
    end,
    [$M | Rest] = MStr2,
    [MoStr, WeekStr, DowStr] = string:split(Rest, ".", all),
    {list_to_integer(MoStr), list_to_integer(WeekStr), list_to_integer(DowStr), Hour}.

transition_to_datetime(Year, {Month, Week, DayOfWeek, Hour}, _StdOff) ->
    %% Find the Week'th DayOfWeek in Month at Hour:00:00
    FirstDay = calendar:day_of_the_week({Year, Month, 1}),
    FirstDow = FirstDay rem 7,
    Offset = (DayOfWeek - FirstDow + 7) rem 7,
    FirstOccurrence = 1 + Offset,
    Day = if
        Week == 5 ->
            LastDay = calendar:last_day_of_the_month(Year, Month),
            LastOccurrence = FirstOccurrence + 28,
            if LastOccurrence > LastDay -> LastOccurrence - 7;
               true -> LastOccurrence
            end;
        true ->
            FirstOccurrence + (Week - 1) * 7
    end,
    {{Year, Month, Day}, {Hour, 0, 0}}.
```

### Integration with Rules Engine

The `evaluate_policies/2` function builds the context using `myhome_time`
instead of raw `erlang:time()`:

```erlang
%% In myhome_rules.erl
build_context(Readings) ->
    {Hour, Minute, _} = myhome_time:local_time(),
    maps:merge(Readings, #{hour => Hour, minute => Minute}).
```

### Why Not NIF/NTP-based localtime?

- SNTP gives us correct UTC (already needed) — that part works fine
- The gap is only UTC→local conversion, which is pure arithmetic
- A ~60-line Erlang module is simpler and more portable than patching AtomVM
- POSIX TZ strings are well-understood and cover all EU timezone rules

## AtomVM Considerations

- `erlang:system_time(millisecond)` — available in AtomVM since 0.6
- `erlang:universaltime()` — returns UTC datetime after SNTP sync;
  local time derived via `myhome_time` module (see above)
- `calendar:datetime_to_gregorian_seconds/1` — verify availability in
  AtomVM's estdlib; if missing, implement with a simple epoch calculation
- Anonymous functions in config — works fine in AtomVM, but the module
  containing the funs (`myhome_config`) must be loaded before `myhome_rules`
  starts (already guaranteed by supervisor ordering).

## Open Questions

1. **SNTP** — Is NTP time sync already configured? If not, need to add
   `network:sntp_sync(["pool.ntp.org"])` at startup.
2. **Manual override** — Should a manual HTTP command suppress automation
   for that bulb temporarily? (Phase 4 above)
3. **Transition brightness** — Instead of binary on/off, ramp brightness
   based on lux (e.g., map lux 0-100 → brightness 255-100)?
4. **Persistent state** — Should `last_fired` timestamps survive a reboot?
   Probably not needed since rules re-evaluate within 60s of boot.

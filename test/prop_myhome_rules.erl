-module(prop_myhome_rules).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Generators
%%====================================================================

%% Sensor readings map as published by myhome_sensors
sensor_readings() ->
    ?LET({Lux, Temp, Hum},
         {float(0.0, 10000.0), float(-20.0, 50.0), float(0.0, 100.0)},
         #{veml6030 => #{lux => Lux, white_lux => Lux * 0.8},
           bme680 => #{temperature_c => Temp, humidity_pct => Hum,
                       pressure_hpa => 1013.0, gas_ohms => 50000}}).

%% Partial readings (only one sensor present)
partial_readings() ->
    oneof([
        ?LET({L, W}, {float(0.0, 10000.0), float(0.0, 8000.0)},
             #{veml6030 => #{lux => L, white_lux => W}}),
        ?LET({T, H}, {float(-20.0, 50.0), float(0.0, 100.0)},
             #{bme680 => #{temperature_c => T, humidity_pct => H,
                           pressure_hpa => 1013.0, gas_ohms => 50000}}),
        exactly(#{})
    ]).

%% Timestamps (millisecond epoch-ish values)
timestamp() ->
    integer(0, 100000000).

%% Cooldown values
cooldown() ->
    oneof([0, 1000, 60000, 300000, 600000, 1800000]).

%%====================================================================
%% Properties: flatten_readings
%%====================================================================

%% flatten_readings always produces a map with lux, temperature, humidity keys
prop_flatten_always_has_keys() ->
    ?FORALL(Readings, oneof([sensor_readings(), partial_readings()]),
        begin
            Flat = myhome_rules:flatten_readings(Readings),
            maps:is_key(lux, Flat) andalso
            maps:is_key(temperature, Flat) andalso
            maps:is_key(humidity, Flat)
        end).

%% flatten_readings values are always numbers
prop_flatten_values_are_numbers() ->
    ?FORALL(Readings, oneof([sensor_readings(), partial_readings()]),
        begin
            #{lux := L, temperature := T, humidity := H} =
                myhome_rules:flatten_readings(Readings),
            is_number(L) andalso is_number(T) andalso is_number(H)
        end).

%% When full readings are present, flatten extracts the correct lux
prop_flatten_preserves_lux() ->
    ?FORALL(Lux, float(0.0, 10000.0),
        begin
            Readings = #{veml6030 => #{lux => Lux, white_lux => 0.0}},
            #{lux := Got} = myhome_rules:flatten_readings(Readings),
            Got =:= Lux
        end).

%%====================================================================
%% Properties: cooldown_expired
%%====================================================================

%% undefined last_fired always means expired
prop_cooldown_undefined_always_expired() ->
    ?FORALL({CD, Now}, {cooldown(), timestamp()},
        myhome_rules:cooldown_expired(undefined, CD, Now) =:= true).

%% If (Now - Last) >= CD, it's expired
prop_cooldown_math_correct() ->
    ?FORALL({Last, CD, Extra},
            {timestamp(), cooldown(), non_neg_integer()},
        begin
            Now = Last + CD + Extra,
            myhome_rules:cooldown_expired(Last, CD, Now) =:= true
        end).

%% If (Now - Last) < CD, it's NOT expired
prop_cooldown_not_expired_when_recent() ->
    ?FORALL({Last, CD}, {integer(1000, 100000000), integer(2000, 1800000)},
        begin
            %% Now is 1ms before cooldown expires
            Now = Last + CD - 1,
            Now > Last andalso  %% guard against overflow in test
            myhome_rules:cooldown_expired(Last, CD, Now) =:= false
        end).

%%====================================================================
%% Properties: safe_eval
%%====================================================================

%% safe_eval never raises, regardless of condition or context
prop_safe_eval_never_crashes() ->
    ?FORALL(Context, oneof([
                #{lux => float(0.0, 1000.0), hour => integer(0, 23), minute => integer(0, 59)},
                #{},
                #{foo => bar}
            ]),
        begin
            %% Try various condition functions, some of which will crash
            Conditions = [
                fun(#{lux := L}) -> L < 50 end,           %% may crash on missing key
                fun(_) -> true end,
                fun(_) -> false end,
                fun(_) -> error(deliberate) end,
                fun(#{nonexistent := _}) -> true end       %% always crashes
            ],
            lists:all(fun(Cond) ->
                Result = myhome_rules:safe_eval(Cond, Context),
                Result =:= true orelse Result =:= false
            end, Conditions)
        end).

%%====================================================================
%% Properties: evaluate_one
%%====================================================================

%% A rule with trigger mismatch never fires (last_fired stays unchanged)
prop_wrong_trigger_never_fires() ->
    ?FORALL({Now, Lux, Hour},
            {timestamp(), float(0.0, 1000.0), integer(0, 23)},
        begin
            Rule = #{id => test, policy => test, trigger => timer,
                     condition => fun(_) -> true end,
                     action => fun() -> ok end,
                     cooldown => 0, last_fired => undefined},
            Context = #{lux => Lux, hour => Hour, minute => 0},
            Result = myhome_rules:evaluate_one(sensor, Rule, Context, Now),
            maps:get(last_fired, Result) =:= undefined
        end).

%% A rule that fires always updates last_fired to Now
prop_fired_rule_updates_timestamp() ->
    ?FORALL(Now, integer(1, 100000000),
        begin
            Rule = #{id => test, policy => test, trigger => sensor,
                     condition => fun(_) -> true end,
                     action => fun() -> ok end,
                     cooldown => 0, last_fired => undefined},
            Context = #{lux => 10.0, hour => 18, minute => 30},
            Result = myhome_rules:evaluate_one(sensor, Rule, Context, Now),
            maps:get(last_fired, Result) =:= Now
        end).

%%====================================================================
%% EUnit wrappers
%%====================================================================

proper_test_() ->
    {timeout, 60, [
        fun() -> ?assert(proper:quickcheck(prop_flatten_always_has_keys(), [quiet, {numtests, 200}])) end,
        fun() -> ?assert(proper:quickcheck(prop_flatten_values_are_numbers(), [quiet, {numtests, 200}])) end,
        fun() -> ?assert(proper:quickcheck(prop_flatten_preserves_lux(), [quiet, {numtests, 200}])) end,
        fun() -> ?assert(proper:quickcheck(prop_cooldown_undefined_always_expired(), [quiet, {numtests, 200}])) end,
        fun() -> ?assert(proper:quickcheck(prop_cooldown_math_correct(), [quiet, {numtests, 200}])) end,
        fun() -> ?assert(proper:quickcheck(prop_cooldown_not_expired_when_recent(), [quiet, {numtests, 200}])) end,
        fun() -> ?assert(proper:quickcheck(prop_safe_eval_never_crashes(), [quiet, {numtests, 200}])) end,
        fun() -> ?assert(proper:quickcheck(prop_wrong_trigger_never_fires(), [quiet, {numtests, 200}])) end,
        fun() -> ?assert(proper:quickcheck(prop_fired_rule_updates_timestamp(), [quiet, {numtests, 200}])) end
    ]}.

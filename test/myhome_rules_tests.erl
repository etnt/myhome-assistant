-module(myhome_rules_tests).
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% flatten_readings tests
%%====================================================================

flatten_full_readings_test() ->
    Readings = #{
        veml6030 => #{lux => 45.5, white_lux => 30.0},
        bme680 => #{temperature_c => 22.3, pressure_hpa => 1013.0,
                    humidity_pct => 55.0, gas_ohms => 50000}
    },
    Result = myhome_rules:flatten_readings(Readings),
    ?assertEqual(45.5, maps:get(lux, Result)),
    ?assertEqual(22.3, maps:get(temperature, Result)),
    ?assertEqual(55.0, maps:get(humidity, Result)).

flatten_missing_veml6030_test() ->
    Readings = #{
        bme680 => #{temperature_c => 20.0, humidity_pct => 60.0}
    },
    Result = myhome_rules:flatten_readings(Readings),
    ?assertEqual(0.0, maps:get(lux, Result)).

flatten_empty_readings_test() ->
    Result = myhome_rules:flatten_readings(#{}),
    ?assertEqual(0.0, maps:get(lux, Result)),
    ?assertEqual(0.0, maps:get(temperature, Result)),
    ?assertEqual(0.0, maps:get(humidity, Result)).

%%====================================================================
%% cooldown_expired tests
%%====================================================================

cooldown_never_fired_test() ->
    ?assertEqual(true, myhome_rules:cooldown_expired(undefined, 300000, 1000000)).

cooldown_not_expired_test() ->
    %% Fired 100ms ago, cooldown is 300000ms
    ?assertEqual(false, myhome_rules:cooldown_expired(999900, 300000, 1000000)).

cooldown_expired_test() ->
    %% Fired 400000ms ago, cooldown is 300000ms
    ?assertEqual(true, myhome_rules:cooldown_expired(600000, 300000, 1000000)).

cooldown_exactly_expired_test() ->
    %% Fired exactly cooldown ms ago — should pass
    ?assertEqual(true, myhome_rules:cooldown_expired(700000, 300000, 1000000)).

%%====================================================================
%% safe_eval tests
%%====================================================================

safe_eval_true_test() ->
    Cond = fun(#{lux := Lux}) -> Lux < 50 end,
    ?assertEqual(true, myhome_rules:safe_eval(Cond, #{lux => 30})).

safe_eval_false_test() ->
    Cond = fun(#{lux := Lux}) -> Lux < 50 end,
    ?assertEqual(false, myhome_rules:safe_eval(Cond, #{lux => 100})).

safe_eval_crash_test() ->
    %% Missing key in context — should not crash, returns false
    Cond = fun(#{lux := Lux}) -> Lux < 50 end,
    ?assertEqual(false, myhome_rules:safe_eval(Cond, #{temperature => 20})).

safe_eval_exception_test() ->
    %% Division by zero — should not crash, returns false
    Cond = fun(_) -> 1 / 0 =:= 0 end,
    ?assertEqual(false, myhome_rules:safe_eval(Cond, #{})).

%%====================================================================
%% evaluate_one tests
%%====================================================================

rule_fires_when_conditions_met_test() ->
    Rule = #{
        id => test_rule,
        policy => test_policy,
        trigger => sensor,
        condition => fun(#{lux := Lux, hour := H}) -> H >= 14 andalso Lux < 50 end,
        action => fun() -> ok end,
        cooldown => 300000,
        last_fired => undefined
    },
    Context = #{lux => 30, hour => 18, minute => 0},
    Now = 1000000,
    Result = myhome_rules:evaluate_one(sensor, Rule, Context, Now),
    ?assertEqual(Now, maps:get(last_fired, Result)).

rule_does_not_fire_wrong_trigger_test() ->
    Rule = #{
        id => test_rule,
        policy => test_policy,
        trigger => timer,
        condition => fun(_) -> true end,
        action => fun() -> ok end,
        cooldown => 300000,
        last_fired => undefined
    },
    Context = #{lux => 30, hour => 18, minute => 0},
    Now = 1000000,
    Result = myhome_rules:evaluate_one(sensor, Rule, Context, Now),
    ?assertEqual(undefined, maps:get(last_fired, Result)).

rule_does_not_fire_cooldown_active_test() ->
    Rule = #{
        id => test_rule,
        policy => test_policy,
        trigger => sensor,
        condition => fun(_) -> true end,
        action => fun() -> ok end,
        cooldown => 300000,
        last_fired => 900000  %% fired 100ms ago
    },
    Context = #{lux => 30, hour => 18, minute => 0},
    Now = 1000000,
    Result = myhome_rules:evaluate_one(sensor, Rule, Context, Now),
    %% last_fired should not be updated
    ?assertEqual(900000, maps:get(last_fired, Result)).

rule_does_not_fire_condition_false_test() ->
    Rule = #{
        id => test_rule,
        policy => test_policy,
        trigger => sensor,
        condition => fun(#{lux := Lux}) -> Lux < 50 end,
        action => fun() -> ok end,
        cooldown => 300000,
        last_fired => undefined
    },
    Context = #{lux => 300, hour => 18, minute => 0},
    Now = 1000000,
    Result = myhome_rules:evaluate_one(sensor, Rule, Context, Now),
    ?assertEqual(undefined, maps:get(last_fired, Result)).

%%====================================================================
%% init_policies tests
%%====================================================================

init_policies_adds_last_fired_test() ->
    Policies = [
        #{id => test_pol, enabled => true, rules => [
            #{id => r1, trigger => sensor, condition => fun(_) -> true end,
              action => fun() -> ok end, cooldown => 1000}
        ]}
    ],
    [#{rules := [Rule]}] = myhome_rules:init_policies(Policies),
    ?assertEqual(undefined, maps:get(last_fired, Rule)),
    ?assertEqual(test_pol, maps:get(policy, Rule)).

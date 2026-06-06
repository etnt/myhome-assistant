%%%-------------------------------------------------------------------
%%% @doc Automation rules engine.
%%% Subscribes to sensor events and evaluates time/lux-based rules
%%% to control lights automatically. Rules are grouped into policies
%%% that can be enabled/disabled at runtime.
%%% @end
%%%-------------------------------------------------------------------
-module(myhome_rules).
-behaviour(gen_server).

-export([start_link/0]).
-export([enable_policy/1, disable_policy/1, list_policies/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-ifdef(TEST).
-export([flatten_readings/1, build_context/1, init_policies/1,
         evaluate_one/4, cooldown_expired/3, safe_eval/2]).
-endif.

-record(state, {
    policies :: list(),     %% list of policy maps with runtime state
    readings :: map()       %% latest flattened sensor readings
}).

%%====================================================================
%% API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec enable_policy(atom()) -> ok | {error, not_found}.
enable_policy(PolicyId) ->
    gen_server:call(?MODULE, {set_policy_enabled, PolicyId, true}).

-spec disable_policy(atom()) -> ok | {error, not_found}.
disable_policy(PolicyId) ->
    gen_server:call(?MODULE, {set_policy_enabled, PolicyId, false}).

-spec list_policies() -> list().
list_policies() ->
    gen_server:call(?MODULE, list_policies).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    myhome_event_bus:subscribe(self(), fun
        ({sensor_update, _}) -> true;
        (_) -> false
    end),
    erlang:send_after(60000, self(), tick),
    Policies = init_policies(myhome_config:policies()),
    io:format("[rules] Started with ~p policies~n", [length(Policies)]),
    {ok, #state{policies = Policies, readings = #{}}}.

handle_call({set_policy_enabled, PolicyId, Enabled}, _From, #state{policies = Policies} = State) ->
    case set_enabled(PolicyId, Enabled, Policies) of
        {ok, NewPolicies} ->
            io:format("[rules] Policy ~p ~s~n",
                      [PolicyId, case Enabled of true -> "enabled"; false -> "disabled" end]),
            myhome_event_bus:publish({policy_changed, PolicyId, Enabled}),
            {reply, ok, State#state{policies = NewPolicies}};
        error ->
            {reply, {error, not_found}, State}
    end;

handle_call(list_policies, _From, #state{policies = Policies} = State) ->
    Now = erlang:system_time(millisecond),
    Summary = lists:map(fun(#{id := Id, enabled := En, rules := Rules}) ->
        %% Find most recent firing across all rules in this policy
        LastFired = lists:foldl(fun(#{last_fired := LF}, Acc) ->
            case LF of
                undefined -> Acc;
                T when Acc =:= undefined -> T;
                T when T > Acc -> T;
                _ -> Acc
            end
        end, undefined, Rules),
        %% "active" if fired within the last cooldown period (use max cooldown)
        MaxCD = lists:max([maps:get(cooldown, R, 0) || R <- Rules]),
        Active = LastFired =/= undefined andalso (Now - LastFired) < MaxCD,
        Base = #{id => Id, enabled => En, rule_count => length(Rules), active => Active},
        case LastFired of
            undefined -> Base;
            _ -> Base#{last_fired_ago_s => (Now - LastFired) div 1000}
        end
    end, Policies),
    {reply, Summary, State};

handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({ble_event, {sensor_update, Readings}}, State) ->
    Flat = flatten_readings(Readings),
    NewState = State#state{readings = Flat},
    {noreply, evaluate_policies(sensor, NewState)};

handle_info(tick, State) ->
    erlang:send_after(60000, self(), tick),
    {noreply, evaluate_policies(timer, State)};

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal
%%====================================================================

%% Initialise policies: add last_fired = undefined to each rule
init_policies(Policies) ->
    lists:map(fun(#{rules := Rules} = Policy) ->
        NewRules = lists:map(fun(Rule) ->
            Rule#{last_fired => undefined, policy => maps:get(id, Policy)}
        end, Rules),
        Policy#{rules => NewRules}
    end, Policies).

%% Set a policy's enabled flag
set_enabled(_Id, _Enabled, []) ->
    error;
set_enabled(Id, Enabled, [#{id := Id} = P | Rest]) ->
    {ok, [P#{enabled => Enabled} | Rest]};
set_enabled(Id, Enabled, [P | Rest]) ->
    case set_enabled(Id, Enabled, Rest) of
        {ok, NewRest} -> {ok, [P | NewRest]};
        error -> error
    end.

%% Flatten nested sensor readings into a single map for rule conditions
flatten_readings(Readings) ->
    Lux = case maps:find(veml6030, Readings) of
        {ok, #{lux := L}} -> L;
        _ -> 0.0
    end,
    {Temp, Hum} = case maps:find(bme680, Readings) of
        {ok, #{temperature_c := T, humidity_pct := H}} -> {T, H};
        _ -> {0.0, 0.0}
    end,
    #{lux => Lux, temperature => Temp, humidity => Hum}.

%% Build the full context map (sensor + time)
build_context(Readings) ->
    {Hour, Minute, _} = myhome_time:local_time(),
    maps:merge(Readings, #{hour => Hour, minute => Minute}).

%% Evaluate all policies for a given trigger
evaluate_policies(Trigger, #state{policies = Policies, readings = Readings} = State) ->
    Now = erlang:system_time(millisecond),
    Context = build_context(Readings),
    NewPolicies = lists:map(fun(Policy) ->
        evaluate_policy(Trigger, Policy, Context, Now)
    end, Policies),
    State#state{policies = NewPolicies}.

evaluate_policy(_Trigger, #{enabled := false} = Policy, _Context, _Now) ->
    Policy;
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
            spawn(fun() -> Act() end),
            Rule#{last_fired => Now};
        false ->
            Rule
    end.

cooldown_expired(undefined, _CD, _Now) -> true;
cooldown_expired(Last, CD, Now) -> (Now - Last) >= CD.

safe_eval(Cond, Context) ->
    try Cond(Context) catch _:_ -> false end.

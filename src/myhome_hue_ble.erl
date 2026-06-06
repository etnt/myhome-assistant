%%%-------------------------------------------------------------------
%%% @doc Hue BLE Light Driver.
%%% A gen_server per bulb that manages the BLE connection and
%%% provides light control operations via the Hue BLE GATT protocol.
%%% @end
%%%-------------------------------------------------------------------
-module(myhome_hue_ble).
-behaviour(gen_server).

%% Public API
-export([start_link/3]).
-export([set_power/2, set_brightness/2, set_color_temp/2]).
-export([set_color_xy/3, set_state/2, get_state/1, read_state/1]).
-export([clear_cooldown/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%%--------------------------------------------------------------------
%% Hue BLE GATT UUIDs (16 bytes, big-endian)
%%--------------------------------------------------------------------

%% Light control service: 932c32bd-0000-47a2-835a-a8d455b859dd
-define(SVC_LIGHT, <<16#93,16#2c,16#32,16#bd, 16#00,16#00, 16#47,16#a2,
                     16#83,16#5a, 16#a8,16#d4,16#55,16#b8,16#59,16#dd>>).

%% Characteristic: 932c32bd-0002-... (power on/off)
-define(CHR_POWER, <<16#93,16#2c,16#32,16#bd, 16#00,16#02, 16#47,16#a2,
                     16#83,16#5a, 16#a8,16#d4,16#55,16#b8,16#59,16#dd>>).

%% Characteristic: 932c32bd-0003-... (brightness)
-define(CHR_BRIGHTNESS, <<16#93,16#2c,16#32,16#bd, 16#00,16#03, 16#47,16#a2,
                          16#83,16#5a, 16#a8,16#d4,16#55,16#b8,16#59,16#dd>>).

%% Characteristic: 932c32bd-0004-... (color temperature)
-define(CHR_COLOR_TEMP, <<16#93,16#2c,16#32,16#bd, 16#00,16#04, 16#47,16#a2,
                          16#83,16#5a, 16#a8,16#d4,16#55,16#b8,16#59,16#dd>>).

%% Characteristic: 932c32bd-0005-... (color XY)
-define(CHR_COLOR_XY, <<16#93,16#2c,16#32,16#bd, 16#00,16#05, 16#47,16#a2,
                        16#83,16#5a, 16#a8,16#d4,16#55,16#b8,16#59,16#dd>>).

%%--------------------------------------------------------------------
%% State
%%--------------------------------------------------------------------

-record(state, {
    name      :: atom(),
    addr      :: binary(),        %% 6-byte BLE address
    addr_type :: integer(),
    conn_handle :: non_neg_integer() | undefined,
    connected :: boolean(),
    %% Cached light state
    power     :: boolean() | undefined,
    brightness :: integer() | undefined,
    color_temp :: integer() | undefined,
    %% Connect-on-demand: pending command waiting for encryption
    pending_cmd :: term() | undefined,
    pending_from :: term() | undefined,
    %% Cooldown: avoid repeated failed connects
    last_connect_fail :: integer() | undefined  %% system_time(millisecond)
}).

%%====================================================================
%% Public API
%%====================================================================

%% @doc Start the light controller.
%% Addr: 6-byte BLE MAC address of the bulb.
%% Name: registered name for this gen_server.
-spec start_link(binary(), integer(), atom()) -> {ok, pid()} | {error, term()}.
start_link(Addr, AddrType, Name) ->
    gen_server:start_link({local, Name}, ?MODULE, {Addr, AddrType, Name}, []).

-define(CALL_TIMEOUT, 35000).

%% Heartbeat: periodic state read to detect external changes (e.g., physical switch)
-define(HEARTBEAT_INTERVAL_MS, 300000). %% 5 minutes

-spec set_power(atom(), boolean()) -> ok | {error, term()}.
set_power(Name, On) ->
    gen_server:call(Name, {set_power, On}, ?CALL_TIMEOUT).

-spec set_brightness(atom(), 1..254) -> ok | {error, term()}.
set_brightness(Name, Bri) when Bri >= 1, Bri =< 254 ->
    gen_server:call(Name, {set_brightness, Bri}, ?CALL_TIMEOUT).

-spec set_color_temp(atom(), 153..500) -> ok | {error, term()}.
set_color_temp(Name, Temp) when Temp >= 153, Temp =< 500 ->
    gen_server:call(Name, {set_color_temp, Temp}, ?CALL_TIMEOUT).

-spec set_color_xy(atom(), 0..65535, 0..65535) -> ok | {error, term()}.
set_color_xy(Name, X, Y) when X >= 0, X =< 65535, Y >= 0, Y =< 65535 ->
    gen_server:call(Name, {set_color_xy, X, Y}, ?CALL_TIMEOUT).

%% @doc Set multiple properties at once using the combined control characteristic.
%% State is a map with optional keys: power, brightness, color_temp, color_xy.
-spec set_state(atom(), map()) -> ok | {error, term()}.
set_state(Name, State) when is_map(State) ->
    gen_server:call(Name, {set_state, State}, ?CALL_TIMEOUT).

-spec get_state(atom()) -> {ok, map()} | {error, term()}.
get_state(Name) ->
    gen_server:call(Name, get_state, ?CALL_TIMEOUT).

%% @doc Clear the connect cooldown so next command will attempt BLE immediately.
-spec clear_cooldown(atom()) -> ok.
clear_cooldown(Name) ->
    gen_server:call(Name, clear_cooldown).

%% @doc Read the actual bulb state via BLE GATT (connects on-demand).
-spec read_state(atom()) -> {ok, map()} | {error, term()}.
read_state(Name) ->
    gen_server:call(Name, read_state, ?CALL_TIMEOUT).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init({Addr, AddrType, Name}) ->
    %% Subscribe to BLE events (enc_change, disconnected)
    myhome_event_bus:subscribe(self(), fun
        ({ble_enc_change, _, _}) -> true;
        ({ble_disconnected, _, _}) -> true;
        (_) -> false
    end),
    State = #state{
        name = Name,
        addr = Addr,
        addr_type = AddrType,
        conn_handle = undefined,
        connected = false
    },
    %% Connect-on-demand: no connection at startup.
    %% WiFi stays healthy until a command actually needs BLE.
    myhome_log:log(info, "[~p] ready (connect-on-demand)", [Name]),
    %% Schedule first heartbeat (stagger based on atomvm:random to avoid all bulbs reading at once)
    Jitter = (atomvm:random() rem ?HEARTBEAT_INTERVAL_MS) + 60000,
    erlang:send_after(Jitter, self(), heartbeat),
    {ok, State}.

handle_call({set_power, On}, From, State) ->
    Cmd = {write, ?CHR_POWER, case On of true -> <<16#01>>; false -> <<16#00>> end},
    do_cmd(Cmd, From, State);

handle_call({set_brightness, Bri}, From, State) ->
    Cmd = {write, ?CHR_BRIGHTNESS, <<Bri:8>>},
    do_cmd(Cmd, From, State);

handle_call({set_color_temp, Temp}, From, State) ->
    Cmd = {write, ?CHR_COLOR_TEMP, <<Temp:16/little>>},
    do_cmd(Cmd, From, State);

handle_call({set_color_xy, X, Y}, From, State) ->
    Cmd = {write, ?CHR_COLOR_XY, <<X:16/big, Y:16/big>>},
    do_cmd(Cmd, From, State);

handle_call({set_state, Props}, From, State) ->
    Cmd = {write_multi, Props},
    do_cmd(Cmd, From, State);

handle_call(get_state, _From, State) ->
    #state{power = Power, brightness = Bri, color_temp = Temp, connected = Conn} = State,
    Reply = {ok, #{power => Power, brightness => Bri, color_temp => Temp, connected => Conn}},
    {reply, Reply, State};

handle_call(clear_cooldown, _From, State) ->
    {reply, ok, State#state{last_connect_fail = undefined}};

handle_call(read_state, From, State) ->
    do_cmd(read_all, From, State);

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% Encryption established — execute pending command
handle_info({ble_event, {ble_enc_change, ConnHandle, Status}},
            #state{conn_handle = ConnHandle, pending_cmd = Cmd, pending_from = From} = State)
  when Cmd =/= undefined ->
    case Status of
        0 ->
            myhome_log:log(info, "[~p] encrypted, executing: ~s", [State#state.name, cmd_name(Cmd)]),
            {Reply, NewState} = execute_cmd(Cmd, State#state{connected = true}),
            myhome_ble_conn:disconnect(ConnHandle),
            case From of
                undefined -> ok;  %% heartbeat — no caller to reply to
                _ -> gen_server:reply(From, Reply)
            end,
            publish_state(NewState),
            {noreply, NewState#state{pending_cmd = undefined, pending_from = undefined,
                                     conn_handle = undefined, connected = false}};
        _ ->
            myhome_log:log(error, "[~p] security failed (status=~p)", [State#state.name, Status]),
            case From of
                undefined -> ok;
                _ -> gen_server:reply(From, {error, {security_failed, Status}})
            end,
            myhome_ble_conn:disconnect(ConnHandle),
            {noreply, State#state{conn_handle = undefined, connected = false,
                                  pending_cmd = undefined, pending_from = undefined}}
    end;

%% Encryption event but no pending command (e.g., reconnect without command)
handle_info({ble_event, {ble_enc_change, ConnHandle, Status}},
            #state{conn_handle = ConnHandle} = State) ->
    case Status of
        0 ->
            myhome_log:log(info, "[~p] encrypted (no pending cmd), disconnecting", [State#state.name]),
            myhome_ble_conn:disconnect(ConnHandle),
            {noreply, State#state{conn_handle = undefined, connected = false}};
        _ ->
            myhome_ble_conn:disconnect(ConnHandle),
            {noreply, State#state{conn_handle = undefined, connected = false}}
    end;

handle_info({ble_event, {ble_disconnected, ConnHandle, Reason}},
            #state{conn_handle = ConnHandle} = State) ->
    myhome_log:log(info, "[~p] disconnected (reason=~p)", [State#state.name, Reason]),
    %% If there was a pending command, fail it
    NewState = case State#state.pending_from of
        undefined -> State;
        From ->
            gen_server:reply(From, {error, disconnected}),
            State#state{pending_cmd = undefined, pending_from = undefined}
    end,
    {noreply, NewState#state{conn_handle = undefined, connected = false}};

%% Heartbeat: periodic state read to detect external changes
handle_info(heartbeat, #state{pending_cmd = undefined} = State) ->
    erlang:send_after(?HEARTBEAT_INTERVAL_MS, self(), heartbeat),
    case in_connect_cooldown(State) of
        true ->
            %% Bulb unreachable — skip this cycle
            {noreply, State};
        false ->
            %% Initiate a read_state as an internal command (no external caller)
            case connect_with_retry(State#state.addr, State#state.addr_type, 0) of
                {ok, ConnHandle} ->
                    ble:security(ConnHandle),
                    {noreply, State#state{conn_handle = ConnHandle, connected = false,
                                          pending_cmd = read_all, pending_from = undefined}};
                {error, _} ->
                    {noreply, State#state{last_connect_fail = erlang:system_time(millisecond)}}
            end
    end;
handle_info(heartbeat, State) ->
    %% A command is already pending — skip this heartbeat
    erlang:send_after(?HEARTBEAT_INTERVAL_MS, self(), heartbeat),
    {noreply, State};

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, #state{conn_handle = undefined}) ->
    ok;
terminate(_Reason, #state{conn_handle = Handle}) ->
    myhome_ble_conn:disconnect(Handle),
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

%% Execute a command — connect on-demand if needed
do_cmd(Cmd, _From, #state{connected = true, conn_handle = Handle} = State)
  when Handle =/= undefined ->
    %% Already connected and encrypted — execute immediately
    {Reply, NewState} = execute_cmd(Cmd, State),
    myhome_ble_conn:disconnect(Handle),
    {reply, Reply, NewState#state{conn_handle = undefined, connected = false}};
do_cmd(Cmd, From, #state{pending_cmd = undefined} = State) ->
    %% Not connected — check cooldown then connect on-demand
    case in_connect_cooldown(State) of
        true ->
            {reply, {error, connect_cooldown}, State};
        false ->
            do_cmd_connect(Cmd, From, State)
    end;
do_cmd(_Cmd, _From, #state{pending_cmd = _Existing} = State) ->
    %% Already have a pending command (connection in progress)
    {reply, {error, busy}, State}.

do_cmd_connect(Cmd, From, State) ->
    case connect_with_retry(State#state.addr, State#state.addr_type, 1) of
        {ok, ConnHandle} ->
            myhome_log:log(info, "[~p] connected, securing...", [State#state.name]),
            ble:security(ConnHandle),
            %% Wait for enc_change in handle_info before executing
            {noreply, State#state{conn_handle = ConnHandle, connected = false,
                                  pending_cmd = Cmd, pending_from = From,
                                  last_connect_fail = undefined}};
        {error, Reason} ->
            myhome_log:log(warning, "[~p] connect failed: ~p", [State#state.name, Reason]),
            {reply, {error, {connect_failed, Reason}},
             State#state{last_connect_fail = erlang:system_time(millisecond)}}
    end.

%% Execute a GATT write command on an encrypted connection
execute_cmd({write, ChrUUID, Value}, #state{conn_handle = Handle} = State) ->
    Result = ble:gatt_write(Handle, ?SVC_LIGHT, ChrUUID, Value),
    NewState = case Result of
        ok -> update_cached_from_write(ChrUUID, Value, State);
        _  -> State
    end,
    {Result, NewState};
execute_cmd({write_multi, Props}, #state{conn_handle = Handle} = State) ->
    Results = lists:map(fun
        ({power, On}) ->
            Val = case On of true -> <<16#01>>; false -> <<16#00>> end,
            ble:gatt_write(Handle, ?SVC_LIGHT, ?CHR_POWER, Val);
        ({brightness, B}) ->
            ble:gatt_write(Handle, ?SVC_LIGHT, ?CHR_BRIGHTNESS, <<B:8>>);
        ({color_temp, T}) ->
            ble:gatt_write(Handle, ?SVC_LIGHT, ?CHR_COLOR_TEMP, <<T:16/little>>);
        ({color_xy, {X, Y}}) ->
            ble:gatt_write(Handle, ?SVC_LIGHT, ?CHR_COLOR_XY, <<X:16/big, Y:16/big>>);
        (_) -> ok
    end, maps:to_list(Props)),
    Result = case lists:all(fun(R) -> R =:= ok end, Results) of
        true -> ok;
        false -> {error, partial_failure}
    end,
    NewState = case Result of
        ok -> update_cached_state(State, Props);
        _  -> State
    end,
    {Result, NewState};
execute_cmd(read_all, #state{conn_handle = Handle} = State) ->
    Power = case ble:gatt_read(Handle, ?SVC_LIGHT, ?CHR_POWER) of
        {ok, <<P>>} -> P =:= 1;
        _ -> undefined
    end,
    Bri = case ble:gatt_read(Handle, ?SVC_LIGHT, ?CHR_BRIGHTNESS) of
        {ok, <<B>>} -> B;
        _ -> undefined
    end,
    CT = case ble:gatt_read(Handle, ?SVC_LIGHT, ?CHR_COLOR_TEMP) of
        {ok, <<T:16/little>>} -> T;
        _ -> undefined
    end,
    XY = case ble:gatt_read(Handle, ?SVC_LIGHT, ?CHR_COLOR_XY) of
        {ok, <<X:16/big, Y:16/big>>} -> {X, Y};
        _ -> undefined
    end,
    Result = {ok, #{power => Power, brightness => Bri,
                    color_temp => CT, color_xy => XY}},
    NewState = State#state{power = Power, brightness = Bri, color_temp = CT},
    {Result, NewState}.

update_cached_from_write(ChrUUID, Value, State) ->
    case ChrUUID of
        ?CHR_POWER ->
            <<P>> = Value,
            State#state{power = P =:= 1};
        ?CHR_BRIGHTNESS ->
            <<B>> = Value,
            State#state{brightness = B};
        ?CHR_COLOR_TEMP ->
            <<T:16/little>> = Value,
            State#state{color_temp = T};
        _ ->
            State
    end.

update_cached_state(State, Props) ->
    S1 = case maps:find(power, Props) of
        {ok, P} -> State#state{power = P};
        error   -> State
    end,
    S2 = case maps:find(brightness, Props) of
        {ok, B} -> S1#state{brightness = B};
        error   -> S1
    end,
    case maps:find(color_temp, Props) of
        {ok, T} -> S2#state{color_temp = T};
        error   -> S2
    end.

cmd_name({write, ?CHR_POWER, _}) -> "set_power";
cmd_name({write, ?CHR_BRIGHTNESS, _}) -> "set_brightness";
cmd_name({write, ?CHR_COLOR_TEMP, _}) -> "set_color_temp";
cmd_name({write, ?CHR_COLOR_XY, _}) -> "set_color_xy";
cmd_name({write_multi, _}) -> "set_state";
cmd_name(read_all) -> "read_state";
cmd_name(Other) -> io_lib:format("~p", [Other]).

%% Connect with exponential backoff retry.
%% Single retry to limit memory pressure and radio time on ESP32.
connect_with_retry(Addr, AddrType, MaxRetries) ->
    connect_with_retry(Addr, AddrType, MaxRetries, 0, 2000).

connect_with_retry(Addr, AddrType, MaxRetries, Attempt, Delay) ->
    case myhome_ble_conn:connect_sync(Addr, AddrType) of
        {ok, ConnHandle} ->
            {ok, ConnHandle};
        {error, Reason} when Attempt < MaxRetries ->
            myhome_log:log(info, "[ble] connect attempt ~p failed (~p), retry in ~pms",
                           [Attempt + 1, Reason, Delay]),
            timer:sleep(Delay),
            connect_with_retry(Addr, AddrType, MaxRetries, Attempt + 1, Delay * 2);
        {error, Reason} ->
            {error, Reason}
    end.

%% 60s cooldown after a failed connect to avoid memory exhaustion from retries
-define(CONNECT_COOLDOWN_MS, 60000).

in_connect_cooldown(#state{last_connect_fail = undefined}) -> false;
in_connect_cooldown(#state{last_connect_fail = LastFail}) ->
    (erlang:system_time(millisecond) - LastFail) < ?CONNECT_COOLDOWN_MS.

%% Publish bulb state to event_bus so long-poll clients get updates
publish_state(#state{name = Name, power = Power, brightness = Bri, color_temp = CT}) ->
    myhome_event_bus:publish({bulb_state, Name,
        #{power => Power, brightness => Bri, color_temp => CT}}).

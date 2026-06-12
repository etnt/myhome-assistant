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
-export([clear_cooldown/1, unpair/1]).

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
    connected :: boolean(),       %% true once the link is encrypted & ready
    %% GATT handle cache: UUID binary → ATT value handle (discovered once)
    gatt_handles :: #{binary() => non_neg_integer()} | undefined,
    %% Cached light state
    power     :: boolean() | undefined,
    brightness :: integer() | undefined,
    color_temp :: integer() | undefined
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

%% @doc Delete the BLE bond for this bulb on the nRF (clears the stored LTK).
%% Disconnects any active link and clears the cooldown so a fresh pairing
%% can be established on the next command (after factory-resetting the bulb).
-spec unpair(atom()) -> ok | {error, term()}.
unpair(Name) ->
    gen_server:call(Name, unpair, ?CALL_TIMEOUT).

%% @doc Read the actual bulb state via BLE GATT (connects on-demand).
-spec read_state(atom()) -> {ok, map()} | {error, term()}.
read_state(Name) ->
    gen_server:call(Name, read_state, ?CALL_TIMEOUT).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init({Addr, AddrType, Name}) ->
    %% Subscribe to BLE events. The nRF keeps bonded bulbs permanently
    %% connected (persistent auto-connect), so we react to the connection
    %% lifecycle rather than connecting on demand.
    myhome_event_bus:subscribe(self(), fun
        ({ble_connected, _, _}) -> true;
        ({ble_enc_change, _, _}) -> true;
        ({ble_disconnected, _, _}) -> true;
        (_) -> false
    end),
    State = #state{
        name = Name,
        addr = Addr,
        addr_type = AddrType,
        conn_handle = undefined,
        connected = false,
        gatt_handles = undefined
    },
    myhome_log:log(info, "[~p] ready (persistent connection managed by nRF)", [Name]),
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
    %% No cooldown in the persistent model; the nRF auto-reconnects on its own.
    %% Kept for HTTP API compatibility (/reconnect endpoints).
    {reply, ok, State};

handle_call(unpair, _From, #state{addr = Addr, addr_type = AddrType,
                                  conn_handle = ConnHandle, name = Name} = State) ->
    %% Drop any active connection before clearing the bond
    case ConnHandle of
        undefined -> ok;
        _ -> catch myhome_ble_i2c:disconnect(ConnHandle)
    end,
    Result = myhome_ble_i2c:delete_bond(Addr, AddrType),
    myhome_log:log(info, "[~p] unpair: ~p", [Name, Result]),
    {reply, Result, State#state{conn_handle = undefined, connected = false,
                                gatt_handles = undefined}};

handle_call(read_state, From, State) ->
    do_cmd(read_all, From, State);

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% nRF established a connection to this bulb (persistent auto-connect or a
%% manual pairing connect). Match by address; record the handle and wait for
%% the link to be encrypted before marking it ready.
handle_info({ble_event, {ble_connected, Handle, Addr}},
            #state{addr = Addr} = State) ->
    myhome_log:log(info, "[~p] connected [~p], awaiting encryption",
                   [State#state.name, Handle]),
    {noreply, State#state{conn_handle = Handle, connected = false}};

%% Link encrypted — bulb is ready. Discover GATT handles once (cached across
%% reconnects), refresh cached state, and publish.
handle_info({ble_event, {ble_enc_change, Handle, 0}},
            #state{conn_handle = Handle} = State) ->
    myhome_log:log(info, "[~p] encrypted, ready", [State#state.name]),
    State1 = State#state{connected = true},
    State2 = case ensure_gatt_handles(State1) of
        {ok, S} ->
            {_, S3} = execute_cmd(read_all, S),
            S3;
        {error, _} ->
            State1
    end,
    publish_state(State2),
    {noreply, State2};

%% Encryption failed — leave the bulb marked down; the nRF will retry.
handle_info({ble_event, {ble_enc_change, Handle, Status}},
            #state{conn_handle = Handle} = State) ->
    myhome_log:log(warning, "[~p] encryption failed (status=~p)",
                   [State#state.name, Status]),
    {noreply, State#state{connected = false}};

%% Bulb disconnected. The nRF auto-reconnects when it advertises again, so we
%% just mark it down — no reconnect initiated from here. GATT handles are kept
%% cached (the Hue GATT layout is stable across reconnects).
handle_info({ble_event, {ble_disconnected, Handle, Reason}},
            #state{conn_handle = Handle} = State) ->
    myhome_log:log(info, "[~p] disconnected (reason=~p), nRF will auto-reconnect",
                   [State#state.name, Reason]),
    {noreply, State#state{conn_handle = undefined, connected = false}};

%% Heartbeat: refresh cached state while connected to detect external changes
%% (e.g., the physical wall switch). Skipped when disconnected.
handle_info(heartbeat, State) ->
    erlang:send_after(?HEARTBEAT_INTERVAL_MS, self(), heartbeat),
    case State#state.connected of
        true ->
            {_, NewState} = execute_cmd(read_all, State),
            publish_state(NewState),
            {noreply, NewState};
        false ->
            {noreply, State}
    end;

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, #state{conn_handle = undefined}) ->
    ok;
terminate(_Reason, #state{conn_handle = Handle}) ->
    myhome_ble_i2c:disconnect(Handle),
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

%% Execute a command on the persistent connection. The nRF keeps bonded bulbs
%% connected, so a command either runs immediately or fails fast when the bulb
%% is currently down (it will reconnect on its own in the background).
do_cmd(Cmd, _From, #state{connected = true, conn_handle = Handle} = State)
  when Handle =/= undefined ->
    {Reply, NewState} = execute_cmd(Cmd, State),
    publish_state(NewState),
    {reply, Reply, NewState};
do_cmd(_Cmd, _From, State) ->
    {reply, {error, not_connected}, State}.

%% Execute a GATT write command on an encrypted connection
execute_cmd({write, ChrUUID, Value}, #state{conn_handle = Handle} = State) ->
    case resolve_handle(ChrUUID, State) of
        {ok, AttrH, State1} ->
            Result = myhome_ble_i2c:gatt_write(Handle, AttrH, Value),
            NewState = case Result of
                ok -> update_cached_from_write(ChrUUID, Value, State1);
                _  -> State1
            end,
            {Result, NewState};
        {error, _} = Err ->
            {Err, State}
    end;
execute_cmd({write_multi, Props}, #state{conn_handle = Handle} = State) ->
    case ensure_gatt_handles(State) of
        {ok, State1} ->
            Results = lists:map(fun
                ({power, On}) ->
                    Val = case On of true -> <<16#01>>; false -> <<16#00>> end,
                    write_by_uuid(?CHR_POWER, Val, Handle, State1);
                ({brightness, B}) ->
                    write_by_uuid(?CHR_BRIGHTNESS, <<B:8>>, Handle, State1);
                ({color_temp, T}) ->
                    write_by_uuid(?CHR_COLOR_TEMP, <<T:16/little>>, Handle, State1);
                ({color_xy, {X, Y}}) ->
                    write_by_uuid(?CHR_COLOR_XY, <<X:16/big, Y:16/big>>, Handle, State1);
                (_) -> ok
            end, maps:to_list(Props)),
            Result = case lists:all(fun(R) -> R =:= ok end, Results) of
                true -> ok;
                false -> {error, partial_failure}
            end,
            NewState = case Result of
                ok -> update_cached_state(State1, Props);
                _  -> State1
            end,
            {Result, NewState};
        {error, _} = Err ->
            {Err, State}
    end;
execute_cmd(read_all, #state{conn_handle = Handle} = State) ->
    case ensure_gatt_handles(State) of
        {ok, State1} ->
            Power = case read_by_uuid(?CHR_POWER, Handle, State1) of
                {ok, <<P>>} -> P =:= 1;
                _ -> undefined
            end,
            Bri = case read_by_uuid(?CHR_BRIGHTNESS, Handle, State1) of
                {ok, <<B>>} -> B;
                _ -> undefined
            end,
            CT = case read_by_uuid(?CHR_COLOR_TEMP, Handle, State1) of
                {ok, <<T:16/little>>} -> T;
                _ -> undefined
            end,
            XY = case read_by_uuid(?CHR_COLOR_XY, Handle, State1) of
                {ok, <<X:16/big, Y:16/big>>} -> {X, Y};
                _ -> undefined
            end,
            Result = {ok, #{power => Power, brightness => Bri,
                            color_temp => CT, color_xy => XY}},
            NewState = State1#state{power = Power, brightness = Bri, color_temp = CT},
            {Result, NewState};
        {error, _} = Err ->
            {Err, State}
    end.

%% Resolve a characteristic UUID to its ATT handle, discovering if needed
resolve_handle(ChrUUID, State) ->
    case ensure_gatt_handles(State) of
        {ok, #state{gatt_handles = Handles} = State1} ->
            case maps:get(ChrUUID, Handles, undefined) of
                undefined -> {error, {uuid_not_found, ChrUUID}};
                AttrH -> {ok, AttrH, State1}
            end;
        {error, _} = Err ->
            Err
    end.

%% Ensure GATT handles are cached; discover if not
ensure_gatt_handles(#state{gatt_handles = Handles} = State) when is_map(Handles) ->
    {ok, State};
ensure_gatt_handles(#state{conn_handle = ConnH} = State) ->
    case myhome_ble_i2c:gatt_discover(ConnH) of
        {ok, Chars} ->
            Handles = lists:foldl(fun(#{uuid := Uuid, handle := H}, Acc) ->
                maps:put(Uuid, H, Acc)
            end, #{}, Chars),
            myhome_log:log(info, "[~p] discovered ~p GATT characteristics",
                           [State#state.name, map_size(Handles)]),
            {ok, State#state{gatt_handles = Handles}};
        {error, _} = Err ->
            myhome_log:log(error, "[~p] GATT discovery failed: ~p",
                           [State#state.name, Err]),
            Err
    end.

%% Write a characteristic by UUID (resolves from cache)
write_by_uuid(ChrUUID, Value, ConnH, #state{gatt_handles = Handles}) ->
    case maps:get(ChrUUID, Handles, undefined) of
        undefined -> {error, {uuid_not_found, ChrUUID}};
        AttrH -> myhome_ble_i2c:gatt_write(ConnH, AttrH, Value)
    end.

%% Read a characteristic by UUID (resolves from cache)
read_by_uuid(ChrUUID, ConnH, #state{gatt_handles = Handles}) ->
    case maps:get(ChrUUID, Handles, undefined) of
        undefined -> {error, {uuid_not_found, ChrUUID}};
        AttrH -> myhome_ble_i2c:gatt_read(ConnH, AttrH)
    end.

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

%% Publish bulb state to event_bus so long-poll clients get updates
publish_state(#state{name = Name, power = Power, brightness = Bri, color_temp = CT}) ->
    myhome_event_bus:publish({bulb_state, Name,
        #{power => Power, brightness => Bri, color_temp => CT}}).

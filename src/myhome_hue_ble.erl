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
    %% GATT handle cache: UUID binary → ATT value handle
    gatt_handles :: #{binary() => non_neg_integer()} | undefined,
    %% Cached light state
    power     :: boolean() | undefined,
    brightness :: integer() | undefined,
    color_temp :: integer() | undefined,
    %% Connect-on-demand: pending command waiting for encryption
    pending_cmd :: term() | undefined,
    pending_from :: term() | undefined,
    pending_ref :: reference() | undefined,  %% watchdog ref for pending_cmd
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

%% Watchdog: if a pending command isn't resolved by an enc_change/disconnect
%% event within this window, reset the connection state so the bulb doesn't
%% get stuck replying {error, busy} forever. Must be < ?CALL_TIMEOUT so a
%% waiting caller gets a clean {error, timeout} reply.
-define(PENDING_TIMEOUT_MS, 30000).

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
        connected = false,
        gatt_handles = undefined
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
            myhome_ble_i2c:disconnect(ConnHandle),
            case From of
                undefined -> ok;  %% heartbeat — no caller to reply to
                _ -> gen_server:reply(From, Reply)
            end,
            publish_state(NewState),
            {noreply, NewState#state{pending_cmd = undefined, pending_from = undefined,
                                     pending_ref = undefined,
                                     conn_handle = undefined, connected = false}};
        _ ->
            myhome_log:log(error, "[~p] security failed (status=~p)", [State#state.name, Status]),
            case From of
                undefined -> ok;
                _ -> gen_server:reply(From, {error, {security_failed, Status}})
            end,
            myhome_ble_i2c:disconnect(ConnHandle),
            {noreply, State#state{conn_handle = undefined, connected = false,
                                  pending_cmd = undefined, pending_from = undefined,
                                  pending_ref = undefined}}
    end;

%% Encryption event but no pending command (e.g., reconnect without command)
handle_info({ble_event, {ble_enc_change, ConnHandle, Status}},
            #state{conn_handle = ConnHandle} = State) ->
    case Status of
        0 ->
            myhome_log:log(info, "[~p] encrypted (no pending cmd), disconnecting", [State#state.name]),
            myhome_ble_i2c:disconnect(ConnHandle),
            {noreply, State#state{conn_handle = undefined, connected = false}};
        _ ->
            myhome_ble_i2c:disconnect(ConnHandle),
            {noreply, State#state{conn_handle = undefined, connected = false}}
    end;

handle_info({ble_event, {ble_disconnected, ConnHandle, Reason}},
            #state{conn_handle = ConnHandle} = State) ->
    myhome_log:log(info, "[~p] disconnected (reason=~p)", [State#state.name, Reason]),
    %% Fail any pending command — whether from an external caller or a
    %% heartbeat (pending_from = undefined). Always clear pending state so
    %% the bulb doesn't get stuck replying {error, busy}.
    case State#state.pending_from of
        undefined -> ok;
        From -> gen_server:reply(From, {error, disconnected})
    end,
    {noreply, State#state{conn_handle = undefined, connected = false,
                          pending_cmd = undefined, pending_from = undefined,
                          pending_ref = undefined}};

%% Heartbeat: periodic state read to detect external changes
handle_info(heartbeat, #state{pending_cmd = undefined} = State) ->
    erlang:send_after(?HEARTBEAT_INTERVAL_MS, self(), heartbeat),
    case in_connect_cooldown(State) of
        true ->
            %% Bulb unreachable — skip this cycle
            {noreply, State};
        false ->
            %% Initiate a read_state as an internal command (no external caller)
            case myhome_ble_i2c:connect(State#state.addr, State#state.addr_type) of
                {ok, ConnHandle} ->
                    %% Must explicitly request bond/encryption
                    spawn(fun() -> myhome_ble_i2c:bond(ConnHandle) end),
                    Ref = schedule_pending_timeout(),
                    {noreply, State#state{conn_handle = ConnHandle, connected = false,
                                          pending_cmd = read_all, pending_from = undefined,
                                          pending_ref = Ref}};
                {error, _} ->
                    {noreply, State#state{last_connect_fail = erlang:system_time(millisecond)}}
            end
    end;
handle_info(heartbeat, State) ->
    %% A command is already pending — skip this heartbeat
    erlang:send_after(?HEARTBEAT_INTERVAL_MS, self(), heartbeat),
    {noreply, State};

%% Watchdog fired for the current pending command — the expected enc_change /
%% disconnect event never arrived. Reset connection state so we recover.
handle_info({pending_timeout, Ref},
            #state{pending_ref = Ref, pending_cmd = Cmd} = State)
  when Cmd =/= undefined ->
    myhome_log:log(warning, "[~p] pending command ~s timed out — resetting",
                   [State#state.name, cmd_name(Cmd)]),
    case State#state.pending_from of
        undefined -> ok;
        From -> gen_server:reply(From, {error, timeout})
    end,
    case State#state.conn_handle of
        undefined -> ok;
        H -> myhome_ble_i2c:disconnect(H)
    end,
    {noreply, State#state{pending_cmd = undefined, pending_from = undefined,
                          pending_ref = undefined, conn_handle = undefined,
                          connected = false}};
%% Stale watchdog (command already resolved) — ignore.
handle_info({pending_timeout, _Stale}, State) ->
    {noreply, State};

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

%% Arm the pending-command watchdog. Returns a unique ref that is matched
%% against the {pending_timeout, Ref} message so stale timers are ignored.
schedule_pending_timeout() ->
    Ref = make_ref(),
    erlang:send_after(?PENDING_TIMEOUT_MS, self(), {pending_timeout, Ref}),
    Ref.

%% Execute a command — connect on-demand if needed
do_cmd(Cmd, _From, #state{connected = true, conn_handle = Handle} = State)
  when Handle =/= undefined ->
    %% Already connected and encrypted — execute immediately
    {Reply, NewState} = execute_cmd(Cmd, State),
    myhome_ble_i2c:disconnect(Handle),
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
    case myhome_ble_i2c:connect(State#state.addr, State#state.addr_type) of
        {ok, ConnHandle} ->
            myhome_log:log(info, "[~p] connected [~p], initiating bond/encryption...",
                           [State#state.name, ConnHandle]),
            %% Must explicitly request bond — XIAO doesn't auto-negotiate encryption.
            %% For already-bonded devices this just re-encrypts the link.
            %% bond() is async (waits via bond_waiters), but we also get enc_change
            %% via the event bus which triggers execute_cmd in handle_info.
            spawn(fun() -> myhome_ble_i2c:bond(ConnHandle) end),
            Ref = schedule_pending_timeout(),
            {noreply, State#state{conn_handle = ConnHandle, connected = false,
                                  pending_cmd = Cmd, pending_from = From,
                                  pending_ref = Ref,
                                  last_connect_fail = undefined}};
        {error, Reason} ->
            myhome_log:log(warning, "[~p] connect failed: ~p", [State#state.name, Reason]),
            {reply, {error, {connect_failed, Reason}},
             State#state{last_connect_fail = erlang:system_time(millisecond)}}
    end.

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

cmd_name({write, ?CHR_POWER, _}) -> "set_power";
cmd_name({write, ?CHR_BRIGHTNESS, _}) -> "set_brightness";
cmd_name({write, ?CHR_COLOR_TEMP, _}) -> "set_color_temp";
cmd_name({write, ?CHR_COLOR_XY, _}) -> "set_color_xy";
cmd_name({write_multi, _}) -> "set_state";
cmd_name(read_all) -> "read_state";
cmd_name(Other) -> io_lib:format("~p", [Other]).

%% 60s cooldown after a failed connect to avoid memory exhaustion from retries
-define(CONNECT_COOLDOWN_MS, 60000).

in_connect_cooldown(#state{last_connect_fail = undefined}) -> false;
in_connect_cooldown(#state{last_connect_fail = LastFail}) ->
    (erlang:system_time(millisecond) - LastFail) < ?CONNECT_COOLDOWN_MS.

%% Publish bulb state to event_bus so long-poll clients get updates
publish_state(#state{name = Name, power = Power, brightness = Bri, color_temp = CT}) ->
    myhome_event_bus:publish({bulb_state, Name,
        #{power => Power, brightness => Bri, color_temp => CT}}).

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
-export([set_color_xy/3, set_state/2, get_state/1]).

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
    %% Reconnect
    reconnect_timer :: reference() | undefined,
    connect_retries = 0 :: non_neg_integer()
}).

-define(RECONNECT_DELAY, 10000).
-define(MAX_CONNECT_RETRIES, 3).

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

%%====================================================================
%% gen_server callbacks
%%====================================================================

init({Addr, AddrType, Name}) ->
    State = #state{
        name = Name,
        addr = Addr,
        addr_type = AddrType,
        conn_handle = undefined,
        connected = false
    },
    %% Stagger connection attempts to avoid NimBLE EALREADY errors
    Delay = case Name of
        bulb_1 -> 100;
        bulb_2 -> 3000;
        bulb_3 -> 6000;
        _      -> 9000
    end,
    erlang:send_after(Delay, self(), connect),
    {ok, State}.

handle_call({set_power, _On}, _From, #state{connected = false} = State) ->
    {reply, {error, not_connected}, State};
handle_call({set_power, On}, _From, #state{conn_handle = Handle} = State) ->
    Value = case On of true -> <<16#01>>; false -> <<16#00>> end,
    Result = ble:gatt_write(Handle, ?SVC_LIGHT, ?CHR_POWER, Value),
    NewState = case Result of
        ok -> State#state{power = On};
        _  -> State
    end,
    {reply, Result, NewState};

handle_call({set_brightness, _Bri}, _From, #state{connected = false} = State) ->
    {reply, {error, not_connected}, State};
handle_call({set_brightness, Bri}, _From, #state{conn_handle = Handle} = State) ->
    Result = ble:gatt_write(Handle, ?SVC_LIGHT, ?CHR_BRIGHTNESS, <<Bri:8>>),
    NewState = case Result of
        ok -> State#state{brightness = Bri};
        _  -> State
    end,
    {reply, Result, NewState};

handle_call({set_color_temp, _Temp}, _From, #state{connected = false} = State) ->
    {reply, {error, not_connected}, State};
handle_call({set_color_temp, Temp}, _From, #state{conn_handle = Handle} = State) ->
    Result = ble:gatt_write(Handle, ?SVC_LIGHT, ?CHR_COLOR_TEMP, <<Temp:16/little>>),
    NewState = case Result of
        ok -> State#state{color_temp = Temp};
        _  -> State
    end,
    {reply, Result, NewState};

handle_call({set_color_xy, _X, _Y}, _From, #state{connected = false} = State) ->
    {reply, {error, not_connected}, State};
handle_call({set_color_xy, X, Y}, _From, #state{conn_handle = Handle} = State) ->
    Result = ble:gatt_write(Handle, ?SVC_LIGHT, ?CHR_COLOR_XY, <<X:16/big, Y:16/big>>),
    {reply, Result, State};

handle_call({set_state, _Props}, _From, #state{connected = false} = State) ->
    {reply, {error, not_connected}, State};
handle_call({set_state, Props}, _From, #state{conn_handle = Handle} = State) ->
    %% Write each property to its individual characteristic
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
    {reply, Result, NewState};

handle_call(get_state, _From, #state{connected = false} = State) ->
    {reply, {error, not_connected}, State};
handle_call(get_state, _From, State) ->
    #state{power = Power, brightness = Bri, color_temp = Temp, connected = Conn} = State,
    Reply = {ok, #{power => Power, brightness => Bri, color_temp => Temp, connected => Conn}},
    {reply, Reply, State};

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(connect, #state{connect_retries = N} = State) when N >= ?MAX_CONNECT_RETRIES ->
    myhome_log:log(warning, "[~p] giving up after ~p connect attempts",
              [State#state.name, N]),
    {noreply, State};
handle_info(connect, State) ->
    case do_connect(State) of
        {ok, NewState} ->
            myhome_log:log(info, "[~p] connected to ~s", [State#state.name, format_addr(State#state.addr)]),
            {noreply, NewState#state{connect_retries = 0}};
        {error, _Reason} ->
            Retries = State#state.connect_retries + 1,
            myhome_log:log(warning, "[~p] connect failed (~p/~p), retrying in ~pms",
                      [State#state.name, Retries, ?MAX_CONNECT_RETRIES, ?RECONNECT_DELAY]),
            Ref = erlang:send_after(?RECONNECT_DELAY, self(), connect),
            {noreply, State#state{reconnect_timer = Ref, connect_retries = Retries}}
    end;

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

do_connect(#state{addr = Addr, addr_type = AddrType} = State) ->
    case myhome_ble_conn:connect_sync(Addr, AddrType) of
        {ok, ConnHandle} ->
            {ok, State#state{conn_handle = ConnHandle, connected = true,
                             reconnect_timer = undefined}};
        {error, Reason} ->
            {error, Reason}
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

format_addr(<<A, B, C, D, E, F>>) ->
    io_lib:format("~2.16.0B:~2.16.0B:~2.16.0B:~2.16.0B:~2.16.0B:~2.16.0B",
                  [F, E, D, C, B, A]).

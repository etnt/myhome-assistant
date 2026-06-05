%%%-------------------------------------------------------------------
%%% @doc BLE connection manager.
%%% Tracks connection state for BLE devices. Receives async events
%%% from the BLE port driver ({ble_connected, ...}, {ble_disconnected, ...},
%%% {ble_enc_change, ...}) and maintains a map of active connections.
%%%
%%% Connections are initiated via the HTTP API (POST /api/connect).
%%% @end
%%%-------------------------------------------------------------------
-module(myhome_ble_conn).
-behaviour(gen_server).

-export([start_link/0]).
-export([connect/2, disconnect/1, security/1, get_connections/0]).
-export([connect_sync/2, connect_sync/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(conn, {
    addr :: binary(),
    addr_type :: 0..3,
    handle :: non_neg_integer() | undefined,
    state :: connecting | connected | securing | bonded | disconnecting,
    since :: integer()  %% erlang:system_time(millisecond)
}).

-record(state, {
    %% Key: connection handle (integer) or {pending, Addr} for connecting
    conns = #{} :: #{term() => #conn{}},
    %% Callers waiting for connect result: [{Addr, From, TimerRef}]
    connect_waiters = [] :: [{binary(), gen_server:from(), reference()}]
}).

%%====================================================================
%% Public API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Initiate connection to a device. Non-blocking.
-spec connect(binary(), 0..3) -> ok | {error, term()}.
connect(Addr, AddrType) when byte_size(Addr) =:= 6 ->
    gen_server:call(?MODULE, {connect, Addr, AddrType}).

%% @doc Connect and wait for the connection event. Returns handle on success.
-spec connect_sync(binary(), 0..3) -> {ok, non_neg_integer()} | {error, term()}.
connect_sync(Addr, AddrType) ->
    connect_sync(Addr, AddrType, 18000).

-spec connect_sync(binary(), 0..3, pos_integer()) -> {ok, non_neg_integer()} | {error, term()}.
connect_sync(Addr, AddrType, Timeout) when byte_size(Addr) =:= 6 ->
    gen_server:call(?MODULE, {connect_sync, Addr, AddrType, Timeout}, Timeout + 5000).

%% @doc Disconnect by connection handle.
-spec disconnect(non_neg_integer()) -> ok | {error, term()}.
disconnect(ConnHandle) ->
    gen_server:call(?MODULE, {disconnect, ConnHandle}).

%% @doc Initiate security on a connection handle.
-spec security(non_neg_integer()) -> ok | {error, term()}.
security(ConnHandle) ->
    gen_server:call(?MODULE, {security, ConnHandle}).

%% @doc Get all active connections.
-spec get_connections() -> {ok, [map()]}.
get_connections() ->
    gen_server:call(?MODULE, get_connections).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    %% Subscribe to connection events from the event bus
    Filter = fun
        ({ble_connected, _, _}) -> true;
        ({ble_disconnected, _, _}) -> true;
        ({ble_enc_change, _, _}) -> true;
        (_) -> false
    end,
    myhome_event_bus:subscribe(self(), Filter),
    {ok, #state{}}.

handle_call({connect, Addr, AddrType}, _From, #state{conns = Conns} = State) ->
    case ble:connect(Addr, AddrType) of
        ok ->
            Conn = #conn{
                addr = Addr,
                addr_type = AddrType,
                handle = undefined,
                state = connecting,
                since = erlang:system_time(millisecond)
            },
            NewConns = Conns#{{pending, Addr} => Conn},
            {reply, ok, State#state{conns = NewConns}};
        {error, _} = Err ->
            {reply, Err, State}
    end;

handle_call({connect_sync, Addr, AddrType, Timeout}, From, #state{conns = Conns, connect_waiters = Waiters} = State) ->
    case ble:connect(Addr, AddrType) of
        ok ->
            Conn = #conn{
                addr = Addr,
                addr_type = AddrType,
                handle = undefined,
                state = connecting,
                since = erlang:system_time(millisecond)
            },
            NewConns = Conns#{{pending, Addr} => Conn},
            TRef = erlang:send_after(Timeout, self(), {connect_timeout, Addr}),
            NewWaiters = [{Addr, From, TRef} | Waiters],
            {noreply, State#state{conns = NewConns, connect_waiters = NewWaiters}};
        {error, _} = Err ->
            {reply, Err, State}
    end;

handle_call({disconnect, ConnHandle}, _From, #state{conns = Conns} = State) ->
    case maps:find(ConnHandle, Conns) of
        {ok, Conn} ->
            case ble:disconnect(ConnHandle) of
                ok ->
                    NewConns = Conns#{ConnHandle => Conn#conn{state = disconnecting}},
                    {reply, ok, State#state{conns = NewConns}};
                {error, _} = Err ->
                    {reply, Err, State}
            end;
        error ->
            %% Try disconnect anyway (device might be connected but not tracked)
            Reply = ble:disconnect(ConnHandle),
            {reply, Reply, State}
    end;

handle_call({security, ConnHandle}, _From, #state{conns = Conns} = State) ->
    case ble:security(ConnHandle) of
        ok ->
            NewConns = case maps:find(ConnHandle, Conns) of
                {ok, Conn} -> Conns#{ConnHandle => Conn#conn{state = securing}};
                error -> Conns
            end,
            {reply, ok, State#state{conns = NewConns}};
        {error, _} = Err ->
            {reply, Err, State}
    end;

handle_call(get_connections, _From, #state{conns = Conns} = State) ->
    List = maps:fold(fun(_Key, #conn{addr = Addr, handle = H, state = S, since = Since}, Acc) ->
        [#{addr => Addr, handle => H, state => S, since => Since} | Acc]
    end, [], Conns),
    {reply, {ok, List}, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% Unwrap events from the event bus
handle_info({ble_event, Event}, State) ->
    handle_info(Event, State);

%% BLE connected event from port driver
handle_info({ble_connected, ConnHandle, 0 = _Status}, #state{conns = Conns, connect_waiters = Waiters} = State) ->
    %% Find the pending connection by scanning all pending entries
    {NewConns, Addr} = maps:fold(fun
        ({pending, A} = Key, #conn{state = connecting} = Conn, {Acc, undefined}) ->
            %% Promote pending to active with handle as key
            Acc2 = maps:remove(Key, Acc),
            Acc3 = Acc2#{ConnHandle => Conn#conn{handle = ConnHandle, state = connected}},
            {Acc3, A};
        (_K, _V, {Acc, Found}) ->
            {Acc, Found}
    end, {Conns, undefined}, Conns),
    %% Register handle→addr mapping for address-based GATT cache
    case Addr of
        undefined -> ok;
        _ -> ble:register_conn(ConnHandle, Addr)
    end,
    %% Reply to any sync waiter for this address
    NewWaiters = case Addr of
        undefined -> Waiters;
        _ -> reply_to_waiter(Addr, {ok, ConnHandle}, Waiters)
    end,
    io:format("BLE connected: handle=~p~n", [ConnHandle]),
    {noreply, State#state{conns = NewConns, connect_waiters = NewWaiters}};

%% BLE connected with error
handle_info({ble_connected, _ConnHandle, Status}, #state{conns = Conns, connect_waiters = Waiters} = State) ->
    io:format("BLE connect failed: status=~p~n", [Status]),
    %% Remove any pending connections and reply to waiters
    {NewConns, RemovedAddrs} = maps:fold(fun
        ({pending, A} = Key, #conn{state = connecting}, {Acc, Addrs}) ->
            {maps:remove(Key, Acc), [A | Addrs]};
        (_K, _V, {Acc, Addrs}) ->
            {Acc, Addrs}
    end, {Conns, []}, Conns),
    NewWaiters = lists:foldl(fun(A, W) ->
        reply_to_waiter(A, {error, {connect_failed, Status}}, W)
    end, Waiters, RemovedAddrs),
    {noreply, State#state{conns = NewConns, connect_waiters = NewWaiters}};

%% BLE disconnected event
handle_info({ble_disconnected, ConnHandle, Reason}, #state{conns = Conns} = State) ->
    io:format("BLE disconnected: handle=~p reason=~p~n", [ConnHandle, Reason]),
    NewConns = maps:remove(ConnHandle, Conns),
    {noreply, State#state{conns = NewConns}};

%% BLE encryption change event
handle_info({ble_enc_change, ConnHandle, 0 = _Status}, #state{conns = Conns} = State) ->
    io:format("BLE bonded: handle=~p~n", [ConnHandle]),
    NewConns = case maps:find(ConnHandle, Conns) of
        {ok, Conn} -> Conns#{ConnHandle => Conn#conn{state = bonded}};
        error -> Conns
    end,
    {noreply, State#state{conns = NewConns}};

handle_info({ble_enc_change, ConnHandle, Status}, State) ->
    io:format("BLE security failed: handle=~p status=~p~n", [ConnHandle, Status]),
    {noreply, State};

handle_info({connect_timeout, Addr}, #state{conns = Conns, connect_waiters = Waiters} = State) ->
    %% Cancel the BLE GAP connect procedure to free the radio
    ble:connect_cancel(),
    NewConns = maps:remove({pending, Addr}, Conns),
    NewWaiters = reply_to_waiter(Addr, {error, connect_timeout}, Waiters),
    {noreply, State#state{conns = NewConns, connect_waiters = NewWaiters}};

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal
%%====================================================================

reply_to_waiter(Addr, Reply, Waiters) ->
    case lists:keytake(Addr, 1, Waiters) of
        {value, {Addr, From, TRef}, Rest} ->
            erlang:cancel_timer(TRef),
            gen_server:reply(From, Reply),
            Rest;
        false ->
            Waiters
    end.

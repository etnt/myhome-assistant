%%%-------------------------------------------------------------------
%%% @doc BLE port server.
%%% Owns the native BLE port, serializes all commands, and publishes
%%% async events (scan, connect, disconnect, encryption) to the event bus.
%%%
%%% Phase 4: GATT read/write are non-blocking. The port returns ok
%%% immediately, and results arrive as async messages. This module
%%% correlates results to waiting callers via a pending ops map.
%%% @end
%%%-------------------------------------------------------------------
-module(ble).
-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([scan_start/0, scan_start/1, scan_stop/0]).
-export([connect/2, connect_cancel/0, disconnect/1, security/1, update_conn_params/1]).
-export([gatt_read/3, gatt_write/4, gatt_write_nr/4]).
-export([discover_services/1]).
-export([register_conn/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% Opcodes (must match ble_port.c)
-define(OP_INIT,         16#01).
-define(OP_SCAN_START,   16#10).
-define(OP_SCAN_STOP,    16#11).
-define(OP_SUBSCRIBE_SCAN, 16#13).
-define(OP_CONNECT,      16#20).
-define(OP_DISCONNECT,   16#21).
-define(OP_SECURITY,     16#22).
-define(OP_UPDATE_PARAMS,16#23).
-define(OP_CONNECT_CANCEL, 16#24).
-define(OP_GATT_READ,    16#30).
-define(OP_GATT_WRITE,   16#31).
-define(OP_GATT_WRITE_NR,16#32).
-define(OP_DISC_SVCS,    16#34).

%% Response status
-define(RSP_OK,  16#00).
-define(RSP_ERR, 16#01).

-record(state, {
    port :: port(),
    %% Pending async GATT ops: ConnHandle -> {From, OpType, TRef}
    pending :: #{non_neg_integer() => {gen_server:from(), atom(), reference()}},
    %% ConnHandle -> Addr mapping (set via register_conn/2)
    conn_addrs :: #{non_neg_integer() => binary()},
    %% Characteristic handle cache keyed by BLE address (stable across reconnects)
    chr_cache :: #{binary() => #{binary() => non_neg_integer()}}
}).

-define(GATT_TIMEOUT, 15000).

%%====================================================================
%% API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% Scanning
%%--------------------------------------------------------------------

-spec scan_start() -> ok | {error, term()}.
scan_start() ->
    scan_start(10).

-spec scan_start(Duration :: 1..255) -> ok | {error, term()}.
scan_start(Duration) ->
    gen_server:call(?MODULE, {scan_start, Duration}, 35000).

-spec scan_stop() -> ok | {error, term()}.
scan_stop() ->
    gen_server:call(?MODULE, scan_stop, 5000).

%%--------------------------------------------------------------------
%% Connection
%%--------------------------------------------------------------------

-spec connect(Addr :: binary(), AddrType :: 0..3) -> ok | {error, term()}.
connect(Addr, AddrType) when byte_size(Addr) =:= 6 ->
    gen_server:call(?MODULE, {connect, Addr, AddrType}, 5000).

-spec connect_cancel() -> ok | {error, term()}.
connect_cancel() ->
    gen_server:call(?MODULE, connect_cancel, 5000).

-spec disconnect(ConnHandle :: non_neg_integer()) -> ok | {error, term()}.
disconnect(ConnHandle) ->
    gen_server:call(?MODULE, {disconnect, ConnHandle}, 5000).

-spec security(ConnHandle :: non_neg_integer()) -> ok | {error, term()}.
security(ConnHandle) ->
    gen_server:call(?MODULE, {security, ConnHandle}, 5000).

-spec update_conn_params(ConnHandle :: non_neg_integer()) -> ok | {error, term()}.
update_conn_params(ConnHandle) ->
    gen_server:call(?MODULE, {update_conn_params, ConnHandle}, 5000).

%%--------------------------------------------------------------------
%% GATT Operations (async internally — caller blocks on gen_server:call)
%%--------------------------------------------------------------------

-spec gatt_read(ConnHandle :: non_neg_integer(), SvcUUID :: binary(), ChrUUID :: binary()) ->
    {ok, binary()} | {error, term()}.
gatt_read(ConnHandle, SvcUUID, ChrUUID)
  when byte_size(SvcUUID) =:= 16, byte_size(ChrUUID) =:= 16 ->
    gen_server:call(?MODULE, {gatt_read, ConnHandle, SvcUUID, ChrUUID}, ?GATT_TIMEOUT + 5000).

-spec gatt_write(ConnHandle :: non_neg_integer(), SvcUUID :: binary(), ChrUUID :: binary(), Value :: binary()) ->
    ok | {error, term()}.
gatt_write(ConnHandle, SvcUUID, ChrUUID, Value)
  when byte_size(SvcUUID) =:= 16, byte_size(ChrUUID) =:= 16 ->
    gen_server:call(?MODULE, {gatt_write, ConnHandle, SvcUUID, ChrUUID, Value}, ?GATT_TIMEOUT + 5000).

-spec gatt_write_nr(ConnHandle :: non_neg_integer(), SvcUUID :: binary(), ChrUUID :: binary(), Value :: binary()) ->
    ok | {error, term()}.
gatt_write_nr(ConnHandle, SvcUUID, ChrUUID, Value)
  when byte_size(SvcUUID) =:= 16, byte_size(ChrUUID) =:= 16 ->
    gen_server:call(?MODULE, {gatt_write_nr, ConnHandle, SvcUUID, ChrUUID, Value}, ?GATT_TIMEOUT + 5000).

%% @doc Discover all characteristics on a connection. Caches results.
-spec discover_services(ConnHandle :: non_neg_integer()) ->
    ok | {error, term()}.
discover_services(ConnHandle) ->
    gen_server:call(?MODULE, {discover_services, ConnHandle}, ?GATT_TIMEOUT + 5000).

%% @doc Register the BLE address for a conn_handle (enables address-based cache).
-spec register_conn(ConnHandle :: non_neg_integer(), Addr :: binary()) -> ok.
register_conn(ConnHandle, Addr) when byte_size(Addr) =:= 6 ->
    gen_server:call(?MODULE, {register_conn, ConnHandle, Addr}, 5000).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    Port = open_port({spawn, "ble_port"}, []),
    case port_call(Port, <<?OP_INIT>>) of
        {ok, _} ->
            case port_call(Port, <<?OP_SUBSCRIBE_SCAN>>) of
                {ok, _} -> ok;
                _ -> ok
            end,
            {ok, #state{port = Port, pending = #{}, conn_addrs = #{}, chr_cache = #{}}};
        Error ->
            {stop, Error}
    end.

%%--------------------------------------------------------------------
%% Synchronous ops (scan, connect, disconnect, security)
%%--------------------------------------------------------------------

handle_call({scan_start, Duration}, _From, #state{port = Port} = State) ->
    Reply = case port_call(Port, <<?OP_SCAN_START, Duration:8>>) of
        {ok, _} -> ok;
        Error   -> Error
    end,
    {reply, Reply, State};

handle_call(scan_stop, _From, #state{port = Port} = State) ->
    Reply = case port_call(Port, <<?OP_SCAN_STOP>>) of
        {ok, _} -> ok;
        Error   -> Error
    end,
    {reply, Reply, State};

handle_call({connect, Addr, AddrType}, _From, #state{port = Port} = State) ->
    Reply = case port_call(Port, <<?OP_CONNECT, Addr:6/binary, AddrType:8>>) of
        {ok, _} -> ok;
        Error   -> Error
    end,
    {reply, Reply, State};

handle_call(connect_cancel, _From, #state{port = Port} = State) ->
    Reply = case port_call(Port, <<?OP_CONNECT_CANCEL>>) of
        {ok, _} -> ok;
        Error   -> Error
    end,
    {reply, Reply, State};

handle_call({disconnect, ConnHandle}, _From, #state{port = Port} = State) ->
    Reply = case port_call(Port, <<?OP_DISCONNECT, ConnHandle:16/little>>) of
        {ok, _} -> ok;
        Error   -> Error
    end,
    %% Remove conn_handle→addr mapping but keep chr_cache (keyed by addr)
    NewAddrs = maps:remove(ConnHandle, State#state.conn_addrs),
    {reply, Reply, State#state{conn_addrs = NewAddrs}};

handle_call({register_conn, ConnHandle, Addr}, _From, State) ->
    NewAddrs = maps:put(ConnHandle, Addr, State#state.conn_addrs),
    {reply, ok, State#state{conn_addrs = NewAddrs}};

handle_call({security, ConnHandle}, _From, #state{port = Port} = State) ->
    Reply = case port_call(Port, <<?OP_SECURITY, ConnHandle:16/little>>) of
        {ok, _} -> ok;
        Error   -> Error
    end,
    {reply, Reply, State};

handle_call({update_conn_params, ConnHandle}, _From, #state{port = Port} = State) ->
    Reply = case port_call(Port, <<?OP_UPDATE_PARAMS, ConnHandle:16/little>>) of
        {ok, _} -> ok;
        Error   -> Error
    end,
    {reply, Reply, State};

%%--------------------------------------------------------------------
%% Async GATT ops — send command, defer reply until result arrives
%%--------------------------------------------------------------------

handle_call({gatt_read, ConnHandle, _SvcUUID, ChrUUID}, From, #state{port = Port} = State) ->
    case maps:is_key(ConnHandle, State#state.pending) of
        true ->
            {reply, {error, busy}, State};
        false ->
            case port_call(Port, <<?OP_GATT_READ, ConnHandle:16/little, ChrUUID:16/binary>>) of
                {ok, _} ->
                    TRef = erlang:send_after(?GATT_TIMEOUT, self(), {gatt_timeout, ConnHandle}),
                    Pending = maps:put(ConnHandle, {From, gatt_read, TRef}, State#state.pending),
                    {noreply, State#state{pending = Pending}};
                Error ->
                    {reply, Error, State}
            end
    end;

handle_call({gatt_write, ConnHandle, _SvcUUID, ChrUUID, Value}, From, #state{port = Port} = State) ->
    case maps:is_key(ConnHandle, State#state.pending) of
        true ->
            {reply, {error, busy}, State};
        false ->
            case get_val_handle(ConnHandle, ChrUUID, State) of
                {ok, ValHandle} ->
                    case port_call(Port, <<?OP_GATT_WRITE, ConnHandle:16/little,
                                           ValHandle:16/little, Value/binary>>) of
                        {ok, _} ->
                            TRef = erlang:send_after(?GATT_TIMEOUT, self(), {gatt_timeout, ConnHandle}),
                            Pending = maps:put(ConnHandle, {From, gatt_write, TRef}, State#state.pending),
                            {noreply, State#state{pending = Pending}};
                        Error ->
                            {reply, Error, State}
                    end;
                {error, no_cache} ->
                    %% Need discovery first — initiate and queue the write
                    case port_call(Port, <<?OP_DISC_SVCS, ConnHandle:16/little>>) of
                        {ok, _} ->
                            TRef = erlang:send_after(?GATT_TIMEOUT, self(), {gatt_timeout, ConnHandle}),
                            Cont = {write_after_disc, ChrUUID, Value},
                            Pending = maps:put(ConnHandle, {From, {disc_for, Cont}, TRef}, State#state.pending),
                            {noreply, State#state{pending = Pending}};
                        Error ->
                            {reply, Error, State}
                    end
            end
    end;

handle_call({gatt_write_nr, ConnHandle, _SvcUUID, ChrUUID, Value}, From, #state{port = Port} = State) ->
    case maps:is_key(ConnHandle, State#state.pending) of
        true ->
            {reply, {error, busy}, State};
        false ->
            case get_val_handle(ConnHandle, ChrUUID, State) of
                {ok, ValHandle} ->
                    Reply = case port_call(Port, <<?OP_GATT_WRITE_NR, ConnHandle:16/little,
                                                   ValHandle:16/little, Value/binary>>) of
                        {ok, _} -> ok;
                        Error   -> Error
                    end,
                    {reply, Reply, State};
                {error, no_cache} ->
                    %% Need discovery first
                    case port_call(Port, <<?OP_DISC_SVCS, ConnHandle:16/little>>) of
                        {ok, _} ->
                            TRef = erlang:send_after(?GATT_TIMEOUT, self(), {gatt_timeout, ConnHandle}),
                            Cont = {write_nr_after_disc, ChrUUID, Value},
                            Pending = maps:put(ConnHandle, {From, {disc_for, Cont}, TRef}, State#state.pending),
                            {noreply, State#state{pending = Pending}};
                        Error ->
                            {reply, Error, State}
                    end
            end
    end;

handle_call({discover_services, ConnHandle}, From, #state{port = Port} = State) ->
    case maps:is_key(ConnHandle, State#state.pending) of
        true ->
            {reply, {error, busy}, State};
        false ->
            case port_call(Port, <<?OP_DISC_SVCS, ConnHandle:16/little>>) of
                {ok, _} ->
                    TRef = erlang:send_after(?GATT_TIMEOUT, self(), {gatt_timeout, ConnHandle}),
                    Pending = maps:put(ConnHandle, {From, disc_svcs, TRef}, State#state.pending),
                    {noreply, State#state{pending = Pending}};
                Error ->
                    {reply, Error, State}
            end
    end;

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Async event handling
%%--------------------------------------------------------------------

%% GATT read result from port
handle_info({ble_gatt_read, ConnHandle, Status, Data}, State) ->
    case maps_take(ConnHandle, State#state.pending) of
        {{From, gatt_read, TRef}, Pending} ->
            erlang:cancel_timer(TRef),
            Reply = case Status of
                0 -> {ok, Data};
                _ -> {error, {ble_gatt_error, Status}}
            end,
            gen_server:reply(From, Reply),
            {noreply, State#state{pending = Pending}};
        _ ->
            {noreply, State}
    end;

%% GATT write result from port
handle_info({ble_gatt_write, ConnHandle, Status}, State) ->
    case maps_take(ConnHandle, State#state.pending) of
        {{From, gatt_write, TRef}, Pending} ->
            erlang:cancel_timer(TRef),
            Reply = case Status of
                0 -> ok;
                _ -> {error, {ble_gatt_error, Status}}
            end,
            gen_server:reply(From, Reply),
            {noreply, State#state{pending = Pending}};
        _ ->
            {noreply, State}
    end;

%% Discovery complete from port
handle_info({ble_disc_complete, ConnHandle, Status, Data}, State) ->
    case maps_take(ConnHandle, State#state.pending) of
        {{From, disc_svcs, TRef}, Pending} ->
            erlang:cancel_timer(TRef),
            case Status of
                0 ->
                    CacheMap = parse_disc_data(Data),
                    NewCache = cache_put(ConnHandle, CacheMap, State),
                    gen_server:reply(From, ok),
                    {noreply, State#state{pending = Pending, chr_cache = NewCache}};
                _ ->
                    gen_server:reply(From, {error, {ble_disc_error, Status}}),
                    {noreply, State#state{pending = Pending}}
            end;
        {{From, {disc_for, Cont}, TRef}, Pending} ->
            erlang:cancel_timer(TRef),
            case Status of
                0 ->
                    CacheMap = parse_disc_data(Data),
                    NewCache = cache_put(ConnHandle, CacheMap, State),
                    NewState = State#state{pending = Pending, chr_cache = NewCache},
                    handle_disc_continuation(ConnHandle, From, Cont, NewState);
                _ ->
                    gen_server:reply(From, {error, {ble_disc_error, Status}}),
                    {noreply, State#state{pending = Pending}}
            end;
        _ ->
            {noreply, State}
    end;

%% GATT timeout
handle_info({gatt_timeout, ConnHandle}, State) ->
    case maps_take(ConnHandle, State#state.pending) of
        {{From, _Op, _TRef}, Pending} ->
            gen_server:reply(From, {error, timeout}),
            {noreply, State#state{pending = Pending}};
        error ->
            {noreply, State}
    end;

%% Broadcast events — publish to event bus
handle_info({ble_scan_event, _, _, _, _} = Event, State) ->
    myhome_event_bus:publish(Event),
    {noreply, State};
handle_info({ble_scan_complete} = Event, State) ->
    myhome_event_bus:publish(Event),
    {noreply, State};
handle_info({ble_connected, _, _} = Event, State) ->
    myhome_event_bus:publish(Event),
    {noreply, State};
handle_info({ble_disconnected, ConnHandle, _} = Event, State) ->
    %% Clear pending ops and conn_addr mapping, keep chr_cache (keyed by addr)
    NewAddrs = maps:remove(ConnHandle, State#state.conn_addrs),
    NewState = case maps_take(ConnHandle, State#state.pending) of
        {{From, _Op, TRef}, Pending} ->
            erlang:cancel_timer(TRef),
            gen_server:reply(From, {error, disconnected}),
            State#state{pending = Pending, conn_addrs = NewAddrs};
        error ->
            State#state{conn_addrs = NewAddrs}
    end,
    myhome_event_bus:publish(Event),
    {noreply, NewState};
handle_info({ble_enc_change, _, _} = Event, State) ->
    myhome_event_bus:publish(Event),
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec port_call(port(), binary()) -> {ok, binary()} | {error, term()}.
port_call(Port, Request) ->
    case port:call(Port, Request, 30000) of
        <<?RSP_OK, Payload/binary>> ->
            {ok, Payload};
        <<?RSP_ERR, Code, Rc>> ->
            {error, {ble_error, Code, Rc}};
        <<?RSP_ERR, Code/binary>> ->
            {error, {ble_error, Code}};
        {error, _} = Err ->
            Err
    end.

%% Look up cached ValHandle for a characteristic UUID on a connection.
%% Uses conn_addrs to resolve ConnHandle → Addr, then looks up addr-based cache.
-spec get_val_handle(non_neg_integer(), binary(), #state{}) ->
    {ok, non_neg_integer()} | {error, no_cache}.
get_val_handle(ConnHandle, ChrUUID, #state{conn_addrs = Addrs, chr_cache = Cache}) ->
    case maps:find(ConnHandle, Addrs) of
        {ok, Addr} ->
            case maps:find(Addr, Cache) of
                {ok, AddrCache} ->
                    case maps:find(ChrUUID, AddrCache) of
                        {ok, ValHandle} -> {ok, ValHandle};
                        error -> {error, no_cache}
                    end;
                error ->
                    {error, no_cache}
            end;
        error ->
            %% No addr registered for this handle — can't use cache
            {error, no_cache}
    end.

%% maps:take/2 polyfill for AtomVM (which lacks it)
maps_take(Key, Map) ->
    case maps:find(Key, Map) of
        {ok, Value} -> {Value, maps:remove(Key, Map)};
        error -> error
    end.

%% Store discovery results in chr_cache keyed by Addr (looked up via conn_addrs)
cache_put(ConnHandle, CacheMap, #state{conn_addrs = Addrs, chr_cache = Cache}) ->
    case maps:find(ConnHandle, Addrs) of
        {ok, Addr} -> maps:put(Addr, CacheMap, Cache);
        error      -> Cache  %% no addr registered, can't cache
    end.

%% Parse discovery result binary into a map of ChrUUID -> ValHandle
-spec parse_disc_data(binary()) -> #{binary() => non_neg_integer()}.
parse_disc_data(<<Count:16/little, Rest/binary>>) ->
    parse_disc_entries(Count, Rest, #{});
parse_disc_data(_) ->
    #{}.

parse_disc_entries(0, _Rest, Acc) ->
    Acc;
parse_disc_entries(N, <<UUID:16/binary, ValHandle:16/little, _Props:8, Rest/binary>>, Acc) ->
    parse_disc_entries(N - 1, Rest, maps:put(UUID, ValHandle, Acc));
parse_disc_entries(_, _, Acc) ->
    Acc.

%% After discovery completes, execute the queued GATT operation
handle_disc_continuation(ConnHandle, From, {write_after_disc, ChrUUID, Value}, State) ->
    case get_val_handle(ConnHandle, ChrUUID, State) of
        {ok, ValHandle} ->
            case port_call(State#state.port, <<?OP_GATT_WRITE, ConnHandle:16/little,
                                               ValHandle:16/little, Value/binary>>) of
                {ok, _} ->
                    TRef = erlang:send_after(?GATT_TIMEOUT, self(), {gatt_timeout, ConnHandle}),
                    Pending = maps:put(ConnHandle, {From, gatt_write, TRef}, State#state.pending),
                    {noreply, State#state{pending = Pending}};
                Error ->
                    gen_server:reply(From, Error),
                    {noreply, State}
            end;
        {error, no_cache} ->
            gen_server:reply(From, {error, char_not_found}),
            {noreply, State}
    end;
handle_disc_continuation(ConnHandle, From, {write_nr_after_disc, ChrUUID, Value}, State) ->
    case get_val_handle(ConnHandle, ChrUUID, State) of
        {ok, ValHandle} ->
            Reply = case port_call(State#state.port, <<?OP_GATT_WRITE_NR, ConnHandle:16/little,
                                                       ValHandle:16/little, Value/binary>>) of
                {ok, _} -> ok;
                Error   -> Error
            end,
            gen_server:reply(From, Reply),
            {noreply, State};
        {error, no_cache} ->
            gen_server:reply(From, {error, char_not_found}),
            {noreply, State}
    end.

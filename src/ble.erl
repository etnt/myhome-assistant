%%%-------------------------------------------------------------------
%%% @doc BLE port server.
%%% Owns the native BLE port, serializes all commands, and publishes
%%% async events (scan, connect, disconnect, encryption) to the event bus.
%%% @end
%%%-------------------------------------------------------------------
-module(ble).
-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([scan_start/0, scan_start/1, scan_stop/0]).
-export([connect/2, disconnect/1, security/1]).
-export([gatt_read/3, gatt_write/4, gatt_write_nr/4]).

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
-define(OP_GATT_READ,    16#30).
-define(OP_GATT_WRITE,   16#31).
-define(OP_GATT_WRITE_NR,16#32).

%% Response status
-define(RSP_OK,  16#00).
-define(RSP_ERR, 16#01).

-record(state, {
    port :: port()
}).

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

%% @doc Initiate connection to a BLE device by address (non-blocking).
%% Addr is a 6-byte binary (little-endian MAC).
%% Returns ok immediately. Connection result arrives via the event bus
%% as {ble_connected, ConnHandle, Status}.
-spec connect(Addr :: binary(), AddrType :: 0..3) -> ok | {error, term()}.
connect(Addr, AddrType) when byte_size(Addr) =:= 6 ->
    gen_server:call(?MODULE, {connect, Addr, AddrType}, 5000).

%% @doc Disconnect by connection handle.
-spec disconnect(ConnHandle :: non_neg_integer()) -> ok | {error, term()}.
disconnect(ConnHandle) ->
    gen_server:call(?MODULE, {disconnect, ConnHandle}, 5000).

%% @doc Initiate security (pairing/bonding) on an active connection.
%% Result arrives via the event bus as {ble_enc_change, ConnHandle, Status}.
-spec security(ConnHandle :: non_neg_integer()) -> ok | {error, term()}.
security(ConnHandle) ->
    gen_server:call(?MODULE, {security, ConnHandle}, 5000).

%%--------------------------------------------------------------------
%% GATT Operations
%%--------------------------------------------------------------------

%% @doc Read a GATT characteristic by service and characteristic UUID.
%% UUIDs are 16-byte binaries in big-endian (natural) order.
-spec gatt_read(ConnHandle :: non_neg_integer(), SvcUUID :: binary(), ChrUUID :: binary()) ->
    {ok, binary()} | {error, term()}.
gatt_read(ConnHandle, SvcUUID, ChrUUID)
  when byte_size(SvcUUID) =:= 16, byte_size(ChrUUID) =:= 16 ->
    gen_server:call(?MODULE, {gatt_read, ConnHandle, SvcUUID, ChrUUID}, 15000).

%% @doc Write a GATT characteristic (with response).
-spec gatt_write(ConnHandle :: non_neg_integer(), SvcUUID :: binary(), ChrUUID :: binary(), Value :: binary()) ->
    ok | {error, term()}.
gatt_write(ConnHandle, SvcUUID, ChrUUID, Value)
  when byte_size(SvcUUID) =:= 16, byte_size(ChrUUID) =:= 16 ->
    gen_server:call(?MODULE, {gatt_write, ConnHandle, SvcUUID, ChrUUID, Value}, 15000).

%% @doc Write a GATT characteristic without response (fast path for light control).
-spec gatt_write_nr(ConnHandle :: non_neg_integer(), SvcUUID :: binary(), ChrUUID :: binary(), Value :: binary()) ->
    ok | {error, term()}.
gatt_write_nr(ConnHandle, SvcUUID, ChrUUID, Value)
  when byte_size(SvcUUID) =:= 16, byte_size(ChrUUID) =:= 16 ->
    gen_server:call(?MODULE, {gatt_write_nr, ConnHandle, SvcUUID, ChrUUID, Value}, 15000).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    Port = open_port({spawn, "ble_port"}, []),
    case port_call(Port, <<?OP_INIT>>) of
        {ok, _} ->
            %% Subscribe ourselves to async events from the port
            case port_call(Port, <<?OP_SUBSCRIBE_SCAN>>) of
                {ok, _} -> ok;
                _ -> ok  %% best-effort
            end,
            {ok, #state{port = Port}};
        Error ->
            {stop, Error}
    end.

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

handle_call({disconnect, ConnHandle}, _From, #state{port = Port} = State) ->
    Reply = case port_call(Port, <<?OP_DISCONNECT, ConnHandle:16/little>>) of
        {ok, _} -> ok;
        Error   -> Error
    end,
    {reply, Reply, State};

handle_call({security, ConnHandle}, _From, #state{port = Port} = State) ->
    Reply = case port_call(Port, <<?OP_SECURITY, ConnHandle:16/little>>) of
        {ok, _} -> ok;
        Error   -> Error
    end,
    {reply, Reply, State};

handle_call({gatt_read, ConnHandle, SvcUUID, ChrUUID}, _From, #state{port = Port} = State) ->
    Reply = port_call(Port, <<?OP_GATT_READ, ConnHandle:16/little, SvcUUID:16/binary, ChrUUID:16/binary>>),
    {reply, Reply, State};

handle_call({gatt_write, ConnHandle, SvcUUID, ChrUUID, Value}, _From, #state{port = Port} = State) ->
    Reply = case port_call(Port, <<?OP_GATT_WRITE, ConnHandle:16/little, SvcUUID:16/binary, ChrUUID:16/binary, Value/binary>>) of
        {ok, _} -> ok;
        Error   -> Error
    end,
    {reply, Reply, State};

handle_call({gatt_write_nr, ConnHandle, SvcUUID, ChrUUID, Value}, _From, #state{port = Port} = State) ->
    Reply = case port_call(Port, <<?OP_GATT_WRITE_NR, ConnHandle:16/little, SvcUUID:16/binary, ChrUUID:16/binary, Value/binary>>) of
        {ok, _} -> ok;
        Error   -> Error
    end,
    {reply, Reply, State};

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% Async events from the port — publish to event bus
handle_info({ble_scan_event, _, _, _, _} = Event, State) ->
    myhome_event_bus:publish(Event),
    {noreply, State};
handle_info({ble_scan_complete} = Event, State) ->
    myhome_event_bus:publish(Event),
    {noreply, State};
handle_info({ble_connected, _, _} = Event, State) ->
    myhome_event_bus:publish(Event),
    {noreply, State};
handle_info({ble_disconnected, _, _} = Event, State) ->
    myhome_event_bus:publish(Event),
    {noreply, State};
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
        <<?RSP_ERR, Code/binary>> ->
            {error, {ble_error, Code}};
        {error, _} = Err ->
            Err
    end.

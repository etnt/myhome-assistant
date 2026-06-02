%%%-------------------------------------------------------------------
%%% @doc BLE port driver wrapper.
%%% Provides an Erlang API over the native BLE port binary protocol.
%%% @end
%%%-------------------------------------------------------------------
-module(ble).

-export([open/0, stop/1]).
-export([scan_start/1, scan_start/2, scan_stop/1, scan_results/1]).
-export([connect/3, disconnect/2, conn_state/2]).
-export([gatt_read/4, gatt_write/5, gatt_write_nr/5]).

%% Opcodes (must match ble_port.c)
-define(OP_INIT,         16#01).
-define(OP_SCAN_START,   16#10).
-define(OP_SCAN_STOP,    16#11).
-define(OP_SCAN_RESULTS, 16#12).
-define(OP_CONNECT,      16#20).
-define(OP_DISCONNECT,   16#21).
-define(OP_CONN_STATE,   16#22).
-define(OP_GATT_READ,    16#30).
-define(OP_GATT_WRITE,   16#31).
-define(OP_GATT_WRITE_NR,16#32).

%% Response status
-define(RSP_OK,  16#00).
-define(RSP_ERR, 16#01).

%%--------------------------------------------------------------------
%% @doc Open the BLE port and initialize the NimBLE stack.
%% Returns the port reference on success.
%% @end
%%--------------------------------------------------------------------
-spec open() -> {ok, port()} | {error, term()}.
open() ->
    Port = open_port({spawn, "ble_port"}, []),
    case call(Port, <<?OP_INIT>>) of
        {ok, _} -> {ok, Port};
        Error   -> Error
    end.

-spec stop(port()) -> ok.
stop(_Port) ->
    ok.

%%--------------------------------------------------------------------
%% Scanning
%%--------------------------------------------------------------------

-spec scan_start(port()) -> ok | {error, term()}.
scan_start(Port) ->
    scan_start(Port, 10).

-spec scan_start(port(), Duration :: 1..255) -> ok | {error, term()}.
scan_start(Port, Duration) ->
    case call(Port, <<?OP_SCAN_START, Duration:8>>) of
        {ok, _} -> ok;
        Error   -> Error
    end.

-spec scan_stop(port()) -> ok | {error, term()}.
scan_stop(Port) ->
    case call(Port, <<?OP_SCAN_STOP>>) of
        {ok, _} -> ok;
        Error   -> Error
    end.

%% @doc Get scan results.
%% Returns a list of #{addr, addr_type, rssi, name}.
-spec scan_results(port()) -> {ok, [map()]} | {error, term()}.
scan_results(Port) ->
    case call(Port, <<?OP_SCAN_RESULTS>>) of
        {ok, Data} -> {ok, parse_scan_results(Data)};
        Error      -> Error
    end.

%%--------------------------------------------------------------------
%% Connection
%%--------------------------------------------------------------------

%% @doc Connect to a BLE device by address.
%% Addr is a 6-byte binary (little-endian MAC).
%% Returns {ok, ConnIdx} where ConnIdx is 0 or 1.
-spec connect(port(), Addr :: binary(), AddrType :: 0..3) -> {ok, integer()} | {error, term()}.
connect(Port, Addr, AddrType) when byte_size(Addr) =:= 6 ->
    case call(Port, <<?OP_CONNECT, Addr:6/binary, AddrType:8>>) of
        {ok, <<Idx:8>>} -> {ok, Idx};
        {ok, _}         -> {error, bad_response};
        Error           -> Error
    end.

-spec disconnect(port(), ConnIdx :: integer()) -> ok | {error, term()}.
disconnect(Port, ConnIdx) ->
    case call(Port, <<?OP_DISCONNECT, ConnIdx:8>>) of
        {ok, _} -> ok;
        Error   -> Error
    end.

-spec conn_state(port(), ConnIdx :: integer()) -> {ok, atom()} | {error, term()}.
conn_state(Port, ConnIdx) ->
    case call(Port, <<?OP_CONN_STATE, ConnIdx:8>>) of
        {ok, <<State:8>>} -> {ok, decode_conn_state(State)};
        Error             -> Error
    end.

%%--------------------------------------------------------------------
%% GATT Operations
%%--------------------------------------------------------------------

%% @doc Read a GATT characteristic by service and characteristic UUID.
%% UUIDs are 16-byte binaries in big-endian (natural) order.
-spec gatt_read(port(), ConnIdx :: integer(), SvcUUID :: binary(), ChrUUID :: binary()) ->
    {ok, binary()} | {error, term()}.
gatt_read(Port, ConnIdx, SvcUUID, ChrUUID)
  when byte_size(SvcUUID) =:= 16, byte_size(ChrUUID) =:= 16 ->
    call(Port, <<?OP_GATT_READ, ConnIdx:8, SvcUUID:16/binary, ChrUUID:16/binary>>).

%% @doc Write a GATT characteristic (with response).
-spec gatt_write(port(), ConnIdx :: integer(), SvcUUID :: binary(), ChrUUID :: binary(), Value :: binary()) ->
    ok | {error, term()}.
gatt_write(Port, ConnIdx, SvcUUID, ChrUUID, Value)
  when byte_size(SvcUUID) =:= 16, byte_size(ChrUUID) =:= 16 ->
    case call(Port, <<?OP_GATT_WRITE, ConnIdx:8, SvcUUID:16/binary, ChrUUID:16/binary, Value/binary>>) of
        {ok, _} -> ok;
        Error   -> Error
    end.

%% @doc Write a GATT characteristic without response (fast path for light control).
-spec gatt_write_nr(port(), ConnIdx :: integer(), SvcUUID :: binary(), ChrUUID :: binary(), Value :: binary()) ->
    ok | {error, term()}.
gatt_write_nr(Port, ConnIdx, SvcUUID, ChrUUID, Value)
  when byte_size(SvcUUID) =:= 16, byte_size(ChrUUID) =:= 16 ->
    case call(Port, <<?OP_GATT_WRITE_NR, ConnIdx:8, SvcUUID:16/binary, ChrUUID:16/binary, Value/binary>>) of
        {ok, _} -> ok;
        Error   -> Error
    end.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec call(port(), binary()) -> {ok, binary()} | {error, term()}.
call(Port, Request) ->
    case port:call(Port, Request, 30000) of
        <<?RSP_OK, Payload/binary>> ->
            {ok, Payload};
        <<?RSP_ERR, Code/binary>> ->
            {error, {ble_error, Code}};
        {error, _} = Err ->
            Err
    end.

parse_scan_results(<<Count:8, Rest/binary>>) ->
    parse_scan_entries(Count, Rest, []).

parse_scan_entries(0, _Rest, Acc) ->
    lists:reverse(Acc);
parse_scan_entries(N, <<Addr:6/binary, AddrType:8, RSSI:8/signed, NameLen:8,
                        Name:NameLen/binary, Rest/binary>>, Acc) ->
    Entry = #{
        addr => Addr,
        addr_type => AddrType,
        rssi => RSSI,
        name => Name
    },
    parse_scan_entries(N - 1, Rest, [Entry | Acc]);
parse_scan_entries(_, _, Acc) ->
    lists:reverse(Acc).

decode_conn_state(0) -> idle;
decode_conn_state(1) -> connecting;
decode_conn_state(2) -> connected;
decode_conn_state(3) -> bonded;
decode_conn_state(_) -> unknown.

%%%-------------------------------------------------------------------
%%% @doc BLE I2C bridge — communicates with XIAO nRF52840 over I2C.
%%%
%%% The XIAO acts as an I2C target at address 0x08.  This module sends
%%% commands by writing to REG_CMD and receives async events via a GPIO
%%% interrupt (IRQ pin, falling edge) which triggers draining REG_EVENT.
%%%
%%% Phase 1: PING/PONG only (verifies I2C link + IRQ signalling).
%%% @end
%%%-------------------------------------------------------------------
-module(myhome_ble_i2c).
-behaviour(gen_server).

-export([start_link/0, get_i2c/0]).
-export([ping/0, reset/0]).
%% BLE operations
-export([scan/1, connect/1, connect/2, disconnect/1, bond/1]).
-export([gatt_discover/1, gatt_read/2, gatt_write/3, gatt_write_nr/3]).
-export([subscribe/2, get_bonds/0, delete_bond/1, delete_bond/2, delete_bonds/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% I2C target address
-define(XIAO_ADDR, 16#08).

%% Register addresses
-define(REG_STATUS,     16#00).
-define(REG_CMD,        16#01).
-define(REG_CMD_STATUS, 16#02).
-define(REG_EVENT,      16#10).
-define(REG_EVENT_LEN,  16#11).

%% Command IDs
-define(CMD_PING,         16#01).
-define(CMD_SCAN_START,   16#02).
-define(CMD_SCAN_STOP,    16#03).
-define(CMD_CONNECT,      16#10).
-define(CMD_DISCONNECT,   16#11).
-define(CMD_BOND,         16#12).
-define(CMD_GATT_DISCOVER, 16#13).
-define(CMD_GATT_READ,    16#20).
-define(CMD_GATT_WRITE,   16#21).
-define(CMD_GATT_WRITE_NR, 16#22).
-define(CMD_SUBSCRIBE,    16#23).
-define(CMD_DELETE_BOND,  16#31).
-define(CMD_DELETE_ALL_BONDS, 16#32).
-define(CMD_RESET,        16#FF).

%% Event IDs
-define(EVT_PONG,          16#81).
-define(EVT_READY,         16#82).
-define(EVT_SCAN_RESULT,   16#83).
-define(EVT_SCAN_DONE,     16#84).
-define(EVT_CONNECTED,     16#85).
-define(EVT_DISCONNECTED,  16#86).
-define(EVT_BOND_COMPLETE, 16#87).
-define(EVT_GATT_SERVICES, 16#88).
-define(EVT_GATT_READ_RSP, 16#89).
-define(EVT_GATT_WRITE_RSP, 16#8A).
-define(EVT_GATT_NOTIFY,   16#8B).
-define(EVT_ENC_CHANGE,    16#8C).
-define(EVT_CMD_ERROR,     16#FE).

%% GPIO pins
-define(IRQ_PIN, 4).
-define(RST_PIN, 5).

%% I2C bus pins (shared with sensors)
-define(SDA_PIN, 1).
-define(SCL_PIN, 2).
-define(I2C_SPEED, 100000).

%% Ping interval (keep watchdog fed)
-define(PING_INTERVAL_MS, 10000).

-record(state, {
    i2c            :: term(),
    ready = false  :: boolean(),
    ping_timer     :: reference() | undefined,
    scan_from      :: {pid(), term()} | undefined,
    scan_results = [] :: list(),
    conn_waiters = #{} :: #{binary() => {pid(), term()}},  %% addr => From
    bond_waiters = #{} :: #{non_neg_integer() => {pid(), term()}},  %% handle => From
    connections = #{} :: #{non_neg_integer() => binary()},  %% handle => addr
    discover_waiters = #{} :: #{non_neg_integer() => {pid(), term()}},  %% conn_handle => From
    discover_results = #{} :: #{non_neg_integer() => list()},  %% conn_handle => [{uuid, handle, props}]
    gatt_read_waiters = #{} :: #{non_neg_integer() => {pid(), term()}},  %% conn_handle => From
    gatt_write_waiters = #{} :: #{non_neg_integer() => {pid(), term()}}  %% conn_handle => From
}).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

ping() ->
    gen_server:call(?MODULE, ping).

reset() ->
    gen_server:cast(?MODULE, reset_xiao).

%% Returns the shared I2C bus handle (for use by myhome_sensors etc.)
get_i2c() ->
    gen_server:call(?MODULE, get_i2c).

%% Phase 2: BLE scanning
scan(Duration) ->
    safe_call({scan, Duration}, 30000).

%% Phase 3: Connection management
connect(Addr) when byte_size(Addr) =:= 6 ->
    connect(Addr, 1);  %% default: random address type
connect(_) -> {error, invalid_addr}.

connect(Addr, AddrType) ->
    safe_call({connect, Addr, AddrType}, 15000).

disconnect(Handle) ->
    safe_call({disconnect, Handle}, 5000).

bond(Handle) ->
    safe_call({bond, Handle}, 15000).

gatt_read(ConnH, AttrH) ->
    safe_call({gatt_read, ConnH, AttrH}, 10000).
gatt_write(ConnH, AttrH, Data) ->
    safe_call({gatt_write, ConnH, AttrH, Data}, 10000).
gatt_write_nr(ConnH, AttrH, Data) ->
    safe_call({gatt_write_nr, ConnH, AttrH, Data}, 5000).
subscribe(_ConnH, _CharH) -> {error, not_implemented}.
get_bonds() -> {error, not_implemented}.

%% Delete the stored bond for a single peer (clears the LTK on the nRF).
delete_bond(Addr) when byte_size(Addr) =:= 6 ->
    delete_bond(Addr, 1);  %% default: random address type
delete_bond(_) -> {error, invalid_addr}.

delete_bond(Addr, AddrType) when byte_size(Addr) =:= 6 ->
    safe_call({delete_bond, Addr, AddrType}, 5000);
delete_bond(_, _) -> {error, invalid_addr}.

%% Delete all stored bonds.
delete_bonds() ->
    safe_call(delete_all_bonds, 5000).

%% Phase 4: GATT discovery
gatt_discover(ConnH) ->
    safe_call({gatt_discover, ConnH}, 15000).

%% Wrap gen_server:call so a timeout (or dead/overloaded server) returns
%% {error, Reason} instead of raising an exit. BLE operations run inside
%% the per-bulb gen_servers; a connect/GATT timeout must NOT crash the bulb
%% process — the caller handles {error, _} gracefully (cooldown + reply).
safe_call(Msg, Timeout) ->
    try
        gen_server:call(?MODULE, Msg, Timeout)
    catch
        exit:{timeout, _} -> {error, timeout};
        exit:{noproc, _}  -> {error, noproc};
        exit:Reason       -> {error, Reason}
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    io:format("[ble_i2c] Opening I2C bus (SDA=~p, SCL=~p, speed=~p)~n",
              [?SDA_PIN, ?SCL_PIN, ?I2C_SPEED]),
    I2C = i2c:open([{sda, ?SDA_PIN}, {scl, ?SCL_PIN},
                    {clock_speed_hz, ?I2C_SPEED}]),

    %% Configure IRQ pin as input with interrupt on falling edge
    io:format("[ble_i2c] Configuring IRQ on GPIO ~p~n", [?IRQ_PIN]),
    gpio:set_pin_mode(?IRQ_PIN, input),
    gpio:set_pin_pull(?IRQ_PIN, up),
    gpio:attach_interrupt(?IRQ_PIN, falling),

    %% Configure RST pin as output (idle HIGH)
    gpio:set_pin_mode(?RST_PIN, output),
    gpio:digital_write(?RST_PIN, 1),

    %% Wait briefly for XIAO to boot, then check for READY event
    erlang:send_after(500, self(), check_ready),

    {ok, #state{i2c = I2C}}.

handle_call(get_i2c, _From, #state{i2c = I2C} = State) ->
    {reply, I2C, State};
handle_call(ping, _From, State) ->
    Result = send_ping(State),
    {reply, Result, State};
handle_call({scan, Duration}, From, #state{i2c = I2C} = State) ->
    myhome_log:log(info, "BLE scan starting (duration=~ps)", [Duration]),
    case i2c:write_bytes(I2C, ?XIAO_ADDR, <<?REG_CMD, ?CMD_SCAN_START, Duration>>) of
        ok ->
            {noreply, State#state{scan_from = From, scan_results = []}};
        {error, _} = Err ->
            myhome_log:log(error, "BLE scan failed to start: ~p", [Err]),
            {reply, Err, State}
    end;
handle_call({connect, Addr, AddrType}, From, #state{i2c = I2C, connections = Conns} = State) ->
    myhome_log:log(info, "BLE connecting to ~s", [format_addr(Addr)]),
    %% If there's a stale connection to this address, disconnect it first
    State1 = case find_handle_by_addr(Addr, Conns) of
        undefined -> State;
        OldHandle ->
            myhome_log:log(info, "Disconnecting stale handle ~p for ~s",
                           [OldHandle, format_addr(Addr)]),
            i2c:write_bytes(I2C, ?XIAO_ADDR, <<?REG_CMD, ?CMD_DISCONNECT, OldHandle:16/little>>),
            timer:sleep(100),
            State#state{connections = maps:remove(OldHandle, Conns)}
    end,
    Cmd = <<?REG_CMD, ?CMD_CONNECT, Addr:6/binary, AddrType>>,
    case i2c:write_bytes(I2C, ?XIAO_ADDR, Cmd) of
        ok ->
            Waiters = maps:put(Addr, From, State1#state.conn_waiters),
            {noreply, State1#state{conn_waiters = Waiters}};
        {error, _} = Err ->
            {reply, Err, State1}
    end;
handle_call({disconnect, Handle}, _From, #state{i2c = I2C} = State) ->
    Cmd = <<?REG_CMD, ?CMD_DISCONNECT, Handle:16/little>>,
    case i2c:write_bytes(I2C, ?XIAO_ADDR, Cmd) of
        ok ->
            {reply, ok, State};
        {error, _} = Err ->
            {reply, Err, State}
    end;
handle_call({bond, Handle}, From, #state{i2c = I2C} = State) ->
    myhome_log:log(info, "BLE bonding handle ~p", [Handle]),
    Cmd = <<?REG_CMD, ?CMD_BOND, Handle:16/little>>,
    case i2c:write_bytes(I2C, ?XIAO_ADDR, Cmd) of
        ok ->
            Waiters = maps:put(Handle, From, State#state.bond_waiters),
            {noreply, State#state{bond_waiters = Waiters}};
        {error, _} = Err ->
            {reply, Err, State}
    end;
handle_call({gatt_discover, ConnH}, From, #state{i2c = I2C} = State) ->
    Cmd = <<?REG_CMD, ?CMD_GATT_DISCOVER, ConnH:16/little>>,
    case i2c:write_bytes(I2C, ?XIAO_ADDR, Cmd) of
        ok ->
            DW = maps:put(ConnH, From, State#state.discover_waiters),
            DR = maps:put(ConnH, [], State#state.discover_results),
            {noreply, State#state{discover_waiters = DW, discover_results = DR}};
        {error, _} = Err ->
            {reply, Err, State}
    end;
handle_call({gatt_read, ConnH, AttrH}, From, #state{i2c = I2C} = State) ->
    Cmd = <<?REG_CMD, ?CMD_GATT_READ, ConnH:16/little, AttrH:16/little>>,
    case i2c:write_bytes(I2C, ?XIAO_ADDR, Cmd) of
        ok ->
            Waiters = maps:put(ConnH, From, State#state.gatt_read_waiters),
            {noreply, State#state{gatt_read_waiters = Waiters}};
        {error, _} = Err ->
            {reply, Err, State}
    end;
handle_call({gatt_write, ConnH, AttrH, Data}, From, #state{i2c = I2C} = State) ->
    Cmd = <<?REG_CMD, ?CMD_GATT_WRITE, ConnH:16/little, AttrH:16/little, Data/binary>>,
    case i2c:write_bytes(I2C, ?XIAO_ADDR, Cmd) of
        ok ->
            Waiters = maps:put(ConnH, From, State#state.gatt_write_waiters),
            {noreply, State#state{gatt_write_waiters = Waiters}};
        {error, _} = Err ->
            {reply, Err, State}
    end;
handle_call({gatt_write_nr, ConnH, AttrH, Data}, _From, #state{i2c = I2C} = State) ->
    Cmd = <<?REG_CMD, ?CMD_GATT_WRITE_NR, ConnH:16/little, AttrH:16/little, Data/binary>>,
    case i2c:write_bytes(I2C, ?XIAO_ADDR, Cmd) of
        ok ->
            {reply, ok, State};
        {error, _} = Err ->
            {reply, Err, State}
    end;
handle_call({delete_bond, Addr, AddrType}, _From, #state{i2c = I2C} = State) ->
    myhome_log:log(info, "BLE deleting bond for ~s", [format_addr(Addr)]),
    Cmd = <<?REG_CMD, ?CMD_DELETE_BOND, Addr:6/binary, AddrType>>,
    case i2c:write_bytes(I2C, ?XIAO_ADDR, Cmd) of
        ok ->
            {reply, ok, State};
        {error, _} = Err ->
            {reply, Err, State}
    end;
handle_call(delete_all_bonds, _From, #state{i2c = I2C} = State) ->
    myhome_log:log(info, "BLE deleting all bonds", []),
    Cmd = <<?REG_CMD, ?CMD_DELETE_ALL_BONDS>>,
    case i2c:write_bytes(I2C, ?XIAO_ADDR, Cmd) of
        ok ->
            {reply, ok, State};
        {error, _} = Err ->
            {reply, Err, State}
    end;
handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(reset_xiao, State) ->
    do_reset(State),
    {noreply, State#state{ready = false}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({gpio_interrupt, ?IRQ_PIN}, State) ->
    %% XIAO has events pending — drain them
    io:format("[ble_i2c] IRQ! draining events~n"),
    State1 = drain_events(State),
    {noreply, State1};

handle_info(drain_continue, State) ->
    %% Continue draining if we hit the per-cycle limit
    io:format("[ble_i2c] drain_continue~n"),
    State1 = drain_events(State),
    {noreply, State1};

handle_info(check_ready, State) ->
    State1 = drain_events(State),
    case State1#state.ready of
        true ->
            Timer = erlang:send_after(?PING_INTERVAL_MS, self(), do_ping),
            {noreply, State1#state{ping_timer = Timer}};
        false ->
            erlang:send_after(1000, self(), check_ready),
            {noreply, State1}
    end;

handle_info(do_ping, State) ->
    send_ping(State),
    Timer = erlang:send_after(?PING_INTERVAL_MS, self(), do_ping),
    {noreply, State#state{ping_timer = Timer}};

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal
%%====================================================================

send_ping(#state{i2c = I2C}) ->
    %% Write CMD_PING to REG_CMD
    case i2c:write_bytes(I2C, ?XIAO_ADDR, <<?REG_CMD, ?CMD_PING>>) of
        ok ->
            ok;
        {error, _} = Err ->
            Err
    end.

do_reset(#state{}) ->
    gpio:digital_write(?RST_PIN, 0),
    timer:sleep(50),
    gpio:digital_write(?RST_PIN, 1),
    %% XIAO will reboot and send READY event
    erlang:send_after(1000, self(), check_ready),
    ok.

drain_events(State) ->
    drain_events(State, 64).  %% max 64 events per drain cycle (discovery can produce 30+)

drain_events(State, 0) ->
    %% Hit the limit — schedule another drain in case events remain
    erlang:send_after(10, self(), drain_continue),
    State;
drain_events(#state{i2c = I2C} = State, Remaining) ->
    %% Read REG_EVENT_LEN to check if there's an event
    case i2c:write_bytes(I2C, ?XIAO_ADDR, <<?REG_EVENT_LEN>>) of
        ok ->
            case i2c:read_bytes(I2C, ?XIAO_ADDR, 2) of
                {ok, <<0, 0>>} ->
                    %% No more events
                    io:format("[ble_i2c] drain: queue empty~n"),
                    State;
                {ok, <<EventType, PayloadLen>>} ->
                    %% Read the actual event
                    io:format("[ble_i2c] drain: evt=0x~.16B len=~p rem=~p~n",
                              [EventType, PayloadLen, Remaining]),
                    State1 = read_event(State, EventType, PayloadLen),
                    drain_events(State1, Remaining - 1);
                {error, Err} ->
                    io:format("[ble_i2c] drain: read_bytes error: ~p~n", [Err]),
                    State
            end;
        {error, Err2} ->
            io:format("[ble_i2c] drain: write_bytes error: ~p~n", [Err2]),
            State
    end.

read_event(#state{i2c = I2C} = State, EventType, PayloadLen) ->
    %% Select REG_EVENT and read type + payload
    ReadLen = 2 + PayloadLen,
    case i2c:write_bytes(I2C, ?XIAO_ADDR, <<?REG_EVENT>>) of
        ok ->
            case i2c:read_bytes(I2C, ?XIAO_ADDR, ReadLen) of
                {ok, <<_Type, _Len, Payload/binary>>} ->
                    io:format("[ble_i2c] event 0x~.16B payload=~p~n",
                              [EventType, Payload]),
                    handle_event(EventType, Payload, State);
                {ok, Other} ->
                    io:format("[ble_i2c] read_event unexpected: ~p~n", [Other]),
                    State;
                {error, Err} ->
                    io:format("[ble_i2c] read_event error: ~p~n", [Err]),
                    State
            end;
        {error, Err2} ->
            io:format("[ble_i2c] read_event write error: ~p~n", [Err2]),
            State
    end.

handle_event(?EVT_READY, _Payload, State) ->
    State#state{ready = true};

handle_event(?EVT_PONG, _Payload, State) ->
    State;

handle_event(?EVT_SCAN_RESULT,
             <<Addr:6/binary, AddrType, Rssi, NameLen, Name:NameLen/binary, _/binary>>,
             #state{scan_results = Results} = State) ->
    Result = #{addr => Addr, addr_type => AddrType,
               rssi => Rssi - 256,  %% unsigned to signed
               name => trim_nulls(Name)},
    State#state{scan_results = [Result | Results]};

handle_event(?EVT_SCAN_RESULT, _Payload, State) ->
    %% Malformed scan result, ignore
    State;

handle_event(?EVT_SCAN_DONE, _Payload,
             #state{scan_from = From, scan_results = Results} = State) ->
    myhome_log:log(info, "BLE scan done, ~p device(s) found", [length(Results)]),
    case From of
        undefined -> ok;
        _ -> gen_server:reply(From, {ok, lists:reverse(Results)})
    end,
    State#state{scan_from = undefined, scan_results = []};

handle_event(?EVT_CONNECTED, <<Handle:16/little, Addr:6/binary>>,
             #state{conn_waiters = Waiters, connections = Conns} = State) ->
    myhome_log:log(info, "BLE connected [~p] to ~s", [Handle, format_addr(Addr)]),
    State1 = State#state{
        connections = maps:put(Handle, Addr, Conns)
    },
    %% Publish so bulb gen_servers learn the handle for nRF-initiated
    %% (persistent auto-connect) links, which have no conn_waiter.
    myhome_event_bus:publish({ble_connected, Handle, Addr}),
    case maps:get(Addr, Waiters, undefined) of
        undefined -> State1;
        From ->
            gen_server:reply(From, {ok, Handle}),
            State1#state{conn_waiters = maps:remove(Addr, Waiters)}
    end;

handle_event(?EVT_DISCONNECTED, <<Handle:16/little, Reason>>,
             #state{connections = Conns} = State) ->
    Addr = maps:get(Handle, Conns, <<>>),
    myhome_log:log(info, "BLE disconnected [~p] (~s): reason=0x~.16B",
                   [Handle, format_addr(Addr), Reason]),
    myhome_event_bus:publish({ble_disconnected, Handle, Reason}),
    State#state{connections = maps:remove(Handle, Conns)};

handle_event(?EVT_BOND_COMPLETE, <<Handle:16/little, Status>>,
             #state{bond_waiters = Waiters} = State) ->
    case Status of
        0 -> myhome_log:log(info, "BLE bonding complete [~p]", [Handle]);
        _ -> myhome_log:log(error, "BLE bonding failed [~p]: status=~p", [Handle, Status])
    end,
    case maps:get(Handle, Waiters, undefined) of
        undefined -> State;
        From ->
            Reply = case Status of
                0 -> ok;
                _ -> {error, {bond_failed, Status}}
            end,
            gen_server:reply(From, Reply),
            State#state{bond_waiters = maps:remove(Handle, Waiters)}
    end;

handle_event(?EVT_ENC_CHANGE, <<Handle:16/little, Status>>,
             #state{bond_waiters = Waiters} = State) ->
    case Status of
        0 -> myhome_log:log(info, "BLE encryption established [~p]", [Handle]);
        _ -> myhome_log:log(warning, "BLE encryption failed [~p]: status=~p", [Handle, Status])
    end,
    myhome_event_bus:publish({ble_enc_change, Handle, Status}),
    %% Also resolve bond waiters (re-bonding to already-bonded device only emits enc_change)
    case maps:get(Handle, Waiters, undefined) of
        undefined -> State;
        From ->
            Reply = case Status of
                0 -> ok;
                _ -> {error, {enc_failed, Status}}
            end,
            gen_server:reply(From, Reply),
            State#state{bond_waiters = maps:remove(Handle, Waiters)}
    end;

handle_event(?EVT_GATT_SERVICES, <<ConnH:16/little, 0:16, _/binary>>,
             #state{discover_waiters = DW, discover_results = DR} = State) ->
    %% Discovery done (handle=0 sentinel)
    Results = lists:reverse(maps:get(ConnH, DR, [])),
    case maps:get(ConnH, DW, undefined) of
        undefined -> ok;
        From -> gen_server:reply(From, {ok, Results})
    end,
    State#state{discover_waiters = maps:remove(ConnH, DW),
                discover_results = maps:remove(ConnH, DR)};

handle_event(?EVT_GATT_SERVICES,
             <<ConnH:16/little, ValHandle:16/little, Props, UuidLen, Uuid:UuidLen/binary, _/binary>>,
             #state{discover_results = DR} = State) ->
    %% Accumulate discovered characteristic
    %% XIAO sends 128-bit UUIDs in BLE wire format (little-endian);
    %% normalize to big-endian (standard UUID representation) for lookup.
    NormUuid = case UuidLen of
        16 -> reverse_binary(Uuid);
        _ -> Uuid  %% 2-byte or 4-byte UUIDs stay as-is
    end,
    Entry = #{handle => ValHandle, properties => Props, uuid => NormUuid},
    Existing = maps:get(ConnH, DR, []),
    State#state{discover_results = maps:put(ConnH, [Entry | Existing], DR)};

handle_event(?EVT_GATT_READ_RSP, <<ConnH:16/little, _AttrH:16/little, Data/binary>>,
             #state{gatt_read_waiters = Waiters} = State) ->
    case maps:get(ConnH, Waiters, undefined) of
        undefined -> State;
        From ->
            gen_server:reply(From, {ok, Data}),
            State#state{gatt_read_waiters = maps:remove(ConnH, Waiters)}
    end;

handle_event(?EVT_GATT_WRITE_RSP, <<ConnH:16/little, _AttrH:16/little, Status>>,
             #state{gatt_write_waiters = Waiters} = State) ->
    case maps:get(ConnH, Waiters, undefined) of
        undefined -> State;
        From ->
            Reply = case Status of
                0 -> ok;
                _ -> {error, {gatt_write_failed, Status}}
            end,
            gen_server:reply(From, Reply),
            State#state{gatt_write_waiters = maps:remove(ConnH, Waiters)}
    end;

handle_event(?EVT_GATT_NOTIFY, <<ConnH:16/little, AttrH:16/little, Data/binary>>, State) ->
    myhome_event_bus:publish({ble_notify, ConnH, AttrH, Data}),
    State;

handle_event(?EVT_CMD_ERROR, <<_Seq, ErrorCode>>, #state{conn_waiters = CW} = State) ->
    myhome_log:log(error, "XIAO command error: code=~p", [ErrorCode]),
    %% Fail any pending connect waiters
    maps:foreach(fun(_Addr, From) ->
        gen_server:reply(From, {error, {cmd_error, ErrorCode}})
    end, CW),
    State#state{conn_waiters = #{}};

handle_event(_EventType, _Payload, State) ->
    State.

%% Strip trailing null bytes from BLE device names
trim_nulls(<<>>) -> <<>>;
trim_nulls(Bin) ->
    case binary:last(Bin) of
        0 -> trim_nulls(binary:part(Bin, 0, byte_size(Bin) - 1));
        _ -> Bin
    end.

%% Find connection handle by address (reverse lookup)
find_handle_by_addr(Addr, Conns) ->
    case [H || {H, A} <- maps:to_list(Conns), A =:= Addr] of
        [Handle | _] -> Handle;
        [] -> undefined
    end.

%% Format 6-byte BLE address as "XX:XX:XX:XX:XX:XX"
format_addr(<<A, B, C, D, E, F>>) ->
    iolist_to_binary(lists:join(":", [byte_to_hex(X) || X <- [F, E, D, C, B, A]]));
format_addr(_) -> <<"??:??:??:??:??:??">>.

reverse_binary(Bin) ->
    list_to_binary(lists:reverse(binary_to_list(Bin))).

byte_to_hex(B) ->
    [hex_char(B bsr 4), hex_char(B band 16#0F)].

hex_char(N) when N < 10 -> N + $0;
hex_char(N) -> N - 10 + $A.

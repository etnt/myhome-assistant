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
%% Future API (Phase 2+):
-export([scan/1, connect/1, connect/2, disconnect/1, bond/1]).
-export([gatt_read/2, gatt_write/3, gatt_write_nr/3]).
-export([subscribe/2, get_bonds/0, delete_bonds/0]).

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
-define(CMD_PING,       16#01).
-define(CMD_SCAN_START, 16#02).
-define(CMD_SCAN_STOP,  16#03).
-define(CMD_CONNECT,    16#10).
-define(CMD_DISCONNECT, 16#11).
-define(CMD_BOND,       16#12).
-define(CMD_RESET,      16#FF).

%% Event IDs
-define(EVT_PONG,          16#81).
-define(EVT_READY,         16#82).
-define(EVT_SCAN_RESULT,   16#83).
-define(EVT_SCAN_DONE,     16#84).
-define(EVT_CONNECTED,     16#85).
-define(EVT_DISCONNECTED,  16#86).
-define(EVT_BOND_COMPLETE, 16#87).
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
    connections = #{} :: #{non_neg_integer() => binary()}   %% handle => addr
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
    gen_server:call(?MODULE, {scan, Duration}, 30000).

%% Phase 3: Connection management
connect(Addr) when byte_size(Addr) =:= 6 ->
    connect(Addr, 1);  %% default: random address type
connect(_) -> {error, invalid_addr}.

connect(Addr, AddrType) ->
    gen_server:call(?MODULE, {connect, Addr, AddrType}, 15000).

disconnect(Handle) ->
    gen_server:call(?MODULE, {disconnect, Handle}, 5000).

bond(Handle) ->
    gen_server:call(?MODULE, {bond, Handle}, 15000).

gatt_read(_ConnH, _CharH) -> {error, not_implemented}.
gatt_write(_ConnH, _CharH, _Data) -> {error, not_implemented}.
gatt_write_nr(_ConnH, _CharH, _Data) -> {error, not_implemented}.
subscribe(_ConnH, _CharH) -> {error, not_implemented}.
get_bonds() -> {error, not_implemented}.
delete_bonds() -> {error, not_implemented}.

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
handle_call({connect, Addr, AddrType}, From, #state{i2c = I2C} = State) ->
    myhome_log:log(info, "BLE connecting to ~s", [format_addr(Addr)]),
    Cmd = <<?REG_CMD, ?CMD_CONNECT, Addr:6/binary, AddrType>>,
    case i2c:write_bytes(I2C, ?XIAO_ADDR, Cmd) of
        ok ->
            Waiters = maps:put(Addr, From, State#state.conn_waiters),
            {noreply, State#state{conn_waiters = Waiters}};
        {error, _} = Err ->
            {reply, Err, State}
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
handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(reset_xiao, State) ->
    do_reset(State),
    {noreply, State#state{ready = false}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({gpio_interrupt, ?IRQ_PIN}, State) ->
    %% XIAO has events pending — drain them
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
    drain_events(State, 16).  %% max 16 events per drain cycle

drain_events(State, 0) ->
    State;
drain_events(#state{i2c = I2C} = State, Remaining) ->
    %% Read REG_EVENT_LEN to check if there's an event
    case i2c:write_bytes(I2C, ?XIAO_ADDR, <<?REG_EVENT_LEN>>) of
        ok ->
            case i2c:read_bytes(I2C, ?XIAO_ADDR, 2) of
                {ok, <<0, 0>>} ->
                    %% No more events
                    State;
                {ok, <<EventType, PayloadLen>>} ->
                    %% Read the actual event
                    State1 = read_event(State, EventType, PayloadLen),
                    drain_events(State1, Remaining - 1);
                {error, _} ->
                    State
            end;
        {error, _} ->
            State
    end.

read_event(#state{i2c = I2C} = State, EventType, PayloadLen) ->
    %% Select REG_EVENT and read type + payload
    ReadLen = 2 + PayloadLen,
    case i2c:write_bytes(I2C, ?XIAO_ADDR, <<?REG_EVENT>>) of
        ok ->
            case i2c:read_bytes(I2C, ?XIAO_ADDR, ReadLen) of
                {ok, <<_Type, _Len, Payload/binary>>} ->
                    handle_event(EventType, Payload, State);
                {ok, _Other} ->
                    State;
                {error, _} ->
                    State
            end;
        {error, _} ->
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

handle_event(?EVT_ENC_CHANGE, <<Handle:16/little, Status>>, State) ->
    case Status of
        0 -> myhome_log:log(info, "BLE encryption established [~p]", [Handle]);
        _ -> myhome_log:log(warning, "BLE encryption failed [~p]: status=~p", [Handle, Status])
    end,
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

%% Format 6-byte BLE address as "XX:XX:XX:XX:XX:XX"
format_addr(<<A, B, C, D, E, F>>) ->
    iolist_to_binary(lists:join(":", [byte_to_hex(X) || X <- [F, E, D, C, B, A]]));
format_addr(_) -> <<"??:??:??:??:??:??">>.

byte_to_hex(B) ->
    [hex_char(B bsr 4), hex_char(B band 16#0F)].

hex_char(N) when N < 10 -> N + $0;
hex_char(N) -> N - 10 + $A.

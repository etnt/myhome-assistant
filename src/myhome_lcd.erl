%%%-------------------------------------------------------------------
%%% @doc LCD 1602 status display.
%%%
%%% Drives a 16x2 HD44780 LCD (PCF8574 I2C backpack) via the
%%% atomvm_sensors `lcd1602' driver. Shares the I2C bus owned by
%%% myhome_ble_i2c (same bus as the environment sensors).
%%%
%%% Line 0: device IP address (updated when WiFi obtains a lease).
%%% Line 1: free heap memory in KB (refreshed periodically).
%%% @end
%%%-------------------------------------------------------------------
-module(myhome_lcd).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% Common PCF8574 backpack addresses (PCF8574 = 0x27, PCF8574A = 0x3F).
-define(LCD_CANDIDATES, [16#27, 16#3F]).
%% How often to refresh the IP + free-memory lines (1 minute, so memory
%% consumption can be tracked over time).
-define(REFRESH_INTERVAL_MS, 60000).
%% Retry delay if the LCD isn't ready at boot.
-define(INIT_RETRY_MS, 10000).
%% Display geometry.
-define(COLS, 16).

-record(state, {
    lcd = undefined :: term() | undefined,
    ip  = undefined :: string() | undefined
}).

%%====================================================================
%% API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    %% Receive the IP address once WiFi is up (published by myhome_http).
    myhome_event_bus:subscribe(self(), fun
        ({network_up, _}) -> true;
        (_) -> false
    end),
    self() ! init_display,
    {ok, #state{}}.

handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% Initialise the LCD on the shared I2C bus. Retry if it's not present yet.
handle_info(init_display, State) ->
    I2C = myhome_ble_i2c:get_i2c(),
    io:format("[lcd] init_display: i2c handle = ~p~n", [I2C]),
    Results = [{Addr, probe(I2C, Addr)} || Addr <- ?LCD_CANDIDATES],
    lists:foreach(
        fun({Addr, R}) ->
            io:format("[lcd]   probe 0x~2.16.0B -> ~p~n", [Addr, R])
        end, Results),
    Acking = [Addr || {Addr, ok} <- Results],
    %% Use the first ACKing address. If none ACK (some PCF8574 backpacks
    %% don't drive reads cleanly), fall back to a blind attempt at 0x27.
    {Target, Blind} = case Acking of
        [Addr | _] -> {Addr, false};
        []         -> {hd(?LCD_CANDIDATES), true}
    end,
    case Blind of
        true ->
            io:format("[lcd] no candidate ACKed; blind attempt at 0x~2.16.0B~n",
                      [Target]);
        false ->
            io:format("[lcd] using detected address 0x~2.16.0B~n", [Target])
    end,
    %% Hardware sanity check: toggle the PCF8574 backlight bit directly.
    %% This is independent of the HD44780 init sequence — if wiring/power
    %% are correct you should physically see the backlight blink.
    backlight_blink(I2C, Target),
    try lcd1602:init(I2C, Target) of
        {ok, LCD} ->
            io:format("[lcd] lcd1602:init ok~n", []),
            %% Contrast calibration aid: fill both rows with solid blocks
            %% (char 0xFF). If you see backlight but no blocks, turn the
            %% trimpot on the backpack until the blocks appear, then back
            %% off slightly until characters would be crisp.
            io:format("[lcd] contrast test: writing solid blocks "
                      "(adjust trimpot until visible)~n", []),
            lcd1602:clear(LCD),
            Blocks = lists:duplicate(?COLS, 16#FF),
            lcd1602:write_string(LCD, 0, 0, Blocks),
            lcd1602:write_string(LCD, 1, 0, Blocks),
            timer:sleep(3000),
            io:format("[lcd] writing status~n", []),
            lcd1602:clear(LCD),
            %% myhome_http starts before us and blocks until it has an IP,
            %% so get_ip/0 already returns the lease here (no "No IP").
            State1 = State#state{lcd = LCD, ip = lookup_ip()},
            render(State1),
            myhome_log:log(info, "[lcd] display ready at 0x~.16B", [Target]),
            erlang:send_after(?REFRESH_INTERVAL_MS, self(), refresh),
            {noreply, State1}
    catch
        C:R:Stk ->
            io:format("[lcd] lcd1602:init FAILED ~p:~p~n  ~p~n", [C, R, Stk]),
            myhome_log:log(error, "[lcd] init failed (~p:~p), retrying", [C, R]),
            erlang:send_after(?INIT_RETRY_MS, self(), init_display),
            {noreply, State}
    end;

%% WiFi obtained an IP — show it on line 0.
handle_info({ble_event, {network_up, Address}}, State) ->
    Ip = format_ip(Address),
    State1 = State#state{ip = Ip},
    render(State1),
    {noreply, State1};

%% Periodic refresh of the IP + free-memory lines.
handle_info(refresh, #state{lcd = undefined} = State) ->
    erlang:send_after(?REFRESH_INTERVAL_MS, self(), refresh),
    {noreply, State};
handle_info(refresh, State) ->
    State1 = State#state{ip = lookup_ip()},
    render(State1),
    erlang:send_after(?REFRESH_INTERVAL_MS, self(), refresh),
    {noreply, State1};

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal
%%====================================================================

%% Render both lines. Line 0: IP (or "No IP"), line 1: free heap.
render(#state{lcd = undefined}) ->
    ok;
render(#state{lcd = LCD, ip = Ip}) ->
    Line0 = case Ip of
        undefined -> "No IP";
        _ -> Ip
    end,
    lcd1602:write_string(LCD, 0, 0, pad(Line0)),
    lcd1602:write_string(LCD, 1, 0, pad(free_mem_str())),
    ok.

%% Line 1: current and minimum-ever free heap in KB, e.g. "Mem:8266/8100K".
%% Current = free right now (fluctuates); minimum = lowest ever seen since
%% boot (worst-case headroom / slow-leak indicator).
free_mem_str() ->
    Cur = heap_kb(esp32_free_heap_size),
    Min = heap_kb(esp32_minimum_free_size),
    "Mem:" ++ Cur ++ "/" ++ Min ++ "K".

heap_kb(Key) ->
    case catch erlang:system_info(Key) of
        Bytes when is_integer(Bytes) -> integer_to_list(Bytes div 1024);
        _ -> "?"
    end.

%% Current IP as a display string, queried from myhome_http. Returns
%% `undefined' if WiFi hasn't obtained a lease (rendered as "No IP").
lookup_ip() ->
    case myhome_http:get_ip() of
        {_, _, _, _} = Addr -> format_ip(Addr);
        _ -> undefined
    end.

format_ip({A, B, C, D}) ->
    integer_to_list(A) ++ "." ++ integer_to_list(B) ++ "." ++
        integer_to_list(C) ++ "." ++ integer_to_list(D).

%% Pad/truncate a string to exactly ?COLS chars so stale characters
%% from a previous (longer) value are overwritten with spaces.
pad(Str) ->
    Flat = binary_to_list(iolist_to_binary(Str)),
    case length(Flat) of
        N when N >= ?COLS -> lists:sublist(Flat, ?COLS);
        N -> Flat ++ lists:duplicate(?COLS - N, $\s)
    end.

%% Probe a single 7-bit address with a 1-byte read. read_bytes surfaces
%% NAK (unlike write_bytes), so {ok, _} means the device ACKed.
probe(I2C, Addr) ->
    case catch i2c:read_bytes(I2C, Addr, 1) of
        {ok, _} -> ok;
        {error, R} -> {error, R};
        Other -> {error, Other}
    end.

%% Toggle the PCF8574 backlight bit (P3) a few times. Pure I2C writes,
%% no HD44780 dependency — a working, correctly-addressed backpack will
%% physically blink the backlight even if the LCD init is wrong.
backlight_blink(I2C, Addr) ->
    io:format("[lcd] backlight blink test @ 0x~2.16.0B~n", [Addr]),
    lists:foreach(
        fun(_) ->
            i2c:write_bytes(I2C, Addr, <<16#08>>),  %% backlight on
            timer:sleep(150),
            i2c:write_bytes(I2C, Addr, <<16#00>>),  %% backlight off
            timer:sleep(150)
        end, [1, 2, 3]),
    i2c:write_bytes(I2C, Addr, <<16#08>>).  %% leave backlight on

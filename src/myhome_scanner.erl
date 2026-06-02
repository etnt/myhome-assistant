%%%-------------------------------------------------------------------
%%% @doc BLE device scanner.
%%% Scans for advertising BLE devices and accumulates results from
%%% async events sent by the BLE port driver.
%%% @end
%%%-------------------------------------------------------------------
-module(myhome_scanner).
-behaviour(gen_server).

-export([start_link/0, scan/0, scan/1, get_results/0, get_raw_results/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(DEFAULT_DURATION, 10).  %% seconds

-record(state, {
    results = [] :: [map()],
    scanning = false :: boolean(),
    scan_from :: gen_server:from() | undefined,
    scan_map = #{} :: #{binary() => map()},
    last_scan :: binary() | undefined
}).

%%====================================================================
%% Public API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Trigger a scan with default duration (10s).
-spec scan() -> ok | {error, term()}.
scan() ->
    scan(?DEFAULT_DURATION).

%% @doc Trigger a scan with specified duration in seconds.
-spec scan(pos_integer()) -> ok | {error, term()}.
scan(Duration) when Duration >= 1, Duration =< 30 ->
    gen_server:call(?MODULE, {scan, Duration}, (Duration + 5) * 1000);
scan(_) ->
    {error, invalid_duration}.

%% @doc Get the last scan results (formatted for HTTP API).
-spec get_results() -> {ok, #{results := [map()], scanning := boolean(), last_scan := binary() | undefined}}.
get_results() ->
    gen_server:call(?MODULE, get_results).

%% @doc Get the last scan results as raw data (binary addresses).
-spec get_raw_results() -> {ok, [map()]}.
get_raw_results() ->
    gen_server:call(?MODULE, get_raw_results).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    %% Subscribe to scan events from the event bus
    Filter = fun
        ({ble_scan_event, _, _, _, _}) -> true;
        ({ble_scan_complete}) -> true;
        (_) -> false
    end,
    myhome_event_bus:subscribe(self(), Filter),
    {ok, #state{}}.

handle_call({scan, _Duration}, _From, #state{scanning = true} = State) ->
    {reply, {error, scan_in_progress}, State};
handle_call({scan, Duration}, From, State) ->
    case ble:scan_start(Duration) of
        ok ->
            %% Don't reply yet — we'll reply when ble_scan_complete arrives
            {noreply, State#state{scanning = true, scan_from = From, scan_map = #{}}};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;
handle_call(get_results, _From, State) ->
    Reply = #{
        results => format_results(State#state.results),
        scanning => State#state.scanning,
        last_scan => State#state.last_scan
    },
    {reply, {ok, Reply}, State};
handle_call(get_raw_results, _From, State) ->
    {reply, {ok, State#state.results}, State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% Unwrap events from the event bus
handle_info({ble_event, Event}, State) ->
    handle_info(Event, State);

handle_info({ble_scan_event, Addr, AddrType, RSSI, Name}, #state{scanning = true, scan_map = Map} = State) ->
    %% Dedup by address, update RSSI, prefer non-empty name
    Entry = case maps:get(Addr, Map, undefined) of
        undefined ->
            #{addr => Addr, addr_type => AddrType, rssi => RSSI, name => Name};
        Existing ->
            NewName = case Name of
                <<>> -> maps:get(name, Existing);
                _ -> Name
            end,
            Existing#{rssi => RSSI, name => NewName}
    end,
    {noreply, State#state{scan_map = maps:put(Addr, Entry, Map)}};
handle_info({ble_scan_event, _Addr, _AddrType, _RSSI, _Name}, State) ->
    %% Not scanning — ignore stray events
    {noreply, State};
handle_info({ble_scan_complete}, #state{scanning = true, scan_from = From, scan_map = Map} = State) ->
    Results = maps:values(Map),
    myhome_log:log(info, "[scanner] Found ~p device(s)", [length(Results)]),
    Timestamp = format_timestamp(),
    gen_server:reply(From, {ok, length(Results)}),
    {noreply, State#state{
        results = Results,
        scanning = false,
        scan_from = undefined,
        scan_map = #{},
        last_scan = Timestamp
    }};
handle_info({ble_scan_complete}, State) ->
    {noreply, State};

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal
%%====================================================================

format_results(Results) ->
    lists:map(fun(#{addr := Addr, addr_type := AddrType, rssi := RSSI, name := Name}) ->
        #{
            addr => format_addr(Addr),
            addr_type => AddrType,
            rssi => RSSI,
            name => Name
        }
    end, Results).

format_addr(<<A, B, C, D, E, F>>) ->
    iolist_to_binary(io_lib:format("~2.16.0B:~2.16.0B:~2.16.0B:~2.16.0B:~2.16.0B:~2.16.0B",
                                   [F, E, D, C, B, A])).

format_timestamp() ->
    iolist_to_binary(io_lib:format("scan_~p", [erlang:monotonic_time()])).

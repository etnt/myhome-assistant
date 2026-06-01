%%%-------------------------------------------------------------------
%%% @doc BLE device scanner.
%%% Scans for advertising BLE devices and stores results.
%%% Triggered on-demand via HTTP API or programmatically.
%%% @end
%%%-------------------------------------------------------------------
-module(myhome_scanner).
-behaviour(gen_server).

-export([start_link/1, scan/0, scan/1, get_results/0, get_raw_results/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(DEFAULT_DURATION, 10).  %% seconds

-record(state, {
    port :: port(),
    results = [] :: [map()],
    scanning = false :: boolean(),
    last_scan :: binary() | undefined
}).

%%====================================================================
%% Public API
%%====================================================================

-spec start_link(port()) -> {ok, pid()} | {error, term()}.
start_link(Port) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Port, []).

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

init(Port) ->
    {ok, #state{port = Port}}.

handle_call({scan, _Duration}, _From, #state{scanning = true} = State) ->
    {reply, {error, scan_in_progress}, State};
handle_call({scan, Duration}, _From, #state{port = Port} = State) ->
    case ble:scan_start(Port, Duration) of
        ok ->
            %% Wait for scan to complete, then collect results
            timer:sleep((Duration + 1) * 1000),
            case ble:scan_results(Port) of
                {ok, Results} ->
                    Timestamp = format_timestamp(),
                    NewState = State#state{
                        results = Results,
                        scanning = false,
                        last_scan = Timestamp
                    },
                    io:format("[scanner] Found ~p device(s)~n", [length(Results)]),
                    {reply, {ok, length(Results)}, NewState};
                {error, Reason} ->
                    {reply, {error, Reason}, State#state{scanning = false}}
            end;
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
    %% Simple timestamp — erlang:system_time not always available on AtomVM
    iolist_to_binary(io_lib:format("scan_~p", [erlang:monotonic_time()])).

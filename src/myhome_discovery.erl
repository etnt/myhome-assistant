%%%-------------------------------------------------------------------
%%% @doc BLE discovery and pairing gen_server.
%%%
%%% On init, loads bulb config from NVS and dynamically starts bulb
%%% gen_servers under myhome_sup. Discovery must be triggered
%%% explicitly via the HTTP API (POST /api/discover).
%%% @end
%%%-------------------------------------------------------------------
-module(myhome_discovery).
-behaviour(gen_server).

-export([start_link/0, run_discovery/0, get_config/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SCAN_DURATION, 15).  %% seconds

-record(state, {
    config = [] :: [{atom(), binary(), integer()}]
}).

%%====================================================================
%% Public API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Trigger a new discovery and pairing flow.
%% Scans for Hue bulbs, pairs with them, saves to NVS, and starts
%% new bulb gen_servers under the supervisor.
-spec run_discovery() -> {ok, non_neg_integer()} | {error, term()}.
run_discovery() ->
    gen_server:call(?MODULE, run_discovery, 60000).

%% @doc Get current bulb configuration.
-spec get_config() -> {ok, [{atom(), binary(), integer()}]}.
get_config() ->
    gen_server:call(?MODULE, get_config).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    %% Send ourselves a message to do initial setup after init returns
    self() ! init_bulbs,
    {ok, #state{}}.

handle_call(run_discovery, _From, State) ->
    case do_discovery() of
        {ok, [_|_] = Paired} ->
            NewConfig = [{Name, Addr, AddrType} || {Name, Addr, AddrType, _} <- Paired],
            start_bulb_children(NewConfig),
            AllConfig = State#state.config ++ NewConfig,
            {reply, {ok, length(NewConfig)}, State#state{config = AllConfig}};
        {ok, []} ->
            {reply, {ok, 0}, State};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;
handle_call(get_config, _From, State) ->
    {reply, {ok, State#state.config}, State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(init_bulbs, State) ->
    Config = load_config(),
    case Config of
        [] ->
            myhome_log:log(info, "No bulbs configured. Use POST /api/discover to pair."),
            {noreply, State};
        _ ->
            myhome_log:log(info, "Starting ~p bulb(s) from NVS config", [length(Config)]),
            start_bulb_children(Config),
            {noreply, State#state{config = Config}}
    end;
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Discovery logic
%%====================================================================

do_discovery() ->
    myhome_log:log(info, "=== Hue Bulb Discovery ==="),
    myhome_log:log(info, "Make sure your Hue bulbs are in pairing mode"),
    myhome_log:log(info, "(power-cycle the bulb -- it stays in pairing mode for 30s)"),
    myhome_log:log(info, "Scanning for ~p seconds...", [?SCAN_DURATION]),

    case scan_for_hue() of
        {ok, []} ->
            myhome_log:log(info, "No Hue bulbs found."),
            {ok, []};
        {ok, Bulbs} ->
            myhome_log:log(info, "Found ~p Hue bulb(s):", [length(Bulbs)]),
            print_bulbs(Bulbs),
            myhome_log:log(info, "Attempting to pair with each bulb..."),
            Paired = pair_all(Bulbs),
            myhome_log:log(info, "=== Pairing complete ==="),
            print_paired(Paired),
            save_config(Paired),
            {ok, Paired};
        {error, Reason} ->
            myhome_log:log(error, "Scan failed: ~p", [Reason]),
            {error, Reason}
    end.

scan_for_hue() ->
    case myhome_scanner:scan(?SCAN_DURATION) of
        {ok, _Count} ->
            case myhome_scanner:get_raw_results() of
                {ok, Results} ->
                    {ok, filter_hue_bulbs(Results)};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%%====================================================================
%% Bulb child management
%%====================================================================

start_bulb_children(Config) ->
    lists:foreach(fun({Name, Addr, AddrType}) ->
        ChildSpec = #{
            id => Name,
            start => {myhome_hue_ble, start_link, [Addr, AddrType, Name]},
            restart => permanent,
            shutdown => 5000,
            type => worker
        },
        case supervisor:start_child(myhome_sup, ChildSpec) of
            {ok, _Pid} ->
                myhome_log:log(info, "Started ~p", [Name]);
            {error, {already_started, _}} ->
                myhome_log:log(info, "~p already running", [Name]);
            {error, Reason} ->
                myhome_log:log(error, "Failed to start ~p: ~p", [Name, Reason])
        end
    end, Config).

%%====================================================================
%% Pairing
%%====================================================================

pair(Addr, AddrType) ->
    myhome_log:log(info, "Connecting to ~s...", [format_addr(Addr)]),
    case myhome_ble_conn:connect_sync(Addr, AddrType) of
        {ok, ConnHandle} ->
            myhome_log:log(info, "~s connected (handle=~p), initiating security...",
                           [format_addr(Addr), ConnHandle]),
            %% Subscribe to enc_change events temporarily
            Self = self(),
            Filter = fun({ble_enc_change, H, _}) when H =:= ConnHandle -> true;
                        (_) -> false end,
            myhome_event_bus:subscribe(Self, Filter),
            ble:security(ConnHandle),
            %% Wait for enc_change result (up to 10s)
            Result = receive
                {ble_event, {ble_enc_change, ConnHandle, 0}} ->
                    myhome_log:log(info, "~s pairing successful!", [format_addr(Addr)]),
                    ok;
                {ble_event, {ble_enc_change, ConnHandle, Status}} ->
                    myhome_log:log(error, "~s pairing FAILED (status=~p)", [format_addr(Addr), Status]),
                    {error, {security_failed, Status}}
            after 10000 ->
                myhome_log:log(error, "~s pairing timeout (no enc_change received)", [format_addr(Addr)]),
                {error, pairing_timeout}
            end,
            myhome_event_bus:unsubscribe(Self),
            ble:disconnect(ConnHandle),
            Result;
        {error, Reason} ->
            myhome_log:log(error, "~s connect failed: ~p", [format_addr(Addr), Reason]),
            {error, Reason}
    end.

pair_all(Bulbs) ->
    pair_all(Bulbs, next_bulb_number(), []).

pair_all([], _N, Acc) ->
    lists:reverse(Acc);
pair_all([#{addr := Addr, addr_type := AddrType, name := Name} | Rest], N, Acc) ->
    BulbName = list_to_atom("bulb_" ++ integer_to_list(N)),
    case pair(Addr, AddrType) of
        ok ->
            Entry = {BulbName, Addr, AddrType, Name},
            pair_all(Rest, N + 1, [Entry | Acc]);
        {error, _} ->
            pair_all(Rest, N + 1, Acc)
    end.

%% Find the next available bulb number
next_bulb_number() ->
    next_bulb_number(1).

next_bulb_number(N) when N > 8 -> N;
next_bulb_number(N) ->
    Name = list_to_atom("bulb_" ++ integer_to_list(N)),
    case whereis(Name) of
        undefined -> N;
        _ -> next_bulb_number(N + 1)
    end.

%%====================================================================
%% NVS config
%%====================================================================

load_config() ->
    try load_bulbs(1, [])
    catch C:R ->
        io:format("[discovery] load_config crash: ~p:~p~n", [C, R]),
        []
    end.

load_bulbs(N, Acc) when N > 4 ->
    lists:reverse(Acc);
load_bulbs(N, Acc) ->
    Name = list_to_atom("bulb_" ++ integer_to_list(N)),
    Key = list_to_atom("bulb_" ++ integer_to_list(N) ++ "_addr"),
    try esp:nvs_get_binary(myhome, Key) of
        Addr when is_binary(Addr), byte_size(Addr) =:= 6 ->
            myhome_log:log(info, "Loaded ~p from NVS: ~s", [Name, format_addr(Addr)]),
            load_bulbs(N + 1, [{Name, Addr, 1} | Acc]);
        _ ->
            lists:reverse(Acc)
    catch _:_ ->
        lists:reverse(Acc)
    end.

save_config(Paired) ->
    lists:foreach(fun({Name, Addr, _AddrType, DisplayName}) ->
        Key = list_to_atom(atom_to_list(Name) ++ "_addr"),
        NameKey = list_to_atom(atom_to_list(Name) ++ "_name"),
        try
            esp:nvs_set_binary(myhome, Key, Addr),
            esp:nvs_set_binary(myhome, NameKey, DisplayName),
            myhome_log:log(info, "Saved ~p (~s) to NVS", [Name, DisplayName])
        catch C:R ->
            io:format("[discovery] save NVS ~p crash: ~p:~p~n", [Name, C, R]),
            myhome_log:log(warning, "Could not save ~p to NVS", [Name])
        end
    end, Paired).

%%====================================================================
%% Helpers
%%====================================================================

filter_hue_bulbs(Results) ->
    lists:filter(fun(#{name := Name}) ->
        is_hue_name(Name);
    (_) ->
        false
    end, Results).

is_hue_name(<<>>) -> false;
is_hue_name(Name) when is_binary(Name) ->
    Lower = to_lower(Name),
    binary:match(Lower, <<"hue">>) =/= nomatch;
is_hue_name(_) -> false.

to_lower(Bin) ->
    << <<(lower_char(C))>> || <<C>> <= Bin >>.

lower_char(C) when C >= $A, C =< $Z -> C + 32;
lower_char(C) -> C.

print_bulbs(Bulbs) ->
    lists:foldl(fun(#{addr := Addr, rssi := RSSI, name := Name}, N) ->
        myhome_log:log(info, "  ~p. ~s (~s) RSSI: ~p dBm",
                  [N, Name, format_addr(Addr), RSSI]),
        N + 1
    end, 1, Bulbs).

print_paired(Paired) ->
    lists:foreach(fun({Name, Addr, _AddrType, DisplayName}) ->
        myhome_log:log(info, "  ~p: ~s (~s)", [Name, DisplayName, format_addr(Addr)])
    end, Paired).

format_addr(<<A, B, C, D, E, F>>) ->
    iolist_to_binary(lists:join(":", [byte_to_hex(X) || X <- [F, E, D, C, B, A]])).

byte_to_hex(B) ->
    [hex_char(B bsr 4), hex_char(B band 16#0F)].

hex_char(N) when N < 10 -> N + $0;
hex_char(N) -> N - 10 + $A.

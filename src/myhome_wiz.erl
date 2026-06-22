%%%-------------------------------------------------------------------
%%% @doc Philips WiZ lamp driver.
%%%
%%% WiZ lamps are controlled over the local network with JSON-over-UDP
%%% on port 38899 (no cloud, no hub). The ESP32-S3 already runs a WiFi
%%% stack for the HTTP API, so this single gen_server can talk to every
%%% lamp directly via `gen_udp' — no extra hardware.
%%%
%%% Lamps are addressed by logical name (e.g. living_room) in
%%% {@link myhome_config:wiz_lamps/0}. Each name maps to either:
%%%   * a static IP tuple `{192,168,1,150}' — used directly, or
%%%   * a MAC binary `<<"a8bb50aabbcc">>' — resolved to the lamp's
%%%     current IP by discovery, so DHCP can hand out any address.
%%%
%%% Discovery unicast-scans the local subnet (derived from the netmask, so
%%% wider-than-/24 LANs are covered): a `getPilot' request is sent
%%% to every host, and each WiZ lamp replies with its MAC. We map
%%% MAC -> IP and cache it. Discovery runs shortly after boot,
%%% periodically, and on-demand when an unknown lamp is addressed.
%%% (Broadcast is avoided: AtomVM does not expose SO_BROADCAST and
%%% ESP-IDF lwIP filters unprivileged broadcasts.)
%%%
%%% AtomVM notes: JSON payloads are built with `iolist_to_binary/1'
%%% (`list_to_binary/1' on iolists hangs); the control socket is opened
%%% lazily so boot ordering relative to WiFi never matters; discovery
%%% uses a short-lived active socket and a deadline-bounded receive.
%%% @end
%%%-------------------------------------------------------------------
-module(myhome_wiz).
-behaviour(gen_server).

%% Public API
-export([start_link/0]).
-export([set_power/2, set_brightness/2, set_color_temp/2, set_rgb/4]).
-export([discover/0, list/0, get_state/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(WIZ_PORT, 38899).
%% Generous enough that a control/state call which parks behind an on-demand
%% local /24 scan (sends + reply window) resolves before the caller times out.
-define(CALL_TIMEOUT, 12000).
-define(DISCOVER_CALL_TIMEOUT, 25000).

%% getPilot request — every WiZ lamp answers with its state, including "mac".
-define(GETPILOT, <<"{\"method\":\"getPilot\",\"params\":{}}">>).

%% Discovery timing.
-define(DISC_WINDOW_MS, 1500).      %% reply-collection window per scan
-define(DISC_INITIAL_MS, 8000).     %% first scan, after WiFi settles
-define(DISC_INTERVAL_MS, 300000).  %% periodic refresh (5 min)
-define(DISC_MAX_HOSTS, 1500).      %% cap sweep size (>/22 falls back to /24)
-define(STATE_RECV_MS, 600).        %% getPilot reply wait for a live state read

-record(state, {
    socket :: term() | undefined,            %% control socket, opened lazily
    cache = #{} :: #{atom() => tuple()},     %% Name => IP, from discovery
    scanning = false :: boolean(),           %% a discovery sweep is in flight
    waiters = [] :: [term()],                %% discover/0 callers awaiting the sweep
    pending = [] :: [{term(), atom(), term()}] %% control/state calls awaiting resolution
}).

%%====================================================================
%% Public API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Turn a lamp on or off. Name is a logical lamp name from
%% myhome_config:wiz_lamps/0.
-spec set_power(atom(), boolean()) -> ok | {error, term()}.
set_power(Name, On) when is_boolean(On) ->
    gen_server:call(?MODULE, {pilot, Name, #{state => On}}, ?CALL_TIMEOUT).

%% @doc Set brightness as a WiZ dimming percentage (10..100).
-spec set_brightness(atom(), 10..100) -> ok | {error, term()}.
set_brightness(Name, Bri) when Bri >= 10, Bri =< 100 ->
    gen_server:call(?MODULE, {pilot, Name, #{dimming => Bri}}, ?CALL_TIMEOUT).

%% @doc Set white color temperature in Kelvin (2200..6500).
-spec set_color_temp(atom(), 2200..6500) -> ok | {error, term()}.
set_color_temp(Name, Temp) when Temp >= 2200, Temp =< 6500 ->
    gen_server:call(?MODULE, {pilot, Name, #{temp => Temp}}, ?CALL_TIMEOUT).

%% @doc Set RGB color, each channel 0..255.
-spec set_rgb(atom(), 0..255, 0..255, 0..255) -> ok | {error, term()}.
set_rgb(Name, R, G, B)
  when R >= 0, R =< 255, G >= 0, G =< 255, B >= 0, B =< 255 ->
    gen_server:call(?MODULE, {pilot, Name, #{r => R, g => G, b => B}}, ?CALL_TIMEOUT).

%% @doc Scan the local network for WiZ lamps. Refreshes the name->IP cache
%% and returns every lamp found as `#{ip => {A,B,C,D}, mac => <<"hex">>}'.
%% Handy for first-time setup: run it to read the MACs to put in the config.
-spec discover() -> {ok, [map()]} | {error, term()}.
discover() ->
    gen_server:call(?MODULE, discover, ?DISCOVER_CALL_TIMEOUT).

%% @doc List the configured lamps with their resolved IPs, for the UI.
%% Static-IP lamps report their configured IP; MAC-addressed lamps report
%% the cached IP from discovery, or `undefined' if not yet seen.
-spec list() -> [#{name => atom(), mac => binary() | undefined,
                   ip => tuple() | undefined}].
list() ->
    gen_server:call(?MODULE, list, ?CALL_TIMEOUT).

%% @doc Read a lamp's current state live (getPilot). Returns a map with the
%% keys present in the reply: `power' (boolean), `brightness' (10..100),
%% `color_temp' (Kelvin), and `r'/`g'/`b' (0..255) when in color mode.
-spec get_state(atom()) -> {ok, map()} | {error, term()}.
get_state(Name) ->
    gen_server:call(?MODULE, {get_state, Name}, ?CALL_TIMEOUT).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    %% Control socket is opened on first use (ensure_socket/1) so this
    %% never races WiFi coming up during boot. Schedule the first scan
    %% once the network has had a moment to settle.
    erlang:send_after(?DISC_INITIAL_MS, self(), refresh_discovery),
    myhome_log:log(info, "[myhome_wiz] ready"),
    {ok, #state{socket = undefined, cache = #{}}}.

handle_call({pilot, Name, Params}, From, State0) ->
    %% Resolve from cache and act immediately; on a cache miss, kick a fast
    %% local scan and park the caller until the lamp's IP is known (rather
    %% than failing — MAC-addressed lamps are cold right after boot).
    case classify(Name, State0) of
        {ready, IP} ->
            {Reply, State1} = do_pilot(IP, Params, State0),
            {reply, Reply, State1};
        needs_scan ->
            {noreply, park(From, Name, {pilot, Params}, start_scan(local24, State0))};
        {error, Reason} ->
            {reply, {error, Reason}, State0}
    end;
handle_call({get_state, Name}, From, State0) ->
    case classify(Name, State0) of
        {ready, IP} ->
            {Reply, State1} = do_get_state(IP, State0),
            {reply, Reply, State1};
        needs_scan ->
            {noreply, park(From, Name, get_state, start_scan(local24, State0))};
        {error, Reason} ->
            {reply, {error, Reason}, State0}
    end;
handle_call(discover, From, State0) ->
    %% Run the (potentially ~1000-host) sweep in a spawned worker so the
    %% gen_server stays responsive to lamp-control calls. The caller is
    %% parked in `waiters' and answered when the sweep result arrives.
    State1 = start_scan(full, State0),
    {noreply, State1#state{waiters = [From | State1#state.waiters]}};
handle_call(list, _From, State) ->
    Lamps = maps:fold(fun(Name, Val, Acc) ->
        Entry = case Val of
            {_, _, _, _} = IP ->
                #{name => Name, mac => undefined, ip => IP};
            Mac when is_binary(Mac) ->
                #{name => Name, mac => Mac,
                  ip => maps:get(Name, State#state.cache, undefined)};
            _ ->
                #{name => Name, mac => undefined, ip => undefined}
        end,
        [Entry | Acc]
    end, [], myhome_config:wiz_lamps()),
    {reply, Lamps, State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(refresh_discovery, State0) ->
    %% Periodic background refresh — full subnet sweep, fire-and-forget.
    State1 = start_scan(full, State0),
    erlang:send_after(?DISC_INTERVAL_MS, self(), refresh_discovery),
    {noreply, State1};
handle_info({discovery_result, {ok, Found}}, State0) ->
    Cache = build_cache(Found, State0#state.cache),
    myhome_log:log(info, "[myhome_wiz] discovered ~p lamp(s)", [length(Found)]),
    Reply = {ok, [#{ip => IP, mac => Mac} || {IP, Mac} <- Found]},
    [gen_server:reply(W, Reply) || W <- State0#state.waiters],
    State1 = State0#state{cache = Cache, scanning = false, waiters = []},
    {noreply, drain_pending(State1)};
handle_info({discovery_result, {error, Reason}}, State0) ->
    [gen_server:reply(W, {error, Reason}) || W <- State0#state.waiters],
    [gen_server:reply(From, {error, Reason}) || {From, _, _} <- State0#state.pending],
    {noreply, State0#state{scanning = false, waiters = [], pending = []}};
handle_info({udp, _Sock, _Addr, _Port, _Packet}, State) ->
    %% Stray late reply from a closed discovery socket — ignore.
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{socket = undefined}) ->
    ok;
terminate(_Reason, #state{socket = Socket}) ->
    gen_udp:close(Socket),
    ok.

%%====================================================================
%% Internal — IP resolution & request servicing
%%====================================================================

%% Decide how to service a request for Name without side effects beyond the
%% cache lookup. Static-IP lamps are always ready; MAC-addressed lamps are
%% ready once discovered, else `needs_scan'.
classify(Name, State) ->
    case maps:find(Name, myhome_config:wiz_lamps()) of
        error ->
            {error, unknown_lamp};
        {ok, {_, _, _, _} = IP} ->
            {ready, IP};
        {ok, Mac} when is_binary(Mac) ->
            case maps:find(Name, State#state.cache) of
                {ok, IP} -> {ready, IP};
                error    -> needs_scan
            end;
        {ok, _Other} ->
            {error, bad_lamp_config}
    end.

%% Pure cache lookup (no scan) used when draining parked callers.
lookup_ip(Name, State) ->
    case maps:find(Name, myhome_config:wiz_lamps()) of
        {ok, {_, _, _, _} = IP} -> {ok, IP};
        {ok, Mac} when is_binary(Mac) -> maps:find(Name, State#state.cache);
        _ -> error
    end.

%% Park a control/state caller until the next discovery result resolves it.
park(From, Name, Action, State) ->
    State#state{pending = [{From, Name, Action} | State#state.pending]}.

%% Once discovery has merged into the cache, answer every parked caller by
%% re-resolving and performing its action (or failing if still unknown).
drain_pending(#state{pending = []} = State) ->
    State;
drain_pending(#state{pending = Pending} = State0) ->
    State1 = lists:foldl(fun({From, Name, Action}, S) ->
        case lookup_ip(Name, S) of
            {ok, IP} ->
                {Reply, S1} = perform(Action, IP, S),
                gen_server:reply(From, Reply),
                S1;
            error ->
                gen_server:reply(From, {error, lamp_not_found}),
                S
        end
    end, State0, Pending),
    State1#state{pending = []}.

perform({pilot, Params}, IP, State) -> do_pilot(IP, Params, State);
perform(get_state, IP, State)       -> do_get_state(IP, State).

%% Send a setPilot to a resolved IP, opening the control socket if needed.
do_pilot(IP, Params, State0) ->
    case ensure_socket(State0) of
        {ok, State1} ->
            {send_pilot(State1#state.socket, IP, Params), State1};
        {error, Reason, State1} ->
            myhome_log:log(error, "[myhome_wiz] udp open failed: ~p", [Reason]),
            {{error, Reason}, State1}
    end.

%% Live getPilot read from a resolved IP.
do_get_state(IP, State) ->
    {read_pilot(IP), State}.

%% Merge newly-discovered Name => IP mappings into the existing cache.
%% Discovery is lossy (a single UDP probe per host, collected in a short
%% window), so a known lamp can miss a round; merging keeps it resolvable
%% until a later scan actually reports a new IP. Static-IP lamps are not
%% cached (they resolve directly).
build_cache(Found, OldCache) ->
    ByMac = lists:foldl(fun({IP, Mac}, Acc) -> Acc#{Mac => IP} end, #{}, Found),
    maps:fold(fun
        (Name, Mac, Acc) when is_binary(Mac) ->
            case maps:find(normalize_mac(Mac), ByMac) of
                {ok, IP} -> Acc#{Name => IP};
                error    -> Acc
            end;
        (_Name, _Val, Acc) ->
            Acc
    end, OldCache, myhome_config:wiz_lamps()).

%%====================================================================
%% Internal — discovery
%%====================================================================

%% Start a discovery sweep in a separate process unless one is already
%% running. The worker owns its own UDP socket and posts the result back
%% as {discovery_result, Result}, keeping the gen_server unblocked. A
%% try/catch guarantees a result is always sent so `scanning' can never
%% get stuck on a worker crash.
start_scan(_Scope, #state{scanning = true} = State) ->
    State;
start_scan(Scope, #state{scanning = false} = State) ->
    Self = self(),
    spawn(fun() ->
        Result = try do_discover(Scope) catch Class:Reason -> {error, {Class, Reason}} end,
        Self ! {discovery_result, Result}
    end),
    State#state{scanning = true}.

%% Unicast-scan for WiZ lamps with getPilot and collect replies. Scope is
%% `full' (whole subnet from the netmask, for periodic/explicit discovery) or
%% `local24' (just our own /24, for fast on-demand resolution — the lamp
%% almost always shares the controller's /24). Returns {IP, NormalizedMac}.
do_discover(Scope) ->
    case myhome_http:get_ip() of
        {_, _, _, _} = MyIp ->
            case gen_udp:open(0, [binary, {active, true}]) of
                {ok, Sock} ->
                    Targets = discover_targets(Scope, MyIp),
                    SendErrs = lists:foldl(fun(IP, Acc) ->
                        case gen_udp:send(Sock, IP, ?WIZ_PORT, ?GETPILOT) of
                            ok -> Acc;
                            {error, _} -> Acc + 1
                        end
                    end, 0, Targets),
                    _ = SendErrs,
                    Deadline = erlang:monotonic_time(millisecond) + ?DISC_WINDOW_MS,
                    Found = collect(Sock, Deadline, #{}),
                    gen_udp:close(Sock),
                    {ok, Found};
                {error, Reason} ->
                    myhome_log:log(error, "[myhome_wiz] discovery socket failed: ~p", [Reason]),
                    {error, Reason}
            end;
        _Other ->
            {error, no_ip}
    end.

%% Build the probe target list for a scan scope. `full' covers the whole
%% subnet (from the netmask, with the directed-broadcast address appended);
%% `local24' covers only the controller's own /24.
discover_targets(full, MyIp) ->
    scan_targets(MyIp, myhome_http:get_netmask());
discover_targets(local24, {A, B, C, D}) ->
    [{A, B, C, N} || N <- lists:seq(1, 254), N =/= D].

%% Build the list of unicast probe targets for the host's subnet from the
%% IP and netmask. Excludes our own address, appends the directed-broadcast
%% address, and caps very large subnets (falling back to the local /24) so
%% the sweep stays bounded. Falls back to /24 when the mask is unknown.
scan_targets({A, B, C, D} = MyIp, {_, _, _, _} = Mask) ->
    Ip32    = ip_to_int(MyIp),
    Mask32  = ip_to_int(Mask),
    Network = Ip32 band Mask32,
    Bcast   = Network bor (bnot Mask32 band 16#FFFFFFFF),
    First   = Network + 1,
    Last    = Bcast - 1,
    case Last - First > ?DISC_MAX_HOSTS of
        true ->
            [{A, B, C, N} || N <- lists:seq(1, 254), N =/= D];
        false ->
            [int_to_ip(I) || I <- lists:seq(First, Last), I =/= Ip32]
                ++ [int_to_ip(Bcast)]
    end;
scan_targets({A, B, C, D}, _UnknownMask) ->
    [{A, B, C, N} || N <- lists:seq(1, 254), N =/= D] ++ [{A, B, C, 255}].

ip_to_int({A, B, C, D}) ->
    (A bsl 24) bor (B bsl 16) bor (C bsl 8) bor D.

int_to_ip(I) ->
    {(I bsr 24) band 255, (I bsr 16) band 255, (I bsr 8) band 255, I band 255}.

%% Collect getPilot replies until the deadline. Keyed by IP so a lamp that
%% answers more than once is recorded only once. Selective receive on the
%% discovery socket leaves unrelated gen_server messages untouched.
%% Returns a list of {IP, Mac}.
collect(Sock, Deadline, Acc) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    case Remaining =< 0 of
        true ->
            maps:to_list(Acc);
        false ->
            receive
                {udp, Sock, Addr, _Port, Packet} ->
                    case extract_mac(Packet) of
                        {ok, Mac} -> collect(Sock, Deadline, Acc#{Addr => Mac});
                        error     -> collect(Sock, Deadline, Acc)
                    end
            after Remaining ->
                maps:to_list(Acc)
            end
    end.

%% Pull the "mac":"..." value out of a getPilot reply.
extract_mac(Packet) ->
    case binary:match(Packet, <<"\"mac\":\"">>) of
        {Start, Len} ->
            Rest = binary:part(Packet, Start + Len, byte_size(Packet) - Start - Len),
            case binary:match(Rest, <<$">>) of
                {End, 1} -> {ok, normalize_mac(binary:part(Rest, 0, End))};
                _ -> error
            end;
        nomatch ->
            error
    end.

%% Lowercase hex and strip ':' so "A8:BB:50:AA:BB:CC" and "a8bb50aabbcc"
%% compare equal.
normalize_mac(Bin) ->
    normalize_mac(Bin, []).

normalize_mac(<<>>, Acc) ->
    list_to_binary(lists:reverse(Acc));
normalize_mac(<<$:, Rest/binary>>, Acc) ->
    normalize_mac(Rest, Acc);
normalize_mac(<<C, Rest/binary>>, Acc) when C >= $A, C =< $F ->
    normalize_mac(Rest, [C + 32 | Acc]);
normalize_mac(<<C, Rest/binary>>, Acc) ->
    normalize_mac(Rest, [C | Acc]).

%%====================================================================
%% Internal — control socket / sending
%%====================================================================

%% Lazily open and cache one long-lived UDP socket.
ensure_socket(#state{socket = undefined} = State) ->
    case gen_udp:open(0, [binary, {active, false}]) of
        {ok, Socket} -> {ok, State#state{socket = Socket}};
        {error, Reason} -> {error, Reason, State}
    end;
ensure_socket(#state{} = State) ->
    {ok, State}.

send_pilot(Socket, IP, Params) ->
    Payload = encode_pilot(Params),
    case gen_udp:send(Socket, IP, ?WIZ_PORT, Payload) of
        ok ->
            ok;
        {error, Reason} ->
            myhome_log:log(error, "[myhome_wiz] send to ~p failed: ~p", [IP, Reason]),
            {error, Reason}
    end.

%% Build {"method":"setPilot","params":{...}} as a binary.
%% Use iolist_to_binary/1 — list_to_binary/1 on iolists hangs in AtomVM.
encode_pilot(Params) ->
    Fields = maps:fold(fun(K, V, Acc) -> [encode_field(K, V) | Acc] end, [], Params),
    Body = lists:join($,, Fields),
    iolist_to_binary([<<"{\"method\":\"setPilot\",\"params\":{">>, Body, <<"}}">>]).

encode_field(state, true)  -> <<"\"state\":true">>;
encode_field(state, false) -> <<"\"state\":false">>;
encode_field(Key, Val) when is_integer(Val) ->
    [$", atom_to_binary(Key, utf8), <<"\":">>, integer_to_binary(Val)].

%%====================================================================
%% Internal — live state read (getPilot)
%%====================================================================

%% Send getPilot and wait for the lamp's reply. Uses a short-lived *active*
%% socket with a deadline-bounded `receive' — AtomVM does not honor passive
%% gen_udp:recv/3 timeouts, so a missing reply would otherwise hang forever.
%% setPilot acks (no "state" field) are skipped until the real reply arrives.
read_pilot(IP) ->
    case gen_udp:open(0, [binary, {active, true}]) of
        {ok, Sock} ->
            Reply = case gen_udp:send(Sock, IP, ?WIZ_PORT, ?GETPILOT) of
                ok ->
                    Deadline = erlang:monotonic_time(millisecond) + ?STATE_RECV_MS,
                    recv_pilot(Sock, Deadline);
                {error, Reason} ->
                    myhome_log:log(error, "[myhome_wiz] getPilot send to ~p failed: ~p", [IP, Reason]),
                    {error, Reason}
            end,
            gen_udp:close(Sock),
            Reply;
        {error, Reason} ->
            {error, Reason}
    end.

recv_pilot(Sock, Deadline) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    case Remaining =< 0 of
        true ->
            {error, timeout};
        false ->
            receive
                {udp, Sock, _Addr, _Port, Packet} ->
                    case binary:match(Packet, <<"\"state\":">>) of
                        nomatch -> recv_pilot(Sock, Deadline);  %% skip setPilot ack
                        _       -> {ok, parse_pilot(Packet)}
                    end
            after Remaining ->
                {error, timeout}
            end
    end.

%% Pull the fields we care about out of a getPilot reply. Missing fields are
%% simply omitted, so callers can pattern-match on what's present.
parse_pilot(Packet) ->
    Base = #{power => parse_power(Packet)},
    Base1 = put_present(brightness, find_int(Packet, <<"\"dimming\":">>), Base),
    Base2 = put_present(color_temp, find_int(Packet, <<"\"temp\":">>), Base1),
    Base3 = put_present(r, find_int(Packet, <<"\"r\":">>), Base2),
    Base4 = put_present(g, find_int(Packet, <<"\"g\":">>), Base3),
    put_present(b, find_int(Packet, <<"\"b\":">>), Base4).

put_present(_K, undefined, M) -> M;
put_present(K, V, M) -> M#{K => V}.

parse_power(Packet) ->
    case binary:match(Packet, <<"\"state\":">>) of
        {Start, Len} ->
            Rest = binary:part(Packet, Start + Len, byte_size(Packet) - Start - Len),
            case Rest of
                <<"true", _/binary>>  -> true;
                <<"false", _/binary>> -> false;
                _                     -> undefined
            end;
        nomatch ->
            undefined
    end.

%% Find Key (e.g. <<"\"dimming\":">>) in the packet and read the integer
%% that follows. Returns `undefined' if absent or not numeric.
find_int(Packet, Key) ->
    case binary:match(Packet, Key) of
        {Start, Len} ->
            Rest = binary:part(Packet, Start + Len, byte_size(Packet) - Start - Len),
            read_int(Rest, []);
        nomatch ->
            undefined
    end.

read_int(<<$-, Rest/binary>>, []) ->
    read_int(Rest, [$-]);
read_int(<<C, Rest/binary>>, Acc) when C >= $0, C =< $9 ->
    read_int(Rest, [C | Acc]);
read_int(_, []) ->
    undefined;
read_int(_, [$-]) ->
    undefined;
read_int(_, Acc) ->
    binary_to_integer(list_to_binary(lists:reverse(Acc))).

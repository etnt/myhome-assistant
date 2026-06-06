%%%-------------------------------------------------------------------
%%% @doc HTTP API handler for controlling Hue bulbs via curl.
%%%
%%% Endpoints:
%%%   GET  /api/status          — list bulbs and connection state
%%%   GET  /api/logs            — get system logs (params: level, limit)
%%%   GET  /api/scan            — get last BLE scan results
%%%   GET  /api/connections     — list active BLE connections
%%%   POST /api/scan            — trigger new BLE scan (optional: {"duration":10})
%%%   POST /api/connect         — body: {"addr":"AA:BB:CC:DD:EE:FF","addr_type":1}
%%%   POST /api/disconnect      — body: {"handle":1}
%%%   POST /api/security        — body: {"handle":1}
%%%   POST /api/discover        — run bulb discovery and pairing
%%%   POST /api/reset           — factory reset (clears config and reboots)
%%%   POST /api/bulb/1/power    — body: {"on": true}
%%%   POST /api/bulb/1/brightness — body: {"value": 200}
%%%   POST /api/bulb/1/color_temp — body: {"value": 153}
%%%   POST /api/bulb/1/state    — body: {"power":true,"brightness":200}
%%%   GET  /api/bulb/1/state    — cached state (no BLE)
%%%   POST /api/bulb/1/refresh  — live BLE GATT read (connects on-demand)
%%%
%%% Example:
%%%   curl http://<ip>:8080/api/bulb/1/power -d '{"on":true}'
%%%   curl http://<ip>:8080/api/logs?level=info&limit=50
%%% @end
%%%-------------------------------------------------------------------
-module(myhome_http_handler).

-export([handle_request/3]).

handle_request(Method, [<<"api">> | Path], Request) ->
    try
        do_handle(Method, Path, Request)
    catch
        exit:{noproc, _} ->
            static_error(<<"process not running">>);
        exit:noproc ->
            static_error(<<"process not running">>);
        exit:{timeout, _} ->
            static_error(<<"timeout - BLE busy">>);
        Class:Reason ->
            io:format("[http] crash: ~p:~p~n", [Class, Reason]),
            static_error(<<"internal error">>)
    end;
handle_request(_Method, _Path, _Request) ->
    {404, #{}, <<"Not Found">>}.

do_handle(get, [<<"status">>], _HttpRequest) ->
    Bulbs = get_bulb_status(),
    json_reply(#{status => ok, bulbs => Bulbs});

do_handle(get, [<<"events">>], _HttpRequest) ->
    %% Long-poll: subscribe to event_bus, wait up to 30s for an event
    myhome_event_bus:subscribe(self(), fun
        ({sensor_update, _}) -> true;
        ({policy_changed, _, _}) -> true;
        ({bulb_state, _, _}) -> true;
        (_) -> false
    end),
    Event = receive
        {ble_event, {sensor_update, Readings}} ->
            #{type => sensor_update, data => format_sensor_readings(Readings)};
        {ble_event, {policy_changed, Id, Enabled}} ->
            #{type => policy_changed, data => #{id => Id, enabled => Enabled}};
        {ble_event, {bulb_state, Name, BulbState}} ->
            #{type => bulb_state, data => BulbState#{name => Name}}
    after 30000 ->
        none
    end,
    myhome_event_bus:unsubscribe(self()),
    case Event of
        none -> json_reply(#{status => ok, event => null});
        _    -> json_reply(#{status => ok, event => Event})
    end;

do_handle(get, [<<"logs">>], HttpRequest) ->
    try
        Opts = parse_log_opts(HttpRequest),
        Logs = myhome_log:get_logs(Opts),
        JsonLogs = [#{seq => maps:get(seq, E),
                      ts => maps:get(ts, E),
                      level => maps:get(level, E),
                      msg => maps:get(msg, E)}
                    || E <- Logs],
        json_reply(#{status => ok, count => length(JsonLogs), logs => JsonLogs})
    catch C:R ->
        io:format("[http] logs crash: ~p:~p~n", [C, R]),
        json_reply(#{status => error, reason => iolist_to_binary(io_lib:format("~p:~p", [C, R]))})
    end;

do_handle(get, [<<"scan">>], _HttpRequest) ->
    case myhome_scanner:get_results() of
        {ok, Results} ->
            json_reply(#{status => ok, scan => Results});
        {error, Reason} ->
            json_reply(#{status => error, reason => to_bin(Reason)})
    end;

do_handle(post, [<<"scan">>], HttpRequest) ->
    #{body := Body} = HttpRequest,
    Duration = case parse_json_int(Body, <<"duration">>) of
        {ok, D} when D >= 1, D =< 30 -> D;
        _ -> 10
    end,
    case myhome_scanner:scan(Duration) of
        {ok, Count} ->
            json_reply(#{status => ok, devices_found => Count});
        {error, Reason} ->
            json_reply(#{status => error, reason => to_bin(Reason)})
    end;

do_handle(post, [<<"discover">>], _HttpRequest) ->
    case myhome_discovery:run_discovery() of
        {ok, Count} ->
            json_reply(#{status => ok, bulbs_paired => Count});
        {error, Reason} ->
            json_reply(#{status => error, reason => to_bin(Reason)})
    end;

do_handle(post, [<<"reset">>], _HttpRequest) ->
    myhome_log:log(info, "Factory reset requested via API"),
    %% Clear app config (bulb addresses)
    try esp:nvs_erase_all(myhome) catch _:_ -> ok end,
    %% Clear NimBLE bond table
    try esp:nvs_erase_all(nimble_bond) catch _:_ -> ok end,
    try esp:nvs_erase_all(nimble_cccd) catch _:_ -> ok end,
    %% Respond before restarting
    spawn(fun() -> timer:sleep(1000), esp:restart() end),
    json_reply(#{status => ok, message => <<"Resetting. Device will reboot in 1 sec.">>});

do_handle(get, [<<"policies">>], _HttpRequest) ->
    Policies = myhome_rules:list_policies(),
    json_reply(#{status => ok, policies => Policies});

do_handle(post, [<<"policies">>, PolicyId, <<"enable">>], _HttpRequest) ->
    case myhome_rules:enable_policy(binary_to_atom(PolicyId)) of
        ok -> json_reply(#{status => ok});
        {error, not_found} -> json_reply(#{status => error, reason => <<"policy not found">>})
    end;

do_handle(post, [<<"policies">>, PolicyId, <<"disable">>], _HttpRequest) ->
    case myhome_rules:disable_policy(binary_to_atom(PolicyId)) of
        ok -> json_reply(#{status => ok});
        {error, not_found} -> json_reply(#{status => error, reason => <<"policy not found">>})
    end;

do_handle(post, [<<"bulb">>, BulbNum, <<"power">>], HttpRequest) ->
    Name = bulb_name(BulbNum),
    #{body := Body} = HttpRequest,
    case parse_json_bool(Body, <<"on">>) of
        {ok, On} ->
            case myhome_hue_ble:set_power(Name, On) of
                ok -> json_reply(#{status => ok});
                {error, Reason} -> json_reply(#{status => error, reason => to_bin(Reason)})
            end;
        error ->
            {400, #{}, <<"Bad Request">>}
    end;

do_handle(post, [<<"bulb">>, BulbNum, <<"brightness">>], HttpRequest) ->
    Name = bulb_name(BulbNum),
    #{body := Body} = HttpRequest,
    case parse_json_int(Body, <<"value">>) of
        {ok, Val} when Val >= 1, Val =< 254 ->
            case myhome_hue_ble:set_brightness(Name, Val) of
                ok -> json_reply(#{status => ok});
                {error, Reason} -> json_reply(#{status => error, reason => to_bin(Reason)})
            end;
        _ ->
            {400, #{}, <<"Bad Request">>}
    end;

do_handle(post, [<<"bulb">>, BulbNum, <<"color_temp">>], HttpRequest) ->
    Name = bulb_name(BulbNum),
    #{body := Body} = HttpRequest,
    case parse_json_int(Body, <<"value">>) of
        {ok, Val} when Val >= 153, Val =< 500 ->
            case myhome_hue_ble:set_color_temp(Name, Val) of
                ok -> json_reply(#{status => ok});
                {error, Reason} -> json_reply(#{status => error, reason => to_bin(Reason)})
            end;
        _ ->
            {400, #{}, <<"Bad Request: color_temp must be 153-500 (mirek)">>}
    end;

do_handle(post, [<<"bulb">>, BulbNum, <<"color_xy">>], HttpRequest) ->
    Name = bulb_name(BulbNum),
    #{body := Body} = HttpRequest,
    case {parse_json_int(Body, <<"x">>), parse_json_int(Body, <<"y">>)} of
        {{ok, X}, {ok, Y}} when X >= 0, X =< 65535, Y >= 0, Y =< 65535 ->
            case myhome_hue_ble:set_color_xy(Name, X, Y) of
                ok -> json_reply(#{status => ok});
                {error, Reason} -> json_reply(#{status => error, reason => to_bin(Reason)})
            end;
        _ ->
            {400, #{}, <<"Bad Request: x and y must be 0-65535">>}
    end;

do_handle(get, [<<"bulb">>, BulbNum, <<"state">>], _HttpRequest) ->
    %% Return cached in-memory state (no BLE connection)
    Name = bulb_name(BulbNum),
    case myhome_hue_ble:get_state(Name) of
        {ok, State} ->
            Reply = case maps:find(color_xy, State) of
                {ok, {X, Y}} ->
                    maps:remove(color_xy, State#{status => ok, color_x => X, color_y => Y});
                {ok, undefined} ->
                    maps:remove(color_xy, State#{status => ok});
                error ->
                    State#{status => ok}
            end,
            json_reply(Reply);
        {error, Reason} ->
            json_reply(#{status => error, reason => to_bin(Reason)})
    end;

do_handle(post, [<<"bulb">>, BulbNum, <<"refresh">>], _HttpRequest) ->
    %% Live BLE read — connects on-demand to read actual GATT values
    Name = bulb_name(BulbNum),
    case myhome_hue_ble:read_state(Name) of
        {ok, State} ->
            Reply = case maps:find(color_xy, State) of
                {ok, {X, Y}} ->
                    maps:remove(color_xy, State#{status => ok, color_x => X, color_y => Y});
                {ok, undefined} ->
                    maps:remove(color_xy, State#{status => ok});
                error ->
                    State#{status => ok}
            end,
            json_reply(Reply);
        {error, Reason} ->
            json_reply(#{status => error, reason => to_bin(Reason)})
    end;

do_handle(post, [<<"bulb">>, BulbNum, <<"reconnect">>], _HttpRequest) ->
    %% Clear connect cooldown and attempt a fresh connection
    Name = bulb_name(BulbNum),
    myhome_hue_ble:clear_cooldown(Name),
    myhome_log:log(info, "[~p] cooldown cleared, ready to reconnect", [Name]),
    json_reply(#{status => ok, msg => <<"cooldown cleared">>});

do_handle(post, [<<"reconnect">>], _HttpRequest) ->
    %% Clear cooldown on all bulbs
    lists:foreach(fun({_, Child, _, _}) ->
        case is_pid(Child) of
            true ->
                Name = element(2, erlang:process_info(Child, registered_name)),
                myhome_hue_ble:clear_cooldown(Name);
            false -> ok
        end
    end, supervisor:which_children(myhome_sup)),
    myhome_log:log(info, "All bulb cooldowns cleared"),
    json_reply(#{status => ok, msg => <<"all cooldowns cleared">>});

do_handle(post, [<<"bulb">>, BulbNum, <<"state">>], HttpRequest) ->
    Name = bulb_name(BulbNum),
    #{body := Body} = HttpRequest,
    Props = parse_state_body(Body),
    case Props of
        #{} when map_size(Props) > 0 ->
            case myhome_hue_ble:set_state(Name, Props) of
                ok -> json_reply(#{status => ok});
                {error, Reason} -> json_reply(#{status => error, reason => to_bin(Reason)})
            end;
        _ ->
            {400, #{}, <<"Bad Request">>}
    end;

do_handle(delete, [<<"bulb">>, BulbNum], _HttpRequest) ->
    Name = bulb_name(BulbNum),
    case myhome_discovery:remove_bulb(Name) of
        ok -> json_reply(#{status => ok, removed => atom_to_binary(Name, utf8)});
        {error, Reason} -> json_reply(#{status => error, reason => to_bin(Reason)})
    end;

do_handle(get, [<<"sensors">>], _HttpRequest) ->
    Readings = myhome_sensors:get_readings(),
    json_reply(#{status => ok, sensors => Readings});

do_handle(get, [<<"sensors">>, TypeBin], _HttpRequest) ->
    Type = binary_to_existing_atom(TypeBin, utf8),
    Readings = myhome_sensors:get_readings(),
    case maps:find(Type, Readings) of
        {ok, Data} ->
            json_reply(#{status => ok, sensor => Type, data => Data});
        error ->
            json_reply(#{status => error, reason => <<"sensor not found">>})
    end;

do_handle(get, [<<"connections">>], _HttpRequest) ->
    case myhome_ble_conn:get_connections() of
        {ok, Conns} ->
            JsonConns = [#{addr => addr_to_hex(maps:get(addr, C)),
                           handle => maps:get(handle, C),
                           state => maps:get(state, C),
                           since => maps:get(since, C)}
                         || C <- Conns],
            json_reply(#{status => ok, connections => JsonConns});
        {error, Reason} ->
            json_reply(#{status => error, reason => to_bin(Reason)})
    end;

do_handle(get, [<<"nvs">>, <<"dump">>], _HttpRequest) ->
    Map0 = #{status => ok},
    %% Dump bulb config from 'myhome' namespace
    Map1 = lists:foldl(fun(N, Acc) ->
        NS = integer_to_list(N),
        AddrKey = list_to_atom("bulb_" ++ NS ++ "_addr"),
        NameKey = list_to_atom("bulb_" ++ NS ++ "_name"),
        case try esp:nvs_get_binary(myhome, AddrKey) catch _:_ -> undefined end of
            Addr when is_binary(Addr), byte_size(Addr) =:= 6 ->
                AddrField = binary_to_atom(iolist_to_binary(["bulb_", NS, "_addr"]), utf8),
                NameField = binary_to_atom(iolist_to_binary(["bulb_", NS, "_name"]), utf8),
                Name = case try esp:nvs_get_binary(myhome, NameKey) catch _:_ -> undefined end of
                    N2 when is_binary(N2) -> N2;
                    _ -> <<"unknown">>
                end,
                Acc#{AddrField => addr_to_hex(Addr), NameField => Name};
            _ ->
                Acc
        end
    end, Map0, [1, 2, 3, 4]),
    %% Dump NimBLE bond data (peer_sec_N, our_sec_N, indices 0..2)
    Map2 = lists:foldl(fun(N, Acc) ->
        NS = integer_to_list(N),
        PeerKey = list_to_atom("peer_sec_" ++ NS),
        OurKey = list_to_atom("our_sec_" ++ NS),
        Acc1 = case try esp:nvs_get_binary(nimble_bond, PeerKey) catch _:_ -> undefined end of
            PVal when is_binary(PVal), byte_size(PVal) > 0 ->
                PField = binary_to_atom(iolist_to_binary(["bond_peer_sec_", NS]), utf8),
                Acc#{PField => bin_to_hex(PVal)};
            _ -> Acc
        end,
        case try esp:nvs_get_binary(nimble_bond, OurKey) catch _:_ -> undefined end of
            OVal when is_binary(OVal), byte_size(OVal) > 0 ->
                OField = binary_to_atom(iolist_to_binary(["bond_our_sec_", NS]), utf8),
                Acc1#{OField => bin_to_hex(OVal)};
            _ -> Acc1
        end
    end, Map1, [0, 1, 2]),
    %% Dump local IRK
    Map3 = case try esp:nvs_get_binary(nimble_bond, local_irk) catch _:_ -> undefined end of
        Irk when is_binary(Irk), byte_size(Irk) > 0 ->
            Map2#{bond_local_irk => bin_to_hex(Irk)};
        _ -> Map2
    end,
    %% Dump NimBLE CCCD data (indices 0..7)
    Map4 = lists:foldl(fun(N, Acc) ->
        NS = integer_to_list(N),
        CccdKey = list_to_atom("cccd_" ++ NS),
        case try esp:nvs_get_binary(nimble_cccd, CccdKey) catch _:_ -> undefined end of
            CVal when is_binary(CVal), byte_size(CVal) > 0 ->
                CField = binary_to_atom(iolist_to_binary(["cccd_", NS]), utf8),
                Acc#{CField => bin_to_hex(CVal)};
            _ -> Acc
        end
    end, Map3, [0, 1, 2, 3, 4, 5, 6, 7]),
    json_reply(Map4);

do_handle(post, [<<"nvs">>, <<"restore">>], HttpRequest) ->
    #{body := Body} = HttpRequest,
    %% Restore bulb config
    Restored = lists:filtermap(fun(N) ->
        NS = integer_to_list(N),
        AddrField = iolist_to_binary(["bulb_", NS, "_addr"]),
        NameField = iolist_to_binary(["bulb_", NS, "_name"]),
        case parse_json_string(Body, AddrField) of
            {ok, AddrHex} ->
                case hex_to_addr(AddrHex) of
                    {ok, Addr} ->
                        AddrKey = list_to_atom("bulb_" ++ NS ++ "_addr"),
                        NameKey = list_to_atom("bulb_" ++ NS ++ "_name"),
                        esp:nvs_set_binary(myhome, AddrKey, Addr),
                        case parse_json_string(Body, NameField) of
                            {ok, DispName} ->
                                esp:nvs_set_binary(myhome, NameKey, DispName);
                            _ ->
                                esp:nvs_set_binary(myhome, NameKey, <<"Hue Bulb">>)
                        end,
                        {true, N};
                    _ -> false
                end;
            _ -> false
        end
    end, [1, 2, 3, 4]),
    %% Restore NimBLE bond data
    BondCount = lists:foldl(fun(N, Cnt) ->
        NS = integer_to_list(N),
        PeerField = iolist_to_binary(["bond_peer_sec_", NS]),
        OurField = iolist_to_binary(["bond_our_sec_", NS]),
        C1 = case parse_json_string(Body, PeerField) of
            {ok, PHex} ->
                PeerKey = list_to_atom("peer_sec_" ++ NS),
                esp:nvs_set_binary(nimble_bond, PeerKey, hex_to_bin(PHex)),
                1;
            _ -> 0
        end,
        C2 = case parse_json_string(Body, OurField) of
            {ok, OHex} ->
                OurKey = list_to_atom("our_sec_" ++ NS),
                esp:nvs_set_binary(nimble_bond, OurKey, hex_to_bin(OHex)),
                1;
            _ -> 0
        end,
        Cnt + C1 + C2
    end, 0, [0, 1, 2]),
    %% Restore local IRK
    BondCount2 = case parse_json_string(Body, <<"bond_local_irk">>) of
        {ok, IrkHex} ->
            esp:nvs_set_binary(nimble_bond, local_irk, hex_to_bin(IrkHex)),
            BondCount + 1;
        _ -> BondCount
    end,
    %% Restore CCCD data
    CccdCount = lists:foldl(fun(N, Cnt) ->
        NS = integer_to_list(N),
        CccdField = iolist_to_binary(["cccd_", NS]),
        case parse_json_string(Body, CccdField) of
            {ok, CHex} ->
                CccdKey = list_to_atom("cccd_" ++ NS),
                esp:nvs_set_binary(nimble_cccd, CccdKey, hex_to_bin(CHex)),
                Cnt + 1;
            _ -> Cnt
        end
    end, 0, [0, 1, 2, 3, 4, 5, 6, 7]),
    json_reply(#{status => ok, restored_slots => Restored,
                 bond_keys => BondCount2, cccd_keys => CccdCount});

do_handle(post, [<<"connect">>], HttpRequest) ->
    #{body := Body} = HttpRequest,
    case parse_json_string(Body, <<"addr">>) of
        {ok, AddrHex} ->
            case hex_to_addr(AddrHex) of
                {ok, Addr} ->
                    AddrType = case parse_json_int(Body, <<"addr_type">>) of
                        {ok, T} when T >= 0, T =< 3 -> T;
                        _ -> 1  %% default: random static
                    end,
                    case myhome_ble_conn:connect(Addr, AddrType) of
                        ok ->
                            json_reply(#{status => ok, message => <<"connecting">>});
                        {error, Reason} ->
                            json_reply(#{status => error, reason => to_bin(Reason)})
                    end;
                error ->
                    {400, #{}, <<"Bad Request">>}
            end;
        error ->
            {400, #{}, <<"Bad Request">>}
    end;

do_handle(post, [<<"disconnect">>], HttpRequest) ->
    #{body := Body} = HttpRequest,
    case parse_json_int(Body, <<"handle">>) of
        {ok, Handle} ->
            case myhome_ble_conn:disconnect(Handle) of
                ok ->
                    json_reply(#{status => ok});
                {error, Reason} ->
                    json_reply(#{status => error, reason => to_bin(Reason)})
            end;
        _ ->
            {400, #{}, <<"Bad Request">>}
    end;

do_handle(post, [<<"security">>], HttpRequest) ->
    #{body := Body} = HttpRequest,
    case parse_json_int(Body, <<"handle">>) of
        {ok, Handle} ->
            case myhome_ble_conn:security(Handle) of
                ok ->
                    json_reply(#{status => ok, message => <<"security initiated">>});
                {error, Reason} ->
                    json_reply(#{status => error, reason => to_bin(Reason)})
            end;
        _ ->
            {400, #{}, <<"Bad Request">>}
    end;

do_handle(_Method, _Path, _HttpRequest) ->
    {404, #{}, <<"Not Found">>}.

%%====================================================================
%% Internal
%%====================================================================

bulb_name(<<"1">>) -> bulb_1;
bulb_name(<<"2">>) -> bulb_2;
bulb_name(<<"3">>) -> bulb_3;
bulb_name(<<"4">>) -> bulb_4;
bulb_name(_) -> bulb_1.

get_bulb_status() ->
    lists:filtermap(fun(N) ->
        Name = list_to_atom("bulb_" ++ integer_to_list(N)),
        case whereis(Name) of
            undefined -> false;
            _Pid ->
                Result = try myhome_hue_ble:get_state(Name)
                         catch C2:R2 ->
                             io:format("[http] get_state(~p) crash: ~p:~p~n", [Name, C2, R2]),
                             {error, crashed}
                         end,
                case Result of
                    {ok, State} -> {true, State#{name => Name}};
                    _ -> {true, #{name => Name, connected => false}}
                end
        end
    end, [1, 2, 3, 4]).

%% Minimal JSON parsing — AtomVM doesn't have a JSON library built-in
%% These parse simple single-key JSON bodies like {"on":true} or {"value":123}

parse_json_bool(Body, Key) ->
    case find_json_value(Body, Key) of
        <<"true">> -> {ok, true};
        <<"false">> -> {ok, false};
        _ -> error
    end.

parse_json_int(Body, Key) ->
    case find_json_value(Body, Key) of
        error -> error;
        ValBin ->
            try {ok, binary_to_integer(ValBin)}
            catch _:_ -> error
            end
    end.

parse_state_body(Body) ->
    Props0 = #{},
    Props1 = case parse_json_bool(Body, <<"power">>) of
        {ok, P} -> Props0#{power => P};
        _ -> Props0
    end,
    Props2 = case parse_json_int(Body, <<"brightness">>) of
        {ok, B} when B >= 1, B =< 254 -> Props1#{brightness => B};
        _ -> Props1
    end,
    case parse_json_int(Body, <<"color_temp">>) of
        {ok, CT} when CT >= 153, CT =< 500 -> Props2#{color_temp => CT};
        _ -> Props2
    end.

%% Find value for a key in simple JSON like {"key": value, ...}
%% Returns the value as a binary (trimmed), or 'error'
find_json_value(Body, Key) ->
    %% Search for "key": or "key" :
    Pattern = <<"\"", Key/binary, "\"">>,
    case binary:match(Body, Pattern) of
        {Start, Len} ->
            Rest = binary:part(Body, Start + Len, byte_size(Body) - Start - Len),
            %% Skip colon and whitespace
            Val = skip_colon_ws(Rest),
            extract_value(Val);
        nomatch ->
            error
    end.

skip_colon_ws(<<$:, Rest/binary>>) -> skip_ws(Rest);
skip_colon_ws(<<$ , Rest/binary>>) -> skip_colon_ws(Rest);
skip_colon_ws(<<$\t, Rest/binary>>) -> skip_colon_ws(Rest);
skip_colon_ws(_) -> <<>>.

skip_ws(<<$ , Rest/binary>>) -> skip_ws(Rest);
skip_ws(<<$\t, Rest/binary>>) -> skip_ws(Rest);
skip_ws(Rest) -> Rest.

extract_value(<<>>) -> error;
extract_value(<<"true", _/binary>>) -> <<"true">>;
extract_value(<<"false", _/binary>>) -> <<"false">>;
extract_value(<<"null", _/binary>>) -> <<"null">>;
extract_value(<<$", _/binary>>) -> error; %% strings not supported yet
extract_value(Bin) ->
    %% Numeric: take digits
    take_digits(Bin, <<>>).

take_digits(<<C, Rest/binary>>, Acc) when C >= $0, C =< $9 ->
    take_digits(Rest, <<Acc/binary, C>>);
take_digits(_, <<>>) -> error;
take_digits(_, Acc) -> Acc.

to_bin(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
to_bin(Other) -> list_to_binary(io_lib:format("~p", [Other])).

%% Parse a JSON string value: {"key": "value"}
parse_json_string(Body, Key) ->
    Pattern = <<"\"", Key/binary, "\"">>,
    case binary:match(Body, Pattern) of
        {Start, Len} ->
            Rest = binary:part(Body, Start + Len, byte_size(Body) - Start - Len),
            Val = skip_colon_ws(Rest),
            case Val of
                <<$", Str/binary>> ->
                    case binary:match(Str, <<$">>) of
                        {End, 1} -> {ok, binary:part(Str, 0, End)};
                        _ -> error
                    end;
                _ -> error
            end;
        nomatch ->
            error
    end.

%% Convert "AA:BB:CC:DD:EE:FF" or "AABBCCDDEEFF" to 6-byte binary
hex_to_addr(Hex) when byte_size(Hex) =:= 17 ->
    %% AA:BB:CC:DD:EE:FF format
    try
        Bytes = [binary_to_integer(binary:part(Hex, I, 2), 16)
                 || I <- [0, 3, 6, 9, 12, 15]],
        {ok, list_to_binary(Bytes)}
    catch _:_ -> error
    end;
hex_to_addr(Hex) when byte_size(Hex) =:= 12 ->
    %% AABBCCDDEEFF format
    try
        Bytes = [binary_to_integer(binary:part(Hex, I, 2), 16)
                 || I <- [0, 2, 4, 6, 8, 10]],
        {ok, list_to_binary(Bytes)}
    catch _:_ -> error
    end;
hex_to_addr(_) -> error.

%% Convert 6-byte binary to "AA:BB:CC:DD:EE:FF"
addr_to_hex(<<A, B, C, D, E, F>>) ->
    iolist_to_binary(lists:join(":", [byte_to_hex(X) || X <- [A, B, C, D, E, F]]));
addr_to_hex(_) -> <<"unknown">>.

byte_to_hex(B) ->
    [hex_char(B bsr 4), hex_char(B band 16#0F)].

hex_char(N) when N < 10 -> N + $0;
hex_char(N) -> N - 10 + $A.

%% Convert arbitrary binary to hex string (no separators)
bin_to_hex(Bin) ->
    iolist_to_binary([byte_to_hex(B) || <<B>> <= Bin]).

%% Convert hex string back to binary
hex_to_bin(Hex) ->
    hex_to_bin(Hex, <<>>).
hex_to_bin(<<H, L, Rest/binary>>, Acc) ->
    Byte = (hex_val(H) bsl 4) bor hex_val(L),
    hex_to_bin(Rest, <<Acc/binary, Byte>>);
hex_to_bin(<<>>, Acc) ->
    Acc;
hex_to_bin(_, Acc) ->
    Acc.

hex_val(C) when C >= $0, C =< $9 -> C - $0;
hex_val(C) when C >= $A, C =< $F -> C - $A + 10;
hex_val(C) when C >= $a, C =< $f -> C - $a + 10.

parse_log_opts(HttpRequest) ->
    Params = maps:get(params, HttpRequest, #{}),
    Opts0 = #{},
    Opts1 = case maps:get(<<"level">>, Params, undefined) of
        undefined -> Opts0;
        LevelBin -> Opts0#{level => binary_to_atom(LevelBin, utf8)}
    end,
    case maps:get(<<"limit">>, Params, undefined) of
        undefined -> Opts1;
        LimitBin ->
            try Opts1#{limit => binary_to_integer(LimitBin)}
            catch _:_ -> Opts1
            end
    end.

json_reply(Map) ->
    Body = tiny_json:encode(Map),
    {200, #{<<"Content-Type">> => <<"application/json">>}, Body}.

%% Sensor readings are already a map of maps — pass through directly
format_sensor_readings(Readings) when is_map(Readings) -> Readings.

%% Pre-built error response — minimal allocation in the hot error path
static_error(Reason) ->
    {200, #{<<"Content-Type">> => <<"application/json">>},
     <<"{\"status\":\"error\",\"reason\":\"", Reason/binary, "\"}">>}.
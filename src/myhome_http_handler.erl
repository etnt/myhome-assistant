%%%-------------------------------------------------------------------
%%% @doc HTTP API handler for controlling Hue bulbs via curl.
%%%
%%% Endpoints:
%%%   GET  /api/status          — list bulbs and connection state
%%%   GET  /api/ble/status      — nRF52840 bridge: fw version, uptime, links
%%%   GET  /api/suptree         — Erlang supervision tree (nested JSON)
%%%   GET  /api/logs            — get system logs (params: level, limit)
%%%   GET  /api/scan            — get last BLE scan results
%%%   POST /api/scan            — trigger new BLE scan (optional: {"duration":10})
%%%   POST /api/connect         — body: {"addr":"AA:BB:CC:DD:EE:FF","addr_type":1}
%%%   POST /api/disconnect      — body: {"handle":1}
%%%   POST /api/security        — body: {"handle":1}
%%%   POST /api/discover        — run bulb discovery and pairing
%%%   POST /api/gatt/discover   — body: {"handle":0} → list characteristics
%%%   POST /api/gatt/read       — body: {"handle":0,"attr":42} → read char value
%%%   POST /api/gatt/write      — body: {"handle":0,"attr":42,"data":"01"} → write
%%%   POST /api/gatt/write_nr   — body: {"handle":0,"attr":42,"data":"01"} → write NR
%%%   POST /api/reset           — factory reset (clears config and reboots)
%%%   POST /api/bulb/1/power    — body: {"on": true}
%%%   POST /api/bulb/1/brightness — body: {"value": 200}
%%%   POST /api/bulb/1/color_temp — body: {"value": 153}
%%%   POST /api/bulb/1/state    — body: {"power":true,"brightness":200}
%%%   GET  /api/bulb/1/state    — cached state (no BLE)
%%%   POST /api/bulb/1/refresh  — live BLE GATT read (connects on-demand)
%%%   POST /api/wiz/<name>/power      — body: {"on": true}
%%%   POST /api/wiz/<name>/brightness — body: {"value": 10-100}
%%%   POST /api/wiz/<name>/color_temp — body: {"value": 2200-6500} (Kelvin)
%%%   POST /api/wiz/<name>/rgb        — body: {"r":255,"g":120,"b":0}
%%%   GET  /api/wiz/discover          — scan LAN, list lamps (ip + mac)
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
            static_error(<<"request timed out">>);
        Class:Reason ->
            io:format("[http] crash: ~p:~p~n", [Class, Reason]),
            static_error(<<"internal error">>)
    end;
handle_request(_Method, _Path, _Request) ->
    {404, #{}, <<"Not Found">>}.

do_handle(get, [<<"status">>], _HttpRequest) ->
    Bulbs = get_bulb_status(),
    json_reply(#{status => ok, bulbs => Bulbs});

do_handle(get, [<<"ble">>, <<"status">>], _HttpRequest) ->
    %% nRF52840 bridge status: firmware version, uptime, and live connections.
    case myhome_ble_i2c:status() of
        St when is_map(St) ->
            json_reply(St#{status => ok});
        Err ->
            json_reply(#{status => error, reason => to_bin(Err)})
    end;

do_handle(get, [<<"suptree">>], _HttpRequest) ->
    %% Walk the Erlang supervision tree starting at the top supervisor and
    %% return it as a nested JSON structure the UI can draw as a graph.
    json_reply(#{status => ok, tree => build_sup_tree(myhome_top_sup)});

do_handle(get, [<<"events">>], _HttpRequest) ->
    %% Long-poll: subscribe to event_bus, wait up to 30s for an event
    myhome_event_bus:subscribe(self(), fun
        ({sensor_update, _}) -> true;
        ({policy_changed, _, _}) -> true;
        ({bulb_state, _, _}) -> true;
        ({wiz_state, _, _}) -> true;
        (_) -> false
    end),
    Event = receive
        {ble_event, {sensor_update, Readings}} ->
            #{type => sensor_update, data => format_sensor_readings(Readings)};
        {ble_event, {policy_changed, Id, Enabled}} ->
            #{type => policy_changed, data => #{id => Id, enabled => Enabled}};
        {ble_event, {bulb_state, Name, BulbState}} ->
            #{type => bulb_state, data => BulbState#{name => Name}};
        {ble_event, {wiz_state, Name, WizState}} ->
            #{type => wiz_state, data => WizState#{name => to_bin(Name)}}
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

do_handle(get, [<<"scan">>], HttpRequest) ->
    case myhome_scanner:get_results() of
        {ok, Results} ->
            Params = maps:get(params, HttpRequest, #{}),
            Filtered = case maps:get(<<"named">>, Params, undefined) of
                undefined -> Results;
                _ -> Results#{results => [R || R = #{name := N} <- maps:get(results, Results, []),
                                                N =/= <<>>]}
            end,
            json_reply(#{status => ok, scan => Filtered});
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

%% --- Philips WiZ lamps (JSON-over-UDP, addressed by logical name) ---

do_handle(get, [<<"wiz">>], _HttpRequest) ->
    %% List the configured lamps (logical names) with their resolved IPs so
    %% the UI can render a control card per lamp.
    Lamps = myhome_wiz:list(),
    json_reply(#{status => ok,
                 lamps => [#{name => to_bin(maps:get(name, L)),
                             mac => wiz_mac_bin(maps:get(mac, L)),
                             ip => wiz_ip_bin(maps:get(ip, L))} || L <- Lamps]});

do_handle(get, [<<"wiz">>, <<"discover">>], _HttpRequest) ->
    case myhome_wiz:discover() of
        {ok, Lamps} ->
            json_reply(#{status => ok,
                         lamps => [#{ip => wiz_ip_bin(maps:get(ip, L)),
                                     mac => maps:get(mac, L)} || L <- Lamps]});
        {error, Reason} ->
            json_reply(#{status => error, reason => to_bin(Reason)})
    end;

do_handle(get, [<<"wiz">>, LampBin, <<"state">>], _HttpRequest) ->
    case wiz_lamp_name(LampBin) of
        {ok, Name} ->
            case myhome_wiz:get_state(Name) of
                {ok, St} -> json_reply(wiz_state_json(St));
                {error, Reason} -> json_reply(#{status => error, reason => to_bin(Reason)})
            end;
        error ->
            {404, #{}, <<"Unknown lamp">>}
    end;

do_handle(post, [<<"wiz">>, LampBin, <<"power">>], HttpRequest) ->
    with_wiz_lamp(LampBin, HttpRequest, fun(Name, Body) ->
        case parse_json_bool(Body, <<"on">>) of
            {ok, On} -> wiz_reply(myhome_wiz:set_power(Name, On));
            error -> {400, #{}, <<"Bad Request: need 'on' boolean">>}
        end
    end);

do_handle(post, [<<"wiz">>, LampBin, <<"brightness">>], HttpRequest) ->
    with_wiz_lamp(LampBin, HttpRequest, fun(Name, Body) ->
        case parse_json_int(Body, <<"value">>) of
            {ok, Val} when Val >= 10, Val =< 100 ->
                wiz_reply(myhome_wiz:set_brightness(Name, Val));
            _ -> {400, #{}, <<"Bad Request: value must be 10-100">>}
        end
    end);

do_handle(post, [<<"wiz">>, LampBin, <<"color_temp">>], HttpRequest) ->
    with_wiz_lamp(LampBin, HttpRequest, fun(Name, Body) ->
        case parse_json_int(Body, <<"value">>) of
            {ok, Val} when Val >= 2200, Val =< 6500 ->
                wiz_reply(myhome_wiz:set_color_temp(Name, Val));
            _ -> {400, #{}, <<"Bad Request: value must be 2200-6500 (Kelvin)">>}
        end
    end);

do_handle(post, [<<"wiz">>, LampBin, <<"rgb">>], HttpRequest) ->
    with_wiz_lamp(LampBin, HttpRequest, fun(Name, Body) ->
        case {parse_json_int(Body, <<"r">>), parse_json_int(Body, <<"g">>),
              parse_json_int(Body, <<"b">>)} of
            {{ok, R}, {ok, G}, {ok, B}}
              when R >= 0, R =< 255, G >= 0, G =< 255, B >= 0, B =< 255 ->
                wiz_reply(myhome_wiz:set_rgb(Name, R, G, B));
            _ -> {400, #{}, <<"Bad Request: r, g, b must be 0-255">>}
        end
    end);

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

do_handle(delete, [<<"bulb">>, BulbNum, <<"bond">>], _HttpRequest) ->
    %% Delete the BLE bond (stored LTK) for this bulb on the nRF.
    %% Use after factory-resetting the bulb to recover from a bond mismatch.
    Name = bulb_name(BulbNum),
    case myhome_hue_ble:unpair(Name) of
        ok ->
            json_reply(#{status => ok, msg => <<"bond deleted">>});
        {error, Reason} ->
            json_reply(#{status => error, reason => to_bin(Reason)})
    end;

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

do_handle(post, [<<"bulb">>, BulbNum, <<"name">>], HttpRequest) ->
    #{body := Body} = HttpRequest,
    case parse_json_string(Body, <<"name">>) of
        {ok, DisplayName} ->
            NS = binary_to_list(BulbNum),
            NameKey = list_to_atom("bulb_" ++ NS ++ "_name"),
            esp:nvs_set_binary(myhome, NameKey, DisplayName),
            json_reply(#{status => ok, name => DisplayName});
        _ ->
            {400, #{}, <<"Bad Request: missing 'name' field">>}
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
                    case myhome_ble_i2c:connect(Addr, AddrType) of
                        {ok, Handle} ->
                            json_reply(#{status => ok, handle => Handle});
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
            case myhome_ble_i2c:disconnect(Handle) of
                ok ->
                    json_reply(#{status => ok});
                {error, Reason} ->
                    json_reply(#{status => error, reason => to_bin(Reason)})
            end;
        _ ->
            {400, #{}, <<"Bad Request">>}
    end;

do_handle(post, [<<"bond">>], HttpRequest) ->
    #{body := Body} = HttpRequest,
    case parse_json_int(Body, <<"handle">>) of
        {ok, Handle} ->
            case myhome_ble_i2c:bond(Handle) of
                ok ->
                    json_reply(#{status => ok, message => <<"bonded">>});
                {error, Reason} ->
                    json_reply(#{status => error, reason => to_bin(Reason)})
            end;
        _ ->
            {400, #{}, <<"Bad Request">>}
    end;

do_handle(post, [<<"gatt">>, <<"discover">>], HttpRequest) ->
    #{body := Body} = HttpRequest,
    case parse_json_int(Body, <<"handle">>) of
        {ok, ConnH} ->
            case myhome_ble_i2c:gatt_discover(ConnH) of
                {ok, Chars} ->
                    JsonChars = [#{handle => maps:get(handle, C),
                                   properties => maps:get(properties, C),
                                   uuid => bin_to_hex(maps:get(uuid, C))}
                                 || C <- Chars],
                    json_reply(#{status => ok, characteristics => JsonChars});
                {error, Reason} ->
                    json_reply(#{status => error, reason => to_bin(Reason)})
            end;
        _ ->
            {400, #{}, <<"Bad Request: need handle">>}
    end;

do_handle(post, [<<"gatt">>, <<"read">>], HttpRequest) ->
    #{body := Body} = HttpRequest,
    case {parse_json_int(Body, <<"handle">>), parse_json_int(Body, <<"attr">>)} of
        {{ok, ConnH}, {ok, AttrH}} ->
            case myhome_ble_i2c:gatt_read(ConnH, AttrH) of
                {ok, Data} ->
                    json_reply(#{status => ok, data => bin_to_hex(Data)});
                {error, Reason} ->
                    json_reply(#{status => error, reason => to_bin(Reason)})
            end;
        _ ->
            {400, #{}, <<"Bad Request: need handle and attr">>}
    end;

do_handle(post, [<<"gatt">>, <<"write">>], HttpRequest) ->
    #{body := Body} = HttpRequest,
    case {parse_json_int(Body, <<"handle">>), parse_json_int(Body, <<"attr">>),
          parse_json_string(Body, <<"data">>)} of
        {{ok, ConnH}, {ok, AttrH}, {ok, DataHex}} ->
            Data = hex_to_bin(DataHex),
            case myhome_ble_i2c:gatt_write(ConnH, AttrH, Data) of
                ok ->
                    json_reply(#{status => ok});
                {error, Reason} ->
                    json_reply(#{status => error, reason => to_bin(Reason)})
            end;
        _ ->
            {400, #{}, <<"Bad Request: need handle, attr, data (hex)">>}
    end;

do_handle(post, [<<"gatt">>, <<"write_nr">>], HttpRequest) ->
    #{body := Body} = HttpRequest,
    case {parse_json_int(Body, <<"handle">>), parse_json_int(Body, <<"attr">>),
          parse_json_string(Body, <<"data">>)} of
        {{ok, ConnH}, {ok, AttrH}, {ok, DataHex}} ->
            Data = hex_to_bin(DataHex),
            case myhome_ble_i2c:gatt_write_nr(ConnH, AttrH, Data) of
                ok ->
                    json_reply(#{status => ok});
                {error, Reason} ->
                    json_reply(#{status => error, reason => to_bin(Reason)})
            end;
        _ ->
            {400, #{}, <<"Bad Request: need handle, attr, data (hex)">>}
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

%% Resolve a WiZ lamp path segment to a configured lamp atom, then run Fun.
%% Returns a 404 for unknown lamps so an arbitrary name never actuates one.
with_wiz_lamp(LampBin, HttpRequest, Fun) ->
    case wiz_lamp_name(LampBin) of
        {ok, Name} ->
            #{body := Body} = HttpRequest,
            Fun(Name, Body);
        error ->
            {404, #{}, <<"Unknown lamp">>}
    end.

%% Validate against myhome_config:wiz_lamps/0. binary_to_existing_atom keeps
%% the atom table bounded — valid lamp atoms already exist in the config module.
wiz_lamp_name(LampBin) ->
    %% Match the request name against the configured atoms by converting each
    %% known key to a binary. Do NOT use binary_to_existing_atom/2 here: on
    %% AtomVM the target atom may not yet be registered in the atom table
    %% (literal-pool atoms appear lazily), so it throws badarg right after a
    %% reboot and every lamp looks "unknown" until something touches the config.
    Names = maps:keys(myhome_config:wiz_lamps()),
    case lists:filter(fun(N) -> atom_to_binary(N, utf8) =:= LampBin end, Names) of
        [Name | _] -> {ok, Name};
        [] -> error
    end.

wiz_reply(ok) -> json_reply(#{status => ok});
wiz_reply({error, Reason}) -> json_reply(#{status => error, reason => to_bin(Reason)}).

%% Format an IP tuple as a binary string for JSON output.
wiz_ip_bin({A, B, C, D}) ->
    iolist_to_binary(io_lib:format("~p.~p.~p.~p", [A, B, C, D]));
wiz_ip_bin(_) -> <<"unknown">>.

%% Format a configured MAC (binary) for JSON output; static-IP lamps have none.
wiz_mac_bin(Mac) when is_binary(Mac) -> Mac;
wiz_mac_bin(_) -> <<"">>.

%% Build a JSON-friendly reply from a live getPilot state map. Only the keys
%% the lamp reported are included; RGB is emitted only when all channels are
%% present (the lamp is in color mode).
wiz_state_json(St) ->
    M0 = #{status => ok},
    M1 = wiz_put(power, maps:get(power, St, undefined), M0),
    M2 = wiz_put(brightness, maps:get(brightness, St, undefined), M1),
    M3 = wiz_put(color_temp, maps:get(color_temp, St, undefined), M2),
    case {maps:get(r, St, undefined), maps:get(g, St, undefined),
          maps:get(b, St, undefined)} of
        {R, G, B} when is_integer(R), is_integer(G), is_integer(B) ->
            M3#{r => R, g => G, b => B};
        _ ->
            M3
    end.

wiz_put(_K, undefined, M) -> M;
wiz_put(K, V, M) -> M#{K => V}.

get_bulb_status() ->
    lists:filtermap(fun(N) ->
        Name = list_to_atom("bulb_" ++ integer_to_list(N)),
        case whereis(Name) of
            undefined -> false;
            _Pid ->
                DisplayName = get_display_name(N),
                Result = try myhome_hue_ble:get_state(Name)
                         catch C2:R2 ->
                             io:format("[http] get_state(~p) crash: ~p:~p~n", [Name, C2, R2]),
                             {error, crashed}
                         end,
                case Result of
                    {ok, State} -> {true, State#{name => Name, display_name => DisplayName}};
                    _ -> {true, #{name => Name, display_name => DisplayName, connected => false}}
                end
        end
    end, [1, 2, 3, 4]).

get_display_name(N) ->
    NameKey = list_to_atom("bulb_" ++ integer_to_list(N) ++ "_name"),
    case try esp:nvs_get_binary(myhome, NameKey) catch _:_ -> undefined end of
        Val when is_binary(Val), byte_size(Val) > 0 -> Val;
        _ -> iolist_to_binary(["Bulb ", integer_to_list(N)])
    end.

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

%%====================================================================
%% Supervision tree introspection (for /api/suptree)
%%====================================================================

%% Build a nested supervision tree starting from a registered supervisor.
build_sup_tree(SupName) when is_atom(SupName) ->
    case whereis(SupName) of
        Pid when is_pid(Pid) -> sup_node(SupName, Pid);
        _ -> null
    end.

%% A supervisor node: recurse into its children.
sup_node(Id, Pid) ->
    Children = try supervisor:which_children(Pid) catch _:_ -> [] end,
    ChildNodes = lists:filtermap(fun child_node/1, Children),
    #{id => to_bin(Id),
      pid => pid_bin(Pid),
      type => supervisor,
      modules => sup_modules(Id),
      children => ChildNodes}.

%% Map a which_children/1 entry to a tree node. Skip children that are
%% currently restarting (pid =:= undefined / restarting).
child_node({Id, Pid, supervisor, _Modules}) when is_pid(Pid) ->
    {true, sup_node(Id, Pid)};
child_node({Id, Pid, worker, Modules}) when is_pid(Pid) ->
    {true, worker_node(Id, Pid, Modules)};
child_node(_) ->
    false.

%% A worker node: classify the behaviour and capture its registered name.
worker_node(Id, Pid, Modules) ->
    #{id => to_bin(Id),
      pid => pid_bin(Pid),
      type => worker,
      kind => gen_kind(Pid),
      name => reg_name(Pid),
      modules => mods_to_bin(Modules)}.

%% Identify the OTP behaviour a worker is running by its current function.
%% AtomVM's process_info/2 does not support `current_function` and raises
%% badarg, so fall back to a plain worker classification there.
gen_kind(Pid) ->
    try erlang:process_info(Pid, current_function) of
        {current_function, {gen_server, _, _}} -> <<"gen_server">>;
        {current_function, {gen_statem, _, _}} -> <<"gen_statem">>;
        {current_function, {gen_event, _, _}} -> <<"gen_event">>;
        _ -> <<"worker">>
    catch _:_ ->
        <<"worker">>
    end.

%% Registered name of a process, or null if anonymous.
reg_name(Pid) ->
    case erlang:process_info(Pid, registered_name) of
        {registered_name, Name} when is_atom(Name) -> atom_to_binary(Name, utf8);
        _ -> null
    end.

%% The supervisor child id is usually its callback module name.
sup_modules(Id) when is_atom(Id) -> [atom_to_binary(Id, utf8)];
sup_modules(_) -> [].

%% A child spec's modules can be a list or the atom `dynamic`
%% (gen_event managers with a dynamic callback set).
mods_to_bin(dynamic) -> [<<"dynamic">>];
mods_to_bin(Mods) when is_list(Mods) -> [to_bin(M) || M <- Mods];
mods_to_bin(_) -> [].

pid_bin(Pid) -> iolist_to_binary(io_lib:format("~p", [Pid])).

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
    %% AA:BB:CC:DD:EE:FF format → BLE little-endian byte order
    try
        Bytes = [binary_to_integer(binary:part(Hex, I, 2), 16)
                 || I <- [0, 3, 6, 9, 12, 15]],
        {ok, list_to_binary(lists:reverse(Bytes))}
    catch _:_ -> error
    end;
hex_to_addr(Hex) when byte_size(Hex) =:= 12 ->
    %% AABBCCDDEEFF format → BLE little-endian byte order
    try
        Bytes = [binary_to_integer(binary:part(Hex, I, 2), 16)
                 || I <- [0, 2, 4, 6, 8, 10]],
        {ok, list_to_binary(lists:reverse(Bytes))}
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
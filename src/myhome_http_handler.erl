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
            io:format("[http] noproc crash in handler~n"),
            json_reply(#{status => error, reason => <<"process not running">>});
        Class:Reason ->
            io:format("[http] handler crash: ~p:~p~n", [Class, Reason]),
            Msg = iolist_to_binary(io_lib:format("~p:~p", [Class, Reason])),
            myhome_log:log(error, "[http] handler crash: ~s", [Msg]),
            json_reply(#{status => error, reason => Msg})
    end;
handle_request(_Method, _Path, _Request) ->
    {404, #{}, <<"Not Found">>}.

do_handle(get, [<<"status">>], _HttpRequest) ->
    Bulbs = get_bulb_status(),
    json_reply(#{status => ok, bulbs => Bulbs});

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
    Name = bulb_name(BulbNum),
    case myhome_hue_ble:read_state(Name) of
        {ok, State} ->
            %% Convert color_xy tuple to separate fields
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
%%%-------------------------------------------------------------------
%%% @doc HTTP API handler for controlling Hue bulbs via curl.
%%%
%%% Endpoints:
%%%   GET  /api/status          — list bulbs and connection state
%%%   POST /api/bulb/1/power    — body: {"on": true}
%%%   POST /api/bulb/1/brightness — body: {"value": 200}
%%%   POST /api/bulb/1/color_temp — body: {"value": 153}
%%%   POST /api/bulb/1/state    — body: {"power":true,"brightness":200}
%%%
%%% Example:
%%%   curl http://<ip>:8080/api/bulb/1/power -d '{"on":true}'
%%% @end
%%%-------------------------------------------------------------------
-module(myhome_http_handler).

-behavior(httpd_api_handler).
-export([handle_api_request/4]).

handle_api_request(get, [<<"status">>], _HttpRequest, _Args) ->
    Bulbs = get_bulb_status(),
    {ok, #{status => ok, bulbs => Bulbs}};

handle_api_request(post, [<<"bulb">>, BulbNum, <<"power">>], HttpRequest, _Args) ->
    Name = bulb_name(BulbNum),
    #{body := Body} = HttpRequest,
    case parse_json_bool(Body, <<"on">>) of
        {ok, On} ->
            case myhome_hue_ble:set_power(Name, On) of
                ok -> {ok, #{status => ok}};
                {error, Reason} -> {ok, #{status => error, reason => to_bin(Reason)}}
            end;
        error ->
            bad_request
    end;

handle_api_request(post, [<<"bulb">>, BulbNum, <<"brightness">>], HttpRequest, _Args) ->
    Name = bulb_name(BulbNum),
    #{body := Body} = HttpRequest,
    case parse_json_int(Body, <<"value">>) of
        {ok, Val} when Val >= 1, Val =< 254 ->
            case myhome_hue_ble:set_brightness(Name, Val) of
                ok -> {ok, #{status => ok}};
                {error, Reason} -> {ok, #{status => error, reason => to_bin(Reason)}}
            end;
        _ ->
            bad_request
    end;

handle_api_request(post, [<<"bulb">>, BulbNum, <<"color_temp">>], HttpRequest, _Args) ->
    Name = bulb_name(BulbNum),
    #{body := Body} = HttpRequest,
    case parse_json_int(Body, <<"value">>) of
        {ok, Val} when Val >= 0, Val =< 255 ->
            case myhome_hue_ble:set_color_temp(Name, Val) of
                ok -> {ok, #{status => ok}};
                {error, Reason} -> {ok, #{status => error, reason => to_bin(Reason)}}
            end;
        _ ->
            bad_request
    end;

handle_api_request(post, [<<"bulb">>, BulbNum, <<"state">>], HttpRequest, _Args) ->
    Name = bulb_name(BulbNum),
    #{body := Body} = HttpRequest,
    Props = parse_state_body(Body),
    case Props of
        #{} when map_size(Props) > 0 ->
            case myhome_hue_ble:set_state(Name, Props) of
                ok -> {ok, #{status => ok}};
                {error, Reason} -> {ok, #{status => error, reason => to_bin(Reason)}}
            end;
        _ ->
            bad_request
    end;

handle_api_request(_Method, _Path, _HttpRequest, _Args) ->
    not_found.

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
                case catch myhome_hue_ble:get_state(Name) of
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
        {ok, CT} when CT >= 0, CT =< 255 -> Props2#{color_temp => CT};
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

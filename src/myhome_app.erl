%%%-------------------------------------------------------------------
%%% @doc MyHome Assistant application entry point.
%%% AtomVM calls start/0 as the application entry.
%%% @end
%%%-------------------------------------------------------------------
-module(myhome_app).

-export([start/0]).

start() ->
    io:format("MyHome Assistant starting...~n"),

    %% Initialize the BLE port (shared across all bulb controllers)
    case ble:open() of
        {ok, Port} ->
            io:format("BLE initialized~n"),
            Config = load_config(),
            case Config of
                [] ->
                    %% No bulbs configured — run discovery
                    io:format("No bulbs configured, starting discovery...~n"),
                    case myhome_discovery:run(Port) of
                        {ok, [_|_] = Paired} ->
                            %% Use discovered config directly (NVS save is best-effort)
                            BulbConfig = [{Name, Addr, AddrType} || {Name, Addr, AddrType, _} <- Paired],
                            start_supervisor(Port, BulbConfig);
                        _ ->
                            io:format("No bulbs paired. Restart to try again.~n"),
                            loop()
                    end;
                _ ->
                    start_supervisor(Port, Config)
            end;
        {error, Reason} ->
            io:format("BLE init failed: ~p~n", [Reason]),
            {error, Reason}
    end.

start_supervisor(Port, Config) ->
    case myhome_sup:start_link(Port, Config) of
        {ok, _Pid} ->
            io:format("MyHome Assistant running with ~p bulb(s)~n", [length(Config)]),
            start_http(),
            loop();
        {error, Reason} ->
            io:format("Failed to start supervisor: ~p~n", [Reason]),
            {error, Reason}
    end.

start_http() ->
    SSID = myhome_config:wifi_ssid(),
    PSK = myhome_config:wifi_psk(),
    io:format("Connecting to WiFi (~s)...~n", [SSID]),
    Creds = [{ssid, SSID}, {psk, PSK}],
    case network:wait_for_sta(Creds, 30000) of
        {ok, {Address, _Netmask, _Gateway}} ->
            io:format("WiFi connected! IP: ~s~n", [format_ip(Address)]),
            Port = myhome_config:http_port(),
            HttpConfig = [
                {[<<"api">>], #{handler => httpd_api_handler,
                                handler_config => #{module => myhome_http_handler, args => #{}}}}
            ],
            case httpd:start(Port, HttpConfig) of
                {ok, _} ->
                    io:format("HTTP API listening on port ~p~n", [Port]),
                    io:format("Try: curl http://~s:~p/api/status~n",
                              [format_ip(Address), Port]);
                {error, Reason} ->
                    io:format("HTTP server failed: ~p~n", [Reason])
            end;
        {error, Reason} ->
            io:format("WiFi failed: ~p (HTTP API disabled)~n", [Reason])
    end.

format_ip({A, B, C, D}) ->
    io_lib:format("~p.~p.~p.~p", [A, B, C, D]).

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

%% @doc Load bulb configuration.
%% Reads paired bulb addresses from NVS (stored by myhome_discovery).
%% Returns a list of {Name, Addr} tuples.
load_config() ->
    try load_bulbs(1, [])
    catch _:_ -> []
    end.

load_bulbs(N, Acc) when N > 4 ->
    lists:reverse(Acc);
load_bulbs(N, Acc) ->
    Name = list_to_atom("bulb_" ++ integer_to_list(N)),
    Key = list_to_binary("bulb_" ++ integer_to_list(N) ++ "_addr"),
    case esp:nvs_get_binary(myhome, Key) of
        {ok, Addr} when byte_size(Addr) =:= 6 ->
            io:format("Loaded ~p from NVS: ~s~n", [Name, format_addr(Addr)]),
            load_bulbs(N + 1, [{Name, Addr} | Acc]);
        _ ->
            lists:reverse(Acc)
    end.

format_addr(<<A, B, C, D, E, F>>) ->
    io_lib:format("~2.16.0B:~2.16.0B:~2.16.0B:~2.16.0B:~2.16.0B:~2.16.0B",
                  [F, E, D, C, B, A]).

loop() ->
    receive
        stop -> ok;
        _Msg -> loop()
    after 60000 ->
        loop()
    end.

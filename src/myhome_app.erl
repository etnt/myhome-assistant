%%%-------------------------------------------------------------------
%%% @doc MyHome Assistant application entry point.
%%% AtomVM calls start/0 as the application entry.
%%% @end
%%%-------------------------------------------------------------------
-module(myhome_app).

-export([start/0]).

start() ->
    io:format("MyHome Assistant starting...~n"),

    %% Initialize the BLE port (shared across all processes)
    case ble:open() of
        {ok, Port} ->
            io:format("BLE initialized~n"),
            %% Start supervision tree (scanner → HTTP → discovery → bulbs)
            case myhome_top_sup:start_link(Port) of
                {ok, _} ->
                    io:format("MyHome Assistant running~n"),
                    loop();
                {error, Reason} ->
                    io:format("Failed to start supervisor: ~p~n", [Reason]),
                    {error, Reason}
            end;
        {error, Reason} ->
            io:format("BLE init failed: ~p~n", [Reason]),
            {error, Reason}
    end.

loop() ->
    receive
        stop -> ok;
        _Msg -> loop()
    after 60000 ->
        loop()
    end.

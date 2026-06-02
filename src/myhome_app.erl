%%%-------------------------------------------------------------------
%%% @doc MyHome Assistant application entry point.
%%% AtomVM calls start/0 as the application entry.
%%% @end
%%%-------------------------------------------------------------------
-module(myhome_app).

-export([start/0]).

start() ->
    io:format("MyHome Assistant starting...~n"),

    case myhome_top_sup:start_link() of
        {ok, _} ->
            myhome_log:log(info, "MyHome Assistant running"),
            loop();
        {error, Reason} ->
            io:format("Failed to start supervisor: ~p~n", [Reason]),
            {error, Reason}
    end.

loop() ->
    receive
        stop -> ok;
        _Msg -> loop()
    after 60000 ->
        io:format("."),
        loop()
    end.

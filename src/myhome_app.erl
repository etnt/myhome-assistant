%%%-------------------------------------------------------------------
%%% @doc MyHome Assistant application entry point.
%%% AtomVM calls start/0 as the application entry.
%%% @end
%%%-------------------------------------------------------------------
-module(myhome_app).

-export([start/0]).

start() ->
    io:format("MyHome Assistant starting...~n"),
    print_memory_info(),

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

print_memory_info() ->
    FreeHeap = erlang:system_info(esp32_free_heap_size),
    MinFree = erlang:system_info(esp32_minimum_free_heap_size),
    LargestBlock = erlang:system_info(esp32_largest_free_block),
    io:format("MEMORY: Free=~p MinFree=~p LargestBlock=~p~n",
              [FreeHeap, MinFree, LargestBlock]).

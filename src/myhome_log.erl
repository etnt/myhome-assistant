%%%-------------------------------------------------------------------
%%% @doc In-memory log server.
%%% Stores the last N log messages in a ring buffer (queue).
%%% Messages can be retrieved via the HTTP API as JSON.
%%% Started first in the top supervisor so it captures boot messages.
%%% @end
%%%-------------------------------------------------------------------
-module(myhome_log).
-behaviour(gen_server).

-export([start_link/0]).
-export([log/3, log/2, get_logs/0, get_logs/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(MAX_ENTRIES, 100).

-record(state, {
    queue :: queue:queue(),
    count :: non_neg_integer(),
    seq :: non_neg_integer()
}).

%%====================================================================
%% Public API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec log(atom(), string(), list()) -> ok.
log(Level, Format, Args) ->
    try
        Msg = io_lib:format(Format, Args),
        gen_server:cast(?MODULE, {log, Level, iolist_to_binary(Msg)})
    catch _:_ -> ok
    end.

-spec log(atom(), string()) -> ok.
log(Level, Message) ->
    try
        gen_server:cast(?MODULE, {log, Level, iolist_to_binary(Message)})
    catch _:_ -> ok
    end.

-spec get_logs() -> [map()].
get_logs() ->
    get_logs(#{}).

-spec get_logs(map()) -> [map()].
get_logs(Opts) ->
    gen_server:call(?MODULE, {get_logs, Opts}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    {ok, #state{queue = queue:new(), count = 0, seq = 0}}.

handle_call({get_logs, Opts}, _From, State) ->
    Logs = format_logs(State, Opts),
    {reply, Logs, State};

handle_call(_Req, _From, State) ->
    {reply, ok, State}.

handle_cast({log, Level, Message}, State) ->
    #state{queue = Q, count = Count, seq = Seq} = State,
    Entry = #{
        seq => Seq + 1,
        ts => erlang:system_time(millisecond),
        level => Level,
        msg => Message
    },
    {Q2, Count2} = case Count >= ?MAX_ENTRIES of
        true ->
            {_Val, Q1} = queue:out(Q),
            {queue:in(Entry, Q1), Count};
        false ->
            {queue:in(Entry, Q), Count + 1}
    end,
    {noreply, State#state{queue = Q2, count = Count2, seq = Seq + 1}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal
%%====================================================================

format_logs(#state{queue = Q}, Opts) ->
    All = queue:to_list(Q),
    Filtered = case maps:get(level, Opts, all) of
        all -> All;
        Level -> [E || E = #{level := L} <- All, L =:= Level]
    end,
    Limit = maps:get(limit, Opts, ?MAX_ENTRIES),
    %% Return newest first: reverse, then take limit
    Limited = lists:sublist(lists:reverse(Filtered), Limit),
    Limited.

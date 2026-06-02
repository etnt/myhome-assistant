%%%-------------------------------------------------------------------
%%% @doc BLE Event Bus - Publish/Subscribe for BLE events.
%%%
%%% Lightweight event bus for multicasting BLE events (scan results,
%%% connection state changes, security events) to multiple subscribers.
%%%
%%% Supports optional filter functions and automatic cleanup of dead
%%% subscribers via process monitors.
%%% @end
%%%-------------------------------------------------------------------
-module(myhome_event_bus).
-behaviour(gen_server).

-export([start_link/0, publish/1, subscribe/1, subscribe/2, unsubscribe/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    subs = #{} :: #{pid() => #{filter => fun((term()) -> boolean()), mon => reference()}}
}).

%%====================================================================
%% API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Publish an event to all matching subscribers.
%% Non-blocking (async cast).
-spec publish(term()) -> ok.
publish(Event) ->
    gen_server:cast(?MODULE, {publish, Event}).

%% @doc Subscribe the calling process to all events.
-spec subscribe(pid()) -> ok.
subscribe(Pid) when is_pid(Pid) ->
    subscribe(Pid, fun(_) -> true end).

%% @doc Subscribe with a filter function.
%% Only events where FilterFun(Event) returns true are delivered.
-spec subscribe(pid(), fun((term()) -> boolean())) -> ok.
subscribe(Pid, FilterFun) when is_pid(Pid), is_function(FilterFun, 1) ->
    gen_server:call(?MODULE, {subscribe, Pid, FilterFun}).

%% @doc Unsubscribe a process.
-spec unsubscribe(pid()) -> ok.
unsubscribe(Pid) when is_pid(Pid) ->
    gen_server:call(?MODULE, {unsubscribe, Pid}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    {ok, #state{}}.

handle_call({subscribe, Pid, FilterFun}, _From, #state{subs = Subs} = State) ->
    case maps:is_key(Pid, Subs) of
        true ->
            %% Update filter for existing subscriber
            #{Pid := Entry} = Subs,
            NewSubs = Subs#{Pid => Entry#{filter => FilterFun}},
            {reply, ok, State#state{subs = NewSubs}};
        false ->
            Mon = erlang:monitor(process, Pid),
            NewSubs = Subs#{Pid => #{filter => FilterFun, mon => Mon}},
            {reply, ok, State#state{subs = NewSubs}}
    end;

handle_call({unsubscribe, Pid}, _From, #state{subs = Subs} = State) ->
    case maps:take(Pid, Subs) of
        {#{mon := Mon}, NewSubs} ->
            erlang:demonitor(Mon, [flush]),
            {reply, ok, State#state{subs = NewSubs}};
        error ->
            {reply, ok, State}
    end;

handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast({publish, Event}, #state{subs = Subs} = State) ->
    maps:foreach(fun(Pid, #{filter := FilterFun}) ->
        case catch FilterFun(Event) of
            true -> Pid ! {ble_event, Event};
            _ -> ok
        end
    end, Subs),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', _MonRef, process, Pid, _Reason}, #state{subs = Subs} = State) ->
    NewSubs = maps:remove(Pid, Subs),
    {noreply, State#state{subs = NewSubs}};

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

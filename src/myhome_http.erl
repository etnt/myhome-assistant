%%%-------------------------------------------------------------------
%%% @doc HTTP server manager.
%%% Connects to WiFi and starts the HTTP API server.
%%% Managed by the supervisor for automatic restart on failure.
%%% @end
%%%-------------------------------------------------------------------
-module(myhome_http).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {}).

%%====================================================================
%% Public API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
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
                              [format_ip(Address), Port]),
                    {ok, #state{}};
                {error, Reason} ->
                    io:format("HTTP server failed: ~p~n", [Reason]),
                    {stop, {http_start_failed, Reason}}
            end;
        {error, Reason} ->
            io:format("WiFi failed: ~p~n", [Reason]),
            {stop, {wifi_failed, Reason}}
    end.

handle_call(_Req, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal
%%====================================================================

format_ip({A, B, C, D}) ->
    io_lib:format("~p.~p.~p.~p", [A, B, C, D]).

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

%% Max seconds without WiFi recovery before rebooting
-define(WIFI_REBOOT_TIMEOUT_MS, 30000).

-record(state, {reboot_timer = undefined :: undefined | reference()}).

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
    myhome_log:log(info, "Connecting to WiFi (~s)...", [SSID]),
    Self = self(),
    StaConfig = [{ssid, SSID}, {psk, PSK},
                 {dhcp_hostname, "myhome-esp32"},
                 {connected, fun() -> Self ! connected end},
                 {got_ip, fun(IpInfo) -> Self ! {ok, IpInfo} end},
                 {disconnected, fun() -> Self ! disconnected end},
                 {beacon_timeout, fun() -> Self ! wifi_beacon_timeout end}],
    SntpConfig = [{host, "pool.ntp.org"},
                  {synchronized, fun(_TimeVal) ->
                      io:format("SNTP synchronized~n"),
                      myhome_log:log(info, "SNTP synchronized")
                  end}],
    Config = [{sta, StaConfig}, {sntp, SntpConfig}],
    case network:start(Config) of
        {ok, _Pid} ->
            case wait_for_ip(30000) of
                {ok, {Address, _Netmask, _Gateway}} ->
                    io:format("WiFi connected! IP: ~s~n", [format_ip(Address)]),
                    Port = myhome_config:http_port(),
                    Opts = #{cors => #{allow_origin => <<"*">>,
                                       allow_methods => <<"GET, POST, DELETE, OPTIONS">>,
                                       allow_headers => <<"Content-Type">>}},
                    case tiny_httpd:start_link(any, Port, myhome_http_handler, Opts) of
                        {ok, _} ->
                            io:format("HTTP API listening on port ~p~n", [Port]),
                            myhome_log:log(info, "HTTP API listening on port ~p", [Port]),
                            myhome_log:log(info, "Try: curl http://~s:~p/api/status",
                                      [format_ip(Address), Port]),
                            {ok, #state{}};
                        {error, Reason} ->
                            io:format("HTTP server FAILED: ~p~n", [Reason]),
                            myhome_log:log(error, "HTTP server failed: ~p", [Reason]),
                            {stop, {http_start_failed, Reason}}
                    end;
                {error, timeout} ->
                    myhome_log:log(error, "WiFi timeout"),
                    {stop, {wifi_failed, timeout}}
            end;
        {error, Reason} ->
            myhome_log:log(error, "WiFi failed: ~p", [Reason]),
            {stop, {wifi_failed, Reason}}
    end.

handle_call(_Req, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(wifi_beacon_timeout, State) ->
    %% Beacon timeouts are expected during BLE radio activity — just log.
    %% Only actual WiFi disconnect should trigger reboot logic.
    myhome_log:log(warning, "WiFi beacon timeout (BLE radio contention?)"),
    {noreply, State};

handle_info(disconnected, #state{reboot_timer = undefined} = State) ->
    myhome_log:log(warning, "WiFi disconnected - starting reboot timer (~ps)",
                   [?WIFI_REBOOT_TIMEOUT_MS div 1000]),
    TRef = erlang:send_after(?WIFI_REBOOT_TIMEOUT_MS, self(), wifi_reboot),
    %% Attempt to reconnect
    network:sta_connect(),
    {noreply, State#state{reboot_timer = TRef}};

handle_info(disconnected, State) ->
    myhome_log:log(warning, "WiFi disconnected (reboot timer active), reconnecting..."),
    network:sta_connect(),
    {noreply, State};

handle_info(connected, #state{reboot_timer = TRef} = State) ->
    myhome_log:log(info, "WiFi recovered"),
    cancel_timer(TRef),
    {noreply, State#state{reboot_timer = undefined}};

handle_info(wifi_reboot, _State) ->
    myhome_log:log(error, "WiFi not recovered after ~ps - rebooting!",
                   [?WIFI_REBOOT_TIMEOUT_MS div 1000]),
    esp:restart(),
    {noreply, #state{}};

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal
%%====================================================================

wait_for_ip(Timeout) ->
    receive
        {ok, IpInfo} -> {ok, IpInfo}
    after Timeout ->
        {error, timeout}
    end.

cancel_timer(undefined) -> ok;
cancel_timer(TRef) -> erlang:cancel_timer(TRef).

format_ip({A, B, C, D}) ->
    io_lib:format("~p.~p.~p.~p", [A, B, C, D]).

%%%-------------------------------------------------------------------
%%% @doc Secondary supervisor.
%%% Starts HTTP and discovery as static children.
%%% Bulb gen_servers are added dynamically by myhome_discovery.
%%% @end
%%%-------------------------------------------------------------------
-module(myhome_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    ScannerSpec = #{
        id => myhome_scanner,
        start => {myhome_scanner, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker
    },

    HttpSpec = #{
        id => myhome_http,
        start => {myhome_http, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker
    },

    DiscoverySpec = #{
        id => myhome_discovery,
        start => {myhome_discovery, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker
    },

    SensorsSpec = #{
        id => myhome_sensors,
        start => {myhome_sensors, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker
    },

    RulesSpec = #{
        id => myhome_rules,
        start => {myhome_rules, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker
    },

    LcdSpec = #{
        id => myhome_lcd,
        start => {myhome_lcd, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker
    },

    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 60
    },

    {ok, {SupFlags, [ScannerSpec, HttpSpec, DiscoverySpec, SensorsSpec, RulesSpec, LcdSpec]}}.

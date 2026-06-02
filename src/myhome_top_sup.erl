%%%-------------------------------------------------------------------
%%% @doc Top-level supervisor.
%%% Starts the BLE scanner first, then the secondary supervisor.
%%% Uses rest_for_one so that if the scanner crashes, the secondary
%%% supervisor is also restarted (correct dependency order).
%%% @end
%%%-------------------------------------------------------------------
-module(myhome_top_sup).
-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

-spec start_link(port()) -> {ok, pid()} | {error, term()}.
start_link(Port) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, Port).

init(Port) ->
    LogSpec = #{
        id => myhome_log,
        start => {myhome_log, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker
    },

    ScannerSpec = #{
        id => myhome_scanner,
        start => {myhome_scanner, start_link, [Port]},
        restart => permanent,
        shutdown => 5000,
        type => worker
    },

    SubSupSpec = #{
        id => myhome_sup,
        start => {myhome_sup, start_link, [Port]},
        restart => permanent,
        shutdown => infinity,
        type => supervisor
    },

    SupFlags = #{
        strategy => rest_for_one,
        intensity => 5,
        period => 60
    },

    {ok, {SupFlags, [LogSpec, ScannerSpec, SubSupSpec]}}.

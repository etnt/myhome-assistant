%%%-------------------------------------------------------------------
%%% @doc Top-level supervisor.
%%% Starts: log → ble (port owner) → event_bus → scanner → ble_conn → sub_sup.
%%% Uses rest_for_one so crashing an early child restarts all later ones.
%%% @end
%%%-------------------------------------------------------------------
-module(myhome_top_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    LogSpec = #{
        id => myhome_log,
        start => {myhome_log, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker
    },

    BleSpec = #{
        id => ble,
        start => {ble, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker
    },

    EventBusSpec = #{
        id => myhome_event_bus,
        start => {myhome_event_bus, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker
    },

    SubSupSpec = #{
        id => myhome_sup,
        start => {myhome_sup, start_link, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor
    },

    BleI2CSpec = #{
        id => myhome_ble_i2c,
        start => {myhome_ble_i2c, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker
    },

    SupFlags = #{
        strategy => rest_for_one,
        intensity => 5,
        period => 60
    },

    {ok, {SupFlags, [LogSpec, BleSpec, EventBusSpec, BleI2CSpec, SubSupSpec]}}.

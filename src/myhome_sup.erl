%%%-------------------------------------------------------------------
%%% @doc MyHome supervisor.
%%% Supervises one myhome_hue_ble gen_server per configured bulb.
%%% @end
%%%-------------------------------------------------------------------
-module(myhome_sup).
-behaviour(supervisor).

-export([start_link/2]).
-export([init/1]).

-spec start_link(port(), [{atom(), binary(), integer()}]) -> {ok, pid()} | {error, term()}.
start_link(Port, Config) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, {Port, Config}).

init({Port, Config}) ->
    ChildSpecs = lists:map(fun({Name, Addr, AddrType}) ->
        #{
            id => Name,
            start => {myhome_hue_ble, start_link, [Port, Addr, AddrType, Name]},
            restart => permanent,
            shutdown => 5000,
            type => worker
        }
    end, Config),

    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 60
    },

    {ok, {SupFlags, ChildSpecs}}.

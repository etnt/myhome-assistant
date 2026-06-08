%%%-------------------------------------------------------------------
%%% @doc Sensor manager — polls I2C sensors and caches readings.
%%%
%%% Reads configuration from myhome_config:sensors/0, initialises
%%% each declared sensor, and polls them at the configured interval.
%%% Latest readings are available via get_readings/0.
%%% @end
%%%-------------------------------------------------------------------
-module(myhome_sensors).
-behaviour(gen_server).

-export([start_link/0, get_readings/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    i2c,
    devices = [],       %% [{Type :: atom(), Handle :: term()}]
    readings = #{},     %% #{atom() => map()}
    interval            %% poll interval in ms
}).

%%====================================================================
%% API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec get_readings() -> map().
get_readings() ->
    gen_server:call(?MODULE, get_readings).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    #{devices := DevConfs, poll_interval_ms := Interval} =
        myhome_config:sensors(),
    io:format("[sensors] Getting shared I2C bus from myhome_ble_i2c~n"),
    I2C = myhome_ble_i2c:get_i2c(),
    io:format("[sensors] I2C bus opened, initing ~p device(s)~n", [length(DevConfs)]),
    Devices = init_devices(I2C, DevConfs),
    io:format("[sensors] ~p device(s) ready~n", [length(Devices)]),
    erlang:send_after(1000, self(), poll),
    {ok, #state{i2c = I2C, devices = Devices, interval = Interval}}.

handle_call(get_readings, _From, #state{readings = Readings} = State) ->
    {reply, Readings, State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(poll, #state{devices = Devices, interval = Interval} = State) ->
    Readings = poll_devices(Devices),
    case Readings =/= State#state.readings of
        true ->
            myhome_event_bus:publish({sensor_update, Readings});
        false ->
            ok
    end,
    erlang:send_after(Interval, self(), poll),
    {noreply, State#state{readings = Readings}};
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal: device initialisation
%%====================================================================

init_devices(I2C, DevConfs) ->
    lists:filtermap(fun(#{type := Type, addr := Addr}) ->
        io:format("[sensors] Trying ~p at 0x~.16B~n", [Type, Addr]),
        try init_device(I2C, Type, Addr) of
            {ok, Handle} ->
                io:format("[sensors] ~p ready~n", [Type]),
                {true, {Type, Handle}};
            {error, Reason} ->
                io:format("[sensors] ~p failed: ~p~n", [Type, Reason]),
                false
        catch
            _:Err ->
                io:format("[sensors] ~p crashed: ~p~n", [Type, Err]),
                false
        end
    end, DevConfs).

init_device(I2C, bme680, Addr) ->
    bme680:init(I2C, Addr);
init_device(I2C, sgp30, _Addr) ->
    sgp30:init(I2C);
init_device(I2C, veml6030, Addr) ->
    {ok, veml6030:init(I2C, Addr)};
init_device(_I2C, Type, _Addr) ->
    {error, {unknown_sensor, Type}}.

%%====================================================================
%% Internal: polling
%%====================================================================

poll_devices(Devices) ->
    lists:foldl(fun({Type, Handle}, Acc) ->
        try read_device(Type, Handle) of
            {ok, Reading} ->
                Acc#{Type => Reading};
            {error, Reason} ->
                myhome_log:log(error, "[sensors] ~p read failed: ~p", [Type, Reason]),
                Acc
        catch
            _:Err ->
                myhome_log:log(error, "[sensors] ~p read crashed: ~p", [Type, Err]),
                Acc
        end
    end, #{}, Devices).

read_device(bme680, Handle) ->
    case bme680:read_gas(Handle) of
        {ok, Temp, Press, Hum, Gas} ->
            {ok, #{temperature_c => Temp,
                   pressure_hpa => Press,
                   humidity_pct => Hum,
                   gas_ohms => Gas}};
        {error, _} = Err ->
            Err
    end;
read_device(sgp30, Handle) ->
    case sgp30:measure(Handle) of
        {ok, ECO2, TVOC} ->
            {ok, #{eco2_ppm => ECO2, tvoc_ppb => TVOC}};
        {error, _} = Err ->
            Err
    end;
read_device(veml6030, Handle) ->
    case veml6030:read_lux(Handle) of
        {ok, Lux} ->
            case veml6030:read_white(Handle) of
                {ok, White} ->
                    {ok, #{lux => Lux, white_lux => White}};
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

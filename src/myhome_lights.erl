%%%-------------------------------------------------------------------
%%% @doc Unified light control for automation policies.
%%%
%%% Applies a single logical light state to every controllable light —
%%% Philips Hue (BLE) bulbs and Philips WiZ (WiFi/UDP) lamps alike — so
%%% one policy action drives both. All control logic lives here (a
%%% version-controlled module); myhome_config holds only configuration
%%% and declarative policies that delegate to set_all/1.
%%%
%%% Props use the Hue convention:
%%%   power       :: boolean()
%%%   brightness  :: 1..254
%%%   color_temp  :: 153..500 (mirek)
%%% WiZ values are translated to its native units (dimming %, Kelvin).
%%% @end
%%%-------------------------------------------------------------------
-module(myhome_lights).

-export([set_all/1, bulb_names/0]).

%% @doc Apply Props to every Hue bulb and every configured WiZ lamp.
-spec set_all(map()) -> ok.
set_all(Props) ->
    set_bulbs_sequential(bulb_names(), Props),
    set_wiz_sequential(maps:keys(myhome_config:wiz_lamps()), Props).

%% @doc Registered Hue bulb process names, discovered from the supervisor.
-spec bulb_names() -> [atom()].
bulb_names() ->
    Children = supervisor:which_children(myhome_sup),
    [Id || {Id, Pid, worker, _} <- Children,
           is_pid(Pid),
           is_atom(Id),
           is_bulb_name(Id)].

is_bulb_name(Name) ->
    case atom_to_list(Name) of
        "bulb_" ++ _ -> true;
        _ -> false
    end.

%% Hue bulbs share the BLE bridge, so leave a 2s gap between writes
%% to reduce contention.
set_bulbs_sequential([], _Props) -> ok;
set_bulbs_sequential([Bulb], Props) ->
    myhome_hue_ble:set_state(Bulb, Props);
set_bulbs_sequential([Bulb | Rest], Props) ->
    myhome_hue_ble:set_state(Bulb, Props),
    timer:sleep(2000),
    set_bulbs_sequential(Rest, Props).

%% WiZ lamps are fire-and-forget UDP, so no inter-lamp delay is needed.
set_wiz_sequential([], _Props) -> ok;
set_wiz_sequential([Name | Rest], Props) ->
    set_wiz(Name, Props),
    set_wiz_sequential(Rest, Props).

%% Translate Hue-convention Props to WiZ commands. When turning off, only send
%% power off (a dimming/temp packet would turn the lamp back on); otherwise apply
%% brightness/temp and then ensure the lamp is on.
set_wiz(Name, Props) ->
    case maps:find(power, Props) of
        {ok, false} ->
            myhome_wiz:set_power(Name, false);
        PowerResult ->
            case maps:find(brightness, Props) of
                {ok, Bri} -> myhome_wiz:set_brightness(Name, hue_bri_to_wiz(Bri));
                error -> ok
            end,
            case maps:find(color_temp, Props) of
                {ok, Mirek} -> myhome_wiz:set_color_temp(Name, mirek_to_kelvin(Mirek));
                error -> ok
            end,
            case PowerResult of
                {ok, true} -> myhome_wiz:set_power(Name, true);
                _ -> ok
            end
    end.

%% Hue brightness (1..254) -> WiZ dimming percentage (10..100).
hue_bri_to_wiz(Bri) ->
    clamp(round(Bri * 100 / 254), 10, 100).

%% Hue color temperature in mirek (153..500) -> WiZ Kelvin (2200..6500).
mirek_to_kelvin(Mirek) when Mirek > 0 ->
    clamp(round(1000000 / Mirek), 2200, 6500).

clamp(V, Lo, _Hi) when V < Lo -> Lo;
clamp(V, _Lo, Hi) when V > Hi -> Hi;
clamp(V, _Lo, _Hi) -> V.

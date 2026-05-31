%%%-------------------------------------------------------------------
%%% @doc BLE discovery and pairing for Hue bulbs.
%%%
%%% One-time setup flow:
%%% 1. Scan for BLE devices (look for "Hue" in name or Hue service UUID)
%%% 2. Display discovered bulbs on serial console
%%% 3. Connect and pair with each discovered Hue bulb
%%% 4. Store bonded addresses in NVS for auto-reconnect
%%%
%%% Usage from console:
%%%   {ok, Port} = ble:start().
%%%   myhome_discovery:run(Port).
%%% @end
%%%-------------------------------------------------------------------
-module(myhome_discovery).

-export([run/1, scan/1, scan/2, pair/3]).

%% Hue bulbs advertise with service UUID 0000fe0f-0000-1000-8000-00805f9b34fb
%% and typically have "Hue" in their local name.

-define(SCAN_DURATION, 15).  %% seconds

%%====================================================================
%% Public API
%%====================================================================

%% @doc Run the full discovery and pairing flow interactively.
%% Scans for Hue bulbs, displays them, then attempts to pair with each.
%% The user should power-cycle each bulb before running this to enter pairing mode.
-spec run(port()) -> {ok, [{atom(), binary()}]} | {error, term()}.
run(Port) ->
    io:format("~n=== Hue Bulb Discovery ===~n"),
    io:format("Make sure your Hue bulbs are in pairing mode~n"),
    io:format("(power-cycle the bulb -- it stays in pairing mode for 30s)~n~n"),
    io:format("Scanning for ~p seconds...~n", [?SCAN_DURATION]),

    case scan(Port, ?SCAN_DURATION) of
        {ok, []} ->
            io:format("No Hue bulbs found.~n"),
            io:format("Tips: ensure bulbs are powered on and in pairing mode.~n"),
            {ok, []};
        {ok, Bulbs} ->
            io:format("~nFound ~p Hue bulb(s):~n", [length(Bulbs)]),
            print_bulbs(Bulbs),
            io:format("~nAttempting to pair with each bulb...~n"),
            Paired = pair_all(Port, Bulbs),
            io:format("~n=== Pairing complete ===~n"),
            print_paired(Paired),
            save_config(Paired),
            {ok, Paired};
        {error, Reason} ->
            io:format("Scan failed: ~p~n", [Reason]),
            {error, Reason}
    end.

%% @doc Scan for Hue bulbs. Returns a list of discovered devices.
-spec scan(port()) -> {ok, [map()]} | {error, term()}.
scan(Port) ->
    scan(Port, ?SCAN_DURATION).

-spec scan(port(), pos_integer()) -> {ok, [map()]} | {error, term()}.
scan(Port, Duration) ->
    case ble:scan_start(Port, Duration) of
        ok ->
            %% Wait for scan to complete
            timer:sleep((Duration + 1) * 1000),
            case ble:scan_results(Port) of
                {ok, Results} ->
                    HueBulbs = filter_hue_bulbs(Results),
                    {ok, HueBulbs};
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

%% @doc Pair with a specific bulb by address.
%% The bulb must be in pairing mode (power-cycled within last 30s).
%% Returns ok if connection + bonding succeeds.
-spec pair(port(), binary(), integer()) -> ok | {error, term()}.
pair(Port, Addr, AddrType) ->
    io:format("  Connecting to ~s...", [format_addr(Addr)]),
    case ble:connect(Port, Addr, AddrType) of
        {ok, Idx} ->
            %% Wait for bonding to complete (initiated automatically in ble_port.c)
            timer:sleep(2000),
            case ble:conn_state(Port, Idx) of
                {ok, bonded} ->
                    io:format(" bonded!~n"),
                    %% Disconnect — we'll reconnect from the app
                    ble:disconnect(Port, Idx),
                    ok;
                {ok, connected} ->
                    %% Connected but not yet bonded — might still work
                    io:format(" connected (bond pending)~n"),
                    ble:disconnect(Port, Idx),
                    ok;
                {ok, Other} ->
                    io:format(" unexpected state: ~p~n", [Other]),
                    ble:disconnect(Port, Idx),
                    {error, {unexpected_state, Other}}
            end;
        {error, Reason} ->
            io:format(" failed: ~p~n", [Reason]),
            {error, Reason}
    end.

%%====================================================================
%% Internal
%%====================================================================

%% Filter scan results to only Hue bulbs.
%% Hue bulbs typically advertise with "Hue" in their name.
filter_hue_bulbs(Results) ->
    lists:filter(fun(#{name := Name}) ->
        is_hue_name(Name);
    (_) ->
        false
    end, Results).

is_hue_name(<<>>) -> false;
is_hue_name(Name) when is_binary(Name) ->
    %% Check if name contains "Hue" (case-insensitive)
    Lower = to_lower(Name),
    binary:match(Lower, <<"hue">>) =/= nomatch;
is_hue_name(_) -> false.

to_lower(Bin) ->
    << <<(lower_char(C))>> || <<C>> <= Bin >>.

lower_char(C) when C >= $A, C =< $Z -> C + 32;
lower_char(C) -> C.

pair_all(Port, Bulbs) ->
    pair_all(Port, Bulbs, 1, []).

pair_all(_Port, [], _N, Acc) ->
    lists:reverse(Acc);
pair_all(Port, [#{addr := Addr, addr_type := AddrType, name := Name} | Rest], N, Acc) ->
    BulbName = list_to_atom("bulb_" ++ integer_to_list(N)),
    case pair(Port, Addr, AddrType) of
        ok ->
            Entry = {BulbName, Addr, AddrType, Name},
            pair_all(Port, Rest, N + 1, [Entry | Acc]);
        {error, _} ->
            %% Skip failed bulbs
            pair_all(Port, Rest, N + 1, Acc)
    end.

%% Store paired bulb config in NVS
save_config(Paired) ->
    lists:foreach(fun({Name, Addr, _AddrType, DisplayName}) ->
        Key = atom_to_list(Name) ++ "_addr",
        NameKey = atom_to_list(Name) ++ "_name",
        %% AtomVM NVS API — best effort
        try
            esp:nvs_set_binary(myhome, list_to_binary(Key), Addr),
            esp:nvs_set_binary(myhome, list_to_binary(NameKey), DisplayName),
            io:format("Saved ~p (~s) to NVS~n", [Name, DisplayName])
        catch _:_ ->
            io:format("Warning: could not save ~p to NVS~n", [Name])
        end
    end, Paired).

%% Pretty-print discovered bulbs
print_bulbs(Bulbs) ->
    lists:foldl(fun(#{addr := Addr, rssi := RSSI, name := Name}, N) ->
        io:format("  ~p. ~s (~s) RSSI: ~p dBm~n",
                  [N, Name, format_addr(Addr), RSSI]),
        N + 1
    end, 1, Bulbs).

print_paired(Paired) ->
    lists:foreach(fun({Name, Addr, _AddrType, DisplayName}) ->
        io:format("  ~p: ~s (~s)~n", [Name, DisplayName, format_addr(Addr)])
    end, Paired).

format_addr(<<A, B, C, D, E, F>>) ->
    io_lib:format("~2.16.0B:~2.16.0B:~2.16.0B:~2.16.0B:~2.16.0B:~2.16.0B",
                  [F, E, D, C, B, A]).

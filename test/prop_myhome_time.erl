-module(prop_myhome_time).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Generators
%%====================================================================

%% Valid UTC datetime within a reasonable range (2020-2035)
utc_datetime() ->
    ?LET({Y, Mo, D, H, Mi, S},
         {integer(2020, 2035), integer(1, 12), integer(1, 28),
          integer(0, 23), integer(0, 59), integer(0, 59)},
         {{Y, Mo, D}, {H, Mi, S}}).

%% CET/CEST TZ string (the one we actually use)
cet_tz() ->
    "CET-1CEST,M3.5.0,M10.5.0/3".

%%====================================================================
%% Properties
%%====================================================================

%% Local time is always a valid {H, M, S} tuple with values in range
prop_local_time_valid_range() ->
    Tz = myhome_time:parse_posix_tz(cet_tz()),
    ?FORALL(Dt, utc_datetime(),
        begin
            {H, M, S} = myhome_time:utc_to_local(Dt, Tz),
            H >= 0 andalso H =< 23 andalso
            M >= 0 andalso M =< 59 andalso
            S >= 0 andalso S =< 59
        end).

%% UTC+1 in winter: local hour = (UTC hour + 1) mod 24
prop_winter_offset_plus_one() ->
    Tz = myhome_time:parse_posix_tz(cet_tz()),
    ?FORALL({H, Mi, S},
            {integer(0, 23), integer(0, 59), integer(0, 59)},
        begin
            %% January 15 is always winter (standard time)
            Dt = {{2026, 1, 15}, {H, Mi, S}},
            {LH, LM, LS} = myhome_time:utc_to_local(Dt, Tz),
            LH =:= (H + 1) rem 24 andalso LM =:= Mi andalso LS =:= S
        end).

%% UTC+2 in summer: local hour = (UTC hour + 2) mod 24
prop_summer_offset_plus_two() ->
    Tz = myhome_time:parse_posix_tz(cet_tz()),
    ?FORALL({H, Mi, S},
            {integer(0, 23), integer(0, 59), integer(0, 59)},
        begin
            %% July 15 is always summer (DST)
            Dt = {{2026, 7, 15}, {H, Mi, S}},
            {LH, LM, LS} = myhome_time:utc_to_local(Dt, Tz),
            LH =:= (H + 2) rem 24 andalso LM =:= Mi andalso LS =:= S
        end).

%% DST is a boolean for any valid datetime
prop_in_dst_is_boolean() ->
    Tz = myhome_time:parse_posix_tz(cet_tz()),
    ?FORALL(Dt, utc_datetime(),
        begin
            Result = myhome_time:in_dst(Dt, Tz),
            Result =:= true orelse Result =:= false
        end).

%% For any year, DST start is before DST end (in CET zone)
prop_dst_start_before_end() ->
    ?FORALL(Y, integer(2020, 2035),
        begin
            Start = myhome_time:transition_to_datetime(Y, {3, 5, 0, 2}, 3600),
            End = myhome_time:transition_to_datetime(Y, {10, 5, 0, 3}, 3600),
            Start < End
        end).

%% Transition dates always fall on a Sunday
prop_transition_is_sunday() ->
    ?FORALL(Y, integer(2020, 2035),
        begin
            {{_, _, DayMar}, _} = myhome_time:transition_to_datetime(Y, {3, 5, 0, 2}, 3600),
            {{_, _, DayOct}, _} = myhome_time:transition_to_datetime(Y, {10, 5, 0, 3}, 3600),
            %% Erlang: 7 = Sunday
            calendar:day_of_the_week({Y, 3, DayMar}) =:= 7 andalso
            calendar:day_of_the_week({Y, 10, DayOct}) =:= 7
        end).

%%====================================================================
%% EUnit wrappers (proper doesn't auto-discover, so we need explicit _test fns)
%%====================================================================

proper_test_() ->
    {timeout, 60, [
        fun() -> ?assert(proper:quickcheck(prop_local_time_valid_range(), [quiet, {numtests, 200}])) end,
        fun() -> ?assert(proper:quickcheck(prop_winter_offset_plus_one(), [quiet, {numtests, 200}])) end,
        fun() -> ?assert(proper:quickcheck(prop_summer_offset_plus_two(), [quiet, {numtests, 200}])) end,
        fun() -> ?assert(proper:quickcheck(prop_in_dst_is_boolean(), [quiet, {numtests, 200}])) end,
        fun() -> ?assert(proper:quickcheck(prop_dst_start_before_end(), [quiet, {numtests, 100}])) end,
        fun() -> ?assert(proper:quickcheck(prop_transition_is_sunday(), [quiet, {numtests, 100}])) end
    ]}.

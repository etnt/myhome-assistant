-module(myhome_time_tests).
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% POSIX TZ parsing tests
%%====================================================================

parse_cet_test() ->
    Tz = myhome_time:parse_posix_tz("CET-1CEST,M3.5.0,M10.5.0/3"),
    %% CET = UTC+1 => 3600 seconds east
    ?assertEqual(3600, element(2, Tz)),
    %% CEST = UTC+2 => 7200 seconds east
    ?assertEqual(7200, element(3, Tz)),
    %% DST starts: last Sunday of March at 02:00
    ?assertEqual({3, 5, 0, 2}, element(4, Tz)),
    %% DST ends: last Sunday of October at 03:00
    ?assertEqual({10, 5, 0, 3}, element(5, Tz)).

parse_est_test() ->
    %% US Eastern: EST5EDT,M3.2.0,M11.1.0
    Tz = myhome_time:parse_posix_tz("EST5EDT,M3.2.0,M11.1.0"),
    %% EST = UTC-5 => -18000 seconds east
    ?assertEqual(-18000, element(2, Tz)),
    %% EDT = UTC-4 => -14400 seconds east
    ?assertEqual(-14400, element(3, Tz)).

%%====================================================================
%% UTC to local conversion tests
%%====================================================================

winter_time_test() ->
    %% 15 January 2026, 14:30:00 UTC => CET = 15:30:00
    Tz = myhome_time:parse_posix_tz("CET-1CEST,M3.5.0,M10.5.0/3"),
    Result = myhome_time:utc_to_local({{2026, 1, 15}, {14, 30, 0}}, Tz),
    ?assertEqual({15, 30, 0}, Result).

summer_time_test() ->
    %% 15 June 2026, 14:30:00 UTC => CEST = 16:30:00
    Tz = myhome_time:parse_posix_tz("CET-1CEST,M3.5.0,M10.5.0/3"),
    Result = myhome_time:utc_to_local({{2026, 6, 15}, {14, 30, 0}}, Tz),
    ?assertEqual({16, 30, 0}, Result).

midnight_rollover_test() ->
    %% 15 January 2026, 23:30:00 UTC => CET = 00:30:00 (next day)
    Tz = myhome_time:parse_posix_tz("CET-1CEST,M3.5.0,M10.5.0/3"),
    Result = myhome_time:utc_to_local({{2026, 1, 15}, {23, 30, 0}}, Tz),
    ?assertEqual({0, 30, 0}, Result).

%%====================================================================
%% DST transition boundary tests
%%====================================================================

dst_start_before_test() ->
    %% 2026: Last Sunday of March = March 29
    %% Just before DST starts: March 29, 01:59 UTC (still standard time)
    Tz = myhome_time:parse_posix_tz("CET-1CEST,M3.5.0,M10.5.0/3"),
    ?assertEqual(false, myhome_time:in_dst({{2026, 3, 29}, {1, 59, 0}}, Tz)).

dst_start_after_test() ->
    %% DST starts at 02:00 local = 01:00 UTC (since std offset is +1)
    %% Wait — the transition datetime is {{2026,3,29},{2,0,0}} which is compared
    %% against UTC directly. At UTC 02:00 on March 29 we're in DST.
    Tz = myhome_time:parse_posix_tz("CET-1CEST,M3.5.0,M10.5.0/3"),
    ?assertEqual(true, myhome_time:in_dst({{2026, 3, 29}, {2, 0, 0}}, Tz)).

dst_end_before_test() ->
    %% 2026: Last Sunday of October = October 25
    %% Just before DST ends at 03:00 local (transition datetime)
    Tz = myhome_time:parse_posix_tz("CET-1CEST,M3.5.0,M10.5.0/3"),
    ?assertEqual(true, myhome_time:in_dst({{2026, 10, 25}, {2, 59, 0}}, Tz)).

dst_end_after_test() ->
    %% At 03:00 on October 25, DST ends
    Tz = myhome_time:parse_posix_tz("CET-1CEST,M3.5.0,M10.5.0/3"),
    ?assertEqual(false, myhome_time:in_dst({{2026, 10, 25}, {3, 0, 0}}, Tz)).

%%====================================================================
%% Transition date calculation tests
%%====================================================================

last_sunday_march_2026_test() ->
    %% March 2026: starts on Sunday. Last Sunday = March 29.
    Result = myhome_time:transition_to_datetime(2026, {3, 5, 0, 2}, 3600),
    ?assertEqual({{2026, 3, 29}, {2, 0, 0}}, Result).

last_sunday_october_2026_test() ->
    %% October 2026: Oct 1 = Thursday. Last Sunday = Oct 25.
    Result = myhome_time:transition_to_datetime(2026, {10, 5, 0, 3}, 3600),
    ?assertEqual({{2026, 10, 25}, {3, 0, 0}}, Result).

second_sunday_march_test() ->
    %% US DST: 2nd Sunday of March 2026.
    %% March 2026: 1st is Sunday, so 2nd Sunday = March 8.
    Result = myhome_time:transition_to_datetime(2026, {3, 2, 0, 2}, -18000),
    ?assertEqual({{2026, 3, 8}, {2, 0, 0}}, Result).

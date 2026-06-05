%%%-------------------------------------------------------------------
%%% @doc Local time helper — converts UTC to local time using a
%%% POSIX TZ string from myhome_config.
%%% @end
%%%-------------------------------------------------------------------
-module(myhome_time).

-export([local_time/0, local_hour/0, local_minute/0, is_dst/0]).

-ifdef(TEST).
-export([parse_posix_tz/1, utc_to_local/2, in_dst/2, transition_to_datetime/3]).
-endif.

-record(tz, {
    std_offset :: integer(),    %% seconds east of UTC (standard)
    dst_offset :: integer(),    %% seconds east of UTC (DST)
    dst_start  :: tuple(),      %% {Month, Week, DayOfWeek, Hour}
    dst_end    :: tuple()       %% {Month, Week, DayOfWeek, Hour}
}).

%%====================================================================
%% API
%%====================================================================

%% @doc Return {Hour, Minute, Second} in configured local timezone.
local_time() ->
    UtcNow = erlang:universaltime(),
    Tz = parse_posix_tz(myhome_config:timezone()),
    utc_to_local(UtcNow, Tz).

local_hour() ->
    {H, _, _} = local_time(),
    H.

local_minute() ->
    {_, M, _} = local_time(),
    M.

%% @doc Return true if the current UTC moment falls within DST.
is_dst() ->
    UtcNow = erlang:universaltime(),
    Tz = parse_posix_tz(myhome_config:timezone()),
    in_dst(UtcNow, Tz).

%%====================================================================
%% Internal: POSIX TZ parsing and conversion
%%====================================================================

parse_posix_tz(Str) ->
    %% Parse "CET-1CEST,M3.5.0,M10.5.0/3"
    [StdPart, Transitions] = string:split(Str, ","),
    OffsetStr = extract_offset(StdPart),
    %% POSIX convention: negative offset = east of UTC, so negate for seconds east
    StdOff = -(list_to_integer(OffsetStr)) * 3600,
    [StartStr, EndStr] = string:split(Transitions, ","),
    Start = parse_transition(StartStr),
    End = parse_transition(EndStr),
    DstOff = StdOff + 3600,
    #tz{std_offset = StdOff, dst_offset = DstOff,
        dst_start = Start, dst_end = End}.

utc_to_local({{Y, Mo, D}, {H, Mi, S}}, #tz{} = Tz) ->
    UtcSecs = calendar:datetime_to_gregorian_seconds({{Y, Mo, D}, {H, Mi, S}}),
    Offset = case in_dst({{Y, Mo, D}, {H, Mi, S}}, Tz) of
        true  -> Tz#tz.dst_offset;
        false -> Tz#tz.std_offset
    end,
    LocalSecs = UtcSecs + Offset,
    {{_, _, _}, Time} = calendar:gregorian_seconds_to_datetime(LocalSecs),
    Time.

in_dst(DateTime, #tz{dst_start = Start, dst_end = End, std_offset = StdOff}) ->
    {{Y, _, _}, _} = DateTime,
    DstStartDT = transition_to_datetime(Y, Start, StdOff),
    DstEndDT = transition_to_datetime(Y, End, StdOff),
    DateTime >= DstStartDT andalso DateTime < DstEndDT.

extract_offset(Str) ->
    %% "CET-1CEST" -> offset is "-1" (meaning east of UTC)
    %% We return the raw sign+digits for list_to_integer
    case find_offset_chars(Str, []) of
        [] -> "0";
        Chars -> Chars
    end.

find_offset_chars([], Acc) ->
    lists:reverse(Acc);
find_offset_chars([$- | Rest], []) ->
    %% Start of a negative offset
    find_offset_chars(Rest, [$-]);
find_offset_chars([$+ | Rest], []) ->
    %% Start of a positive offset
    find_offset_chars(Rest, [$+]);
find_offset_chars([C | Rest], Acc) when C >= $0, C =< $9 ->
    find_offset_chars(Rest, [C | Acc]);
find_offset_chars([C | _Rest], Acc) when length(Acc) > 0, (C < $0 orelse C > $9) ->
    %% Hit a non-digit after collecting digits — done
    lists:reverse(Acc);
find_offset_chars([_C | Rest], Acc) ->
    find_offset_chars(Rest, Acc).

parse_transition(Str) ->
    %% Parse "M3.5.0" or "M10.5.0/3"
    {MStr2, Hour} = case string:split(Str, "/") of
        [M] -> {M, 2};
        [M, HStr] -> {M, list_to_integer(HStr)}
    end,
    [$M | Rest] = MStr2,
    [MoStr, WeekStr, DowStr] = string:split(Rest, ".", all),
    {list_to_integer(MoStr), list_to_integer(WeekStr),
     list_to_integer(DowStr), Hour}.

transition_to_datetime(Year, {Month, Week, DayOfWeek, Hour}, _StdOff) ->
    %% Find the Week'th DayOfWeek in Month of Year
    %% DayOfWeek: 0=Sunday, 1=Monday, ..., 6=Saturday
    %% calendar:day_of_the_week returns 1=Monday..7=Sunday
    FirstDayErl = calendar:day_of_the_week({Year, Month, 1}),
    %% Convert Erlang DOW (1=Mon..7=Sun) to POSIX (0=Sun..6=Sat)
    FirstDayPosix = case FirstDayErl of
        7 -> 0;
        N -> N
    end,
    Offset = (DayOfWeek - FirstDayPosix + 7) rem 7,
    FirstOccurrence = 1 + Offset,
    Day = case Week of
        5 ->
            %% "last" occurrence
            LastDay = calendar:last_day_of_the_month(Year, Month),
            find_last_occurrence(FirstOccurrence, LastDay);
        _ ->
            FirstOccurrence + (Week - 1) * 7
    end,
    {{Year, Month, Day}, {Hour, 0, 0}}.

find_last_occurrence(First, LastDay) ->
    Candidate = First + 28,
    case Candidate > LastDay of
        true  -> Candidate - 7;
        false -> Candidate
    end.

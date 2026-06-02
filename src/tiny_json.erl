%%%-------------------------------------------------------------------
%%% @doc Minimal JSON encoder that produces flat binaries.
%%%
%%% Handles: maps, lists, binaries, atoms, integers, floats, booleans.
%%% Produces a single flat binary — no nested iolists.
%%% Designed for AtomVM where deeply nested iolists cause hangs.
%%% @end
%%%-------------------------------------------------------------------
-module(tiny_json).

-export([encode/1]).

-spec encode(term()) -> binary().
encode(null) -> <<"null">>;
encode(nil) -> <<"null">>;
encode(undefined) -> <<"null">>;
encode(true) -> <<"true">>;
encode(false) -> <<"false">>;
encode(V) when is_integer(V) -> integer_to_binary(V);
encode(V) when is_float(V) -> float_to_binary(V, [{decimals, 6}, compact]);
encode(V) when is_atom(V) -> <<"\"", (atom_to_binary(V, utf8))/binary, "\"">>;
encode(V) when is_binary(V) -> <<"\"", (escape(V))/binary, "\"">>;
encode(M) when is_map(M) -> encode_map(M);
encode(L) when is_list(L) -> encode_list(L);
encode(_) -> <<"null">>.

%%====================================================================
%% Map encoding
%%====================================================================

encode_map(Map) ->
    Pairs = maps:fold(fun(K, V, Acc) ->
        Key = encode_key(K),
        Val = encode(V),
        [<<Key/binary, ":", Val/binary>> | Acc]
    end, [], Map),
    Inner = join(Pairs, <<",">>),
    <<"{", Inner/binary, "}">>.

encode_key(K) when is_atom(K) -> <<"\"", (atom_to_binary(K, utf8))/binary, "\"">>;
encode_key(K) when is_binary(K) -> <<"\"", (escape(K))/binary, "\"">>;
encode_key(K) when is_list(K) -> <<"\"", (list_to_binary(K))/binary, "\"">>.

%%====================================================================
%% List encoding
%%====================================================================

encode_list([]) -> <<"[]">>;
encode_list(L) ->
    Items = [encode(E) || E <- L],
    Inner = join(Items, <<",">>),
    <<"[", Inner/binary, "]">>.

%%====================================================================
%% String escaping
%%====================================================================

escape(Bin) -> escape(Bin, <<>>).

escape(<<>>, Acc) -> Acc;
escape(<<$", Rest/binary>>, Acc) -> escape(Rest, <<Acc/binary, "\\\"" >>);
escape(<<$\\, Rest/binary>>, Acc) -> escape(Rest, <<Acc/binary, "\\\\">>);
escape(<<$\n, Rest/binary>>, Acc) -> escape(Rest, <<Acc/binary, "\\n">>);
escape(<<$\r, Rest/binary>>, Acc) -> escape(Rest, <<Acc/binary, "\\r">>);
escape(<<$\t, Rest/binary>>, Acc) -> escape(Rest, <<Acc/binary, "\\t">>);
escape(<<C, Rest/binary>>, Acc) when C < 32 ->
    %% Other control chars: \u00XX
    Hi = hex_char(C bsr 4),
    Lo = hex_char(C band 16#0F),
    escape(Rest, <<Acc/binary, "\\u00", Hi, Lo>>);
escape(<<C, Rest/binary>>, Acc) -> escape(Rest, <<Acc/binary, C>>).

hex_char(N) when N < 10 -> N + $0;
hex_char(N) -> N - 10 + $a.

%%====================================================================
%% Helpers
%%====================================================================

join([], _Sep) -> <<>>;
join([H], _Sep) -> H;
join([H | T], Sep) ->
    lists:foldl(fun(B, Acc) -> <<Acc/binary, Sep/binary, B/binary>> end, H, T).

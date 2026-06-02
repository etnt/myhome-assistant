%%%-------------------------------------------------------------------
%%% @doc Minimal HTTP server with one process per connection.
%%%
%%% Each accepted connection spawns its own handler process, which
%%% parses the HTTP request, invokes the callback module, and sends
%%% the response — all without blocking other connections.
%%%
%%% Callback module must export:
%%%   handle_request(Method, Path, Request) ->
%%%       {200, Headers, Body} | {StatusCode, Headers, Body}
%%%
%%% Where:
%%%   Method  :: get | post | put | delete
%%%   Path    :: [binary()]           e.g. [<<"api">>, <<"status">>]
%%%   Request :: #{params => #{binary() => binary()},
%%%                body => binary(),
%%%                headers => #{binary() => binary()}}
%%% @end
%%%-------------------------------------------------------------------
-module(tiny_httpd).

-export([start_link/2, start_link/3]).

%% @doc Start listening on Port, dispatching to Handler module.
-spec start_link(pos_integer(), module()) -> {ok, pid()}.
start_link(Port, Handler) ->
    start_link(any, Port, Handler).

-spec start_link(any | {integer(),integer(),integer(),integer()}, pos_integer(), module()) -> {ok, pid()}.
start_link(Address, Port, Handler) ->
    Pid = spawn_link(fun() -> listen(Address, Port, Handler) end),
    {ok, Pid}.

%%====================================================================
%% Listener
%%====================================================================

listen(Address, Port, Handler) ->
    case socket:open(inet, stream, tcp) of
        {ok, ListenSock} ->
            ok = socket:setopt(ListenSock, {socket, reuseaddr}, true),
            BindAddr = case Address of
                any -> #{family => inet, addr => any, port => Port};
                {_, _, _, _} = IP -> #{family => inet, addr => IP, port => Port}
            end,
            case socket:bind(ListenSock, BindAddr) of
                ok ->
                    case socket:listen(ListenSock) of
                        ok ->
                            accept_loop(ListenSock, Handler);
                        {error, Reason} ->
                            io:format("[tiny_httpd] listen failed: ~p~n", [Reason])
                    end;
                {error, Reason} ->
                    io:format("[tiny_httpd] bind failed: ~p~n", [Reason])
            end;
        {error, Reason} ->
            io:format("[tiny_httpd] socket open failed: ~p~n", [Reason])
    end.

accept_loop(ListenSock, Handler) ->
    case socket:accept(ListenSock) of
        {ok, ConnSock} ->
            spawn(fun() -> handle_connection(ConnSock, Handler) end),
            accept_loop(ListenSock, Handler);
        {error, _Reason} ->
            accept_loop(ListenSock, Handler)
    end.

%%====================================================================
%% Connection handler (one process per request)
%%====================================================================

handle_connection(Sock, Handler) ->
    case recv_request(Sock, <<>>) of
        {ok, RawRequest} ->
            case parse_request(RawRequest) of
                {ok, Method, Path, Params, Headers, Body} ->
                    Request = #{params => Params,
                                body => Body,
                                headers => Headers},
                    {Status, RespHeaders, RespBody} =
                        try Handler:handle_request(Method, Path, Request)
                        catch C:R ->
                            io:format("[tiny_httpd] handler crash: ~p:~p~n", [C, R]),
                            {500, #{}, <<"Internal Server Error">>}
                        end,
                    send_response(Sock, Status, RespHeaders, RespBody);
                {error, _} ->
                    send_response(Sock, 400, #{}, <<"Bad Request">>)
            end;
        {error, _} ->
            ok
    end,
    socket:close(Sock).

%%====================================================================
%% Receive full HTTP request
%%====================================================================

recv_request(Sock, Acc) ->
    case socket:recv(Sock, 0, 10000) of
        {ok, Data} ->
            All = <<Acc/binary, Data/binary>>,
            case has_complete_request(All) of
                {true, HeaderEnd} ->
                    maybe_recv_body(Sock, All, HeaderEnd);
                false ->
                    recv_request(Sock, All)
            end;
        {error, timeout} when byte_size(Acc) > 0 ->
            {ok, Acc};
        {error, Reason} ->
            {error, Reason}
    end.

has_complete_request(Data) ->
    case binary:match(Data, <<"\r\n\r\n">>) of
        {Pos, 4} -> {true, Pos + 4};
        nomatch -> false
    end.

maybe_recv_body(Sock, Data, HeaderEnd) ->
    Headers = binary:part(Data, 0, HeaderEnd),
    Body = binary:part(Data, HeaderEnd, byte_size(Data) - HeaderEnd),
    case find_content_length(Headers) of
        0 ->
            {ok, Data};
        ContentLen when byte_size(Body) >= ContentLen ->
            {ok, Data};
        ContentLen ->
            recv_remaining(Sock, Data, ContentLen - byte_size(Body))
    end.

recv_remaining(_Sock, Acc, Remaining) when Remaining =< 0 ->
    {ok, Acc};
recv_remaining(Sock, Acc, Remaining) ->
    case socket:recv(Sock, 0, 5000) of
        {ok, Data} ->
            NewAcc = <<Acc/binary, Data/binary>>,
            recv_remaining(Sock, NewAcc, Remaining - byte_size(Data));
        {error, _} ->
            {ok, Acc}
    end.

find_content_length(Headers) ->
    %% Case-insensitive search for content-length
    Lower = lowercase(Headers),
    case binary:match(Lower, <<"content-length:">>) of
        {Pos, Len} ->
            Rest = binary:part(Headers, Pos + Len, byte_size(Headers) - Pos - Len),
            ValBin = trim_to_line(Rest),
            try binary_to_integer(trim_ws(ValBin))
            catch _:_ -> 0
            end;
        nomatch ->
            0
    end.

%%====================================================================
%% Parse HTTP request line + headers + body
%%====================================================================

parse_request(RawRequest) ->
    case binary:match(RawRequest, <<"\r\n">>) of
        {LineEnd, 2} ->
            RequestLine = binary:part(RawRequest, 0, LineEnd),
            Rest = binary:part(RawRequest, LineEnd + 2,
                               byte_size(RawRequest) - LineEnd - 2),
            case parse_request_line(RequestLine) of
                {ok, Method, PathBin, QueryString} ->
                    Path = parse_path(PathBin),
                    Params = parse_query_string(QueryString),
                    {Headers, Body} = parse_headers_body(Rest),
                    {ok, Method, Path, Params, Headers, Body};
                error ->
                    {error, bad_request_line}
            end;
        nomatch ->
            {error, no_request_line}
    end.

parse_request_line(Line) ->
    case binary:split(Line, <<" ">>, [global]) of
        [MethodBin, URI | _] ->
            Method = method_atom(MethodBin),
            {PathBin, QueryString} = split_uri(URI),
            {ok, Method, PathBin, QueryString};
        _ ->
            error
    end.

method_atom(<<"GET">>) -> get;
method_atom(<<"POST">>) -> post;
method_atom(<<"PUT">>) -> put;
method_atom(<<"DELETE">>) -> delete;
method_atom(_) -> get.

split_uri(URI) ->
    case binary:match(URI, <<"?">>) of
        {Pos, 1} ->
            Path = binary:part(URI, 0, Pos),
            QS = binary:part(URI, Pos + 1, byte_size(URI) - Pos - 1),
            {Path, QS};
        nomatch ->
            {URI, <<>>}
    end.

parse_path(PathBin) ->
    %% "/api/status" -> [<<"api">>, <<"status">>]
    Stripped = case PathBin of
        <<"/", Rest/binary>> -> Rest;
        Other -> Other
    end,
    case Stripped of
        <<>> -> [];
        _ -> binary:split(Stripped, <<"/">>, [global])
    end.

parse_query_string(<<>>) ->
    #{};
parse_query_string(QS) ->
    Pairs = binary:split(QS, <<"&">>, [global]),
    lists:foldl(fun(Pair, Acc) ->
        case binary:match(Pair, <<"=">>) of
            {Pos, 1} ->
                Key = binary:part(Pair, 0, Pos),
                Val = binary:part(Pair, Pos + 1, byte_size(Pair) - Pos - 1),
                Acc#{Key => Val};
            nomatch ->
                Acc#{Pair => <<"true">>}
        end
    end, #{}, Pairs).

parse_headers_body(Data) ->
    case binary:match(Data, <<"\r\n\r\n">>) of
        {Pos, 4} ->
            HeaderBlock = binary:part(Data, 0, Pos),
            Body = binary:part(Data, Pos + 4, byte_size(Data) - Pos - 4),
            Headers = parse_header_lines(HeaderBlock),
            {Headers, Body};
        nomatch ->
            %% No body separator found — treat all as headers
            Headers = parse_header_lines(Data),
            {Headers, <<>>}
    end.

parse_header_lines(Block) ->
    Lines = binary:split(Block, <<"\r\n">>, [global]),
    lists:foldl(fun(Line, Acc) ->
        case binary:match(Line, <<":">>) of
            {Pos, 1} ->
                Key = lowercase(trim_ws(binary:part(Line, 0, Pos))),
                Val = trim_ws(binary:part(Line, Pos + 1, byte_size(Line) - Pos - 1)),
                Acc#{Key => Val};
            nomatch ->
                Acc
        end
    end, #{}, Lines).

%%====================================================================
%% Send HTTP response
%%====================================================================

send_response(Sock, Status, Headers, Body) ->
    StatusLine = [<<"HTTP/1.1 ">>, status_text(Status), <<"\r\n">>],
    AllHeaders = Headers#{<<"Content-Length">> => integer_to_binary(byte_size(Body)),
                          <<"Connection">> => <<"close">>},
    HeaderLines = maps:fold(fun(K, V, Acc) ->
        [to_binary(K), <<": ">>, to_binary(V), <<"\r\n">> | Acc]
    end, [], AllHeaders),
    Response = iolist_to_binary([StatusLine, HeaderLines, <<"\r\n">>, Body]),
    socket:send(Sock, Response).

status_text(200) -> <<"200 OK">>;
status_text(400) -> <<"400 Bad Request">>;
status_text(404) -> <<"404 Not Found">>;
status_text(500) -> <<"500 Internal Server Error">>;
status_text(N) -> integer_to_binary(N).

%%====================================================================
%% Helpers
%%====================================================================

trim_ws(<<$ , Rest/binary>>) -> trim_ws(Rest);
trim_ws(<<$\t, Rest/binary>>) -> trim_ws(Rest);
trim_ws(Bin) -> Bin.

trim_to_line(Bin) ->
    case binary:match(Bin, <<"\r\n">>) of
        {Pos, _} -> binary:part(Bin, 0, Pos);
        nomatch -> Bin
    end.

lowercase(Bin) when is_binary(Bin) ->
    << <<(lower_char(C))>> || <<C>> <= Bin >>.

lower_char(C) when C >= $A, C =< $Z -> C + 32;
lower_char(C) -> C.

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> list_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(I) when is_integer(I) -> integer_to_binary(I).

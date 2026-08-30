%%%-------------------------------------------------------------------
%%% @doc Project Gutenberg ebook search agent.
%%%
%%% Uses the Gutendex REST API (gutendex.com) to search the ~70 000
%%% public-domain ebooks in Project Gutenberg and returns embryos
%%% with title, authors, and a direct link to the ebook page.
%%%
%%% Deduplication by URL is handled upstream by the Emquest pipeline.
%%%
%%% === Capability cascade ===
%%%
%%%   base_capabilities/0 extends em_filter:base_capabilities().
%%%
%%% Handler contract: handle/2 (Body, Memory) -> {RawList, Memory}.
%%% @end
%%%-------------------------------------------------------------------
-module(gutenberg_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/2, base_capabilities/0]).

-define(SEARCH_URL, "https://gutendex.com/books/?search=").

%%====================================================================
%% Capability cascade
%%====================================================================

-spec base_capabilities() -> [binary()].
base_capabilities() ->
    em_filter:base_capabilities() ++ [<<"gutenberg">>, <<"books">>,
                                      <<"ebooks">>, <<"public_domain">>,
                                      <<"literature">>].

%%====================================================================
%% Application behaviour
%%====================================================================

start(_Type, _Args) ->
    case gutenberg_filter_sup:start_link() of
        {ok, Pid} ->
            ok = start_pop_and_http(),
            {ok, Pid};
        Error ->
            Error
    end.

stop(_State) ->
    catch cowboy:stop_listener(gutenberg_filter_query_listener),
    catch em_pop_sup:stop_node(gutenberg_filter),
    ok.

%%====================================================================
%% Internal
%%====================================================================

start_pop_and_http() ->
    PopPort   = application:get_env(gutenberg_filter, pop_port,   9536),
    QueryPort = application:get_env(gutenberg_filter, query_port, 9537),
    Seeds     = application:get_env(gutenberg_filter, pop_seeds,  []),
    Vec = em_filter_vec:from_capabilities(base_capabilities()),
    catch em_pop_sup:stop_node(gutenberg_filter),
    catch cowboy:stop_listener(gutenberg_filter_query_listener),
    {ok, PopPid} = em_pop_sup:start_node(gutenberg_filter, #{
        port            => PopPort,
        query_port      => QueryPort,
        vector          => Vec,
        max_peers       => 100,
        gossip_interval => 5_000
    }),
    lists:foreach(
        fun({H, P}) -> catch em_pop_node:add_peer(PopPid, H, P) end,
        Seeds),
    Dispatch = cowboy_router:compile([
        {'_', [{"/agent/query", em_filter_http,
                #{server => gutenberg_filter_server}}]}
    ]),
    {ok, _} = cowboy:start_clear(gutenberg_filter_query_listener,
                                  [{port, QueryPort}],
                                  #{env => #{dispatch => Dispatch}}),
    logger:notice("[gutenberg_filter] gossip port ~w  query port ~w",
                  [PopPort, QueryPort]),
    ok.

%%====================================================================
%% Agent handler
%%====================================================================

handle(Body, Memory) when is_binary(Body) ->
    {generate_embryo_list(Body), Memory};
handle(_Body, Memory) ->
    {[], Memory}.

%%====================================================================
%% Search and processing
%%====================================================================

generate_embryo_list(JsonBinary) ->
    {Query, Timeout} = extract_params(JsonBinary),
    fetch_results(Query, Timeout).

extract_params(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            Query   = binary_to_list(maps:get(<<"value">>, Map,
                          maps:get(<<"query">>, Map, <<"">>))),
            Timeout = case maps:get(<<"timeout">>, Map, undefined) of
                undefined            -> 10;
                T when is_integer(T) -> T;
                T when is_binary(T)  -> binary_to_integer(T)
            end,
            {Query, Timeout};
        _ ->
            {binary_to_list(JsonBinary), 10}
    catch
        _:_ -> {binary_to_list(JsonBinary), 10}
    end.

fetch_results("", _) -> [];
fetch_results(Query, Timeout) ->
    Url = lists:flatten(io_lib:format("~s~s", [?SEARCH_URL, uri_string:quote(Query)])),
    Headers = [{"User-Agent", "gutenberg_filter/1.0"}],
    case httpc:request(get, {Url, Headers},
                       [{timeout, Timeout * 1000},
                        {ssl, [{verify, verify_none}]}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            parse_results(Body);
        _ ->
            []
    end.

parse_results(JsonBin) ->
    try json:decode(JsonBin) of
        #{<<"results">> := Results} when is_list(Results) ->
            lists:filtermap(fun build_embryo/1, Results);
        _ ->
            []
    catch
        _:_ -> []
    end.

build_embryo(#{<<"id">> := Id, <<"title">> := Title} = Book) ->
    Authors  = format_authors(maps:get(<<"authors">>, Book, [])),
    Url      = lists:flatten(io_lib:format(
        "https://www.gutenberg.org/ebooks/~p", [Id])),
    Resume   = case Authors of
        "" -> <<"">>;
        _  -> list_to_binary(Authors)
    end,
    {true, #{
        <<"properties">> => #{
            <<"url">>    => list_to_binary(Url),
            <<"resume">> => Resume,
            <<"title">>  => Title,
            <<"source">> => <<"gutenberg.org">>
        }
    }};
build_embryo(_) ->
    false.

format_authors([]) -> "";
format_authors(Authors) when is_list(Authors) ->
    Names = lists:filtermap(fun(A) ->
        case maps:get(<<"name">>, A, undefined) of
            undefined -> false;
            N         -> {true, binary_to_list(N)}
        end
    end, Authors),
    string:join(lists:sublist(Names, 3), ", ").

%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% @author John Keiser <jkeiser@opscode.com>
%% @author Seth Falcon <seth@opscode.com>
%% @copyright 2011-2012 Opscode Inc.
%% @doc stats_hero metric collector worker gen_server
%%
%% This module implements the stats_hero worker, a gen_server used by a another process
%% (e.g. Webmachine request), to aggregate timing data and send it to estatsd.
%%
%% @end

-module(stats_hero).
-behaviour(gen_server).

%% API
-export([ctime/3,
         alog/3,
         report_tuples/1,
         report_metrics/2,
         start_link/1,
         label/2,
         clean_worker_data/1,
         stop_worker/1,
         init_storage/0,
         log_request/3]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-type upstream() :: 'authz' | 'chef_authz' | 'chef_otto' | 'chef_solr' |
                    'chef_sql' | 'couchdb' | 'rdbms' | 'solr'.

-type req_id() :: binary().
-type time_unit() :: 'ms' | 'micros'.
-type timing() :: {non_neg_integer(), time_unit()}.

-define(SERVER, ?MODULE).

%% Global ETS table used by stats_hero to keep track of ReqId <=> Pid mappings.
-define(SH_WORKER_TABLE, stats_hero_table).

%% Helper macro for extracting values from proplists; crashes if key not found
-define(gv(Key, PL), element(2, lists:keyfind(Key, 1, PL))).

-include("stats_hero.hrl").
-include_lib("eunit/include/eunit.hrl").

-record(state, {
          estatsd_host           :: string(),
          estatsd_port           :: non_neg_integer(),
          start_time             :: {non_neg_integer(), non_neg_integer(), non_neg_integer()},
          my_app                 :: binary(),
          my_host                :: binary(),
          request_label          :: binary(),   % roles
          request_action         :: binary(),   % update
          org_name               :: binary(),
          request_id             :: binary(),
          metrics = dict:new()   :: dict(),
          upstream_prefixes = [] :: [binary()]
         }).

-record(ctimer, {count = 0 :: non_neg_integer(),
                 time = 0 :: non_neg_integer()}).

-record(alog, {message = [] :: iolist()}).

-spec ctime(req_id(), binary(), fun(() -> any()) | timing()) -> any().
%% @doc Update cummulative timer identified by `Label'.
%%
%% If `Fun' is a fun/0, the metric is updated with the time required to execute `Fun()' and
%% its value is returned. You can also specify a time explicitly in milliseconds or
%% microseconds as `{Time, ms}' or `{Time, micros}', respectively. The `ReqId' is used to
%% find the appropriate stats_hero worker process. If no such process is found, the timing
%% data is thrown away.
%%
%% You probably want to use the `?SH_TIME' macro in stats_hero.hrl instead of calling this
%% function directly.
%%
%% ``?SH_TIME(ReqId, Mod, Fun, Args)''
%%
%% The `Mod' argument will be mapped to an upstream label as defined in this module (one of
%% 'rdbms', 'couchdb', 'authz', or 'solr'). If `Mod' is not recognized, we currently raise
%% an error, but this could be changed to just accept it as part of the label for the metric
%% as-is.
%%
%% The specified MFA will be evaluated and its execution time sent to the stats_hero
%% worker. This macro returns the value returned by the specified MFA.  NOTE: `Args' must be
%% a parenthesized list of args. This is non-standard, but allows us to avoid an apply and
%% still get by with a simple macro.
%%
%% Here's an example call:
%% ``` ?SH_TIME(ReqId, chef_db, fetch_node, (Ctx, OrgName, NodeName))
%% '''
%%  And here's the intended expansion:
%% ```
%% stats_hero:ctime(ReqId, <<"rdbms.fetch_node">>,
%%                  fun() -> chef_db:fetch_node(Ctx, OrgName, NodeName) end)
%% '''
%%
%% `ReqId': binary(); `Mod': atom(); `Fun': atom();
%% `Args': '(a1, a2, ..., aN)'
%%
ctime(ReqId, Label, Fun) when is_function(Fun) ->
    {Micros, Result} = timer:tc(Fun),
    worker_ctime(ReqId, Label, {Micros, micros}),
    Result;
ctime(ReqId, Label, {Time, Unit}) ->
    worker_ctime(ReqId, Label, {Time, Unit}).

-spec init_storage() -> atom().
%% @doc Initialize the ETS storage for mapping ReqId to/from stats_hero worker Pids.
%%
%% This should be called by the supervisor that supervises the stats_hero_monitor process.
init_storage() ->
    ets:new(?SH_WORKER_TABLE, [set, public, named_table, {write_concurrency, true}]).

-spec stop_worker(pid() | binary()) -> ok.
%% @doc Stop the worker with the specified `Pid'.
%%
%% This will remove the worker's entries from the ETS table and then send an asynchronous
%% stop message to the worker.
%%
stop_worker(ReqId) when is_binary(ReqId) ->
    case find_stats_hero(ReqId) of
        not_found -> not_found;
        Pid -> stop_worker(Pid)
    end;
stop_worker(Pid) ->
    %% the monitor this worker registered with will clean this worker's ETS data
    gen_server:cast(Pid, stop_worker),
    ok.

-spec clean_worker_data(pid()) -> true | false.
%% @doc Remove pid/req_id mapping for the stats_hero worker given by `Pid'.
%%
%% This is intended to be called by a process that monitors all stats_hero workers and
%% cleans up their data when they exit. Returns `false' if no data was found in the table
%% and `true' otherwise.
clean_worker_data(Pid) ->
    case find_req_id(Pid) of
        not_found ->
            false;
        ReqId ->
            ets:delete(?SH_WORKER_TABLE, Pid),
            ets:delete(?SH_WORKER_TABLE, ReqId),
            true
    end.

%% @doc Append `Msg' to log identified by `{Level, Label}'.
alog(ReqId, {Level, Label}, Msg) ->
    case find_stats_hero(ReqId) of
        not_found -> ignored;
        Pid ->
            gen_server:cast(Pid, {alog, {Level, Label}, Msg})
    end.

report_tuples(Pid) ->
    gen_server:call(Pid, report_tuples).

-spec log_request(atom(), atom(), [{string()|binary()|atom(), any()}]) -> ok.
%% @doc Log a request using fast_log
%%
%% `Logger' is the name of the fast_log logger, `Level' is the logging level to log the
%% request at. `TList' is a tuple list of data to be logged. Keys should be atoms, strings,
%% or binaries; values should be iolists.
log_request(Logger, Level, TList) ->
    fast_log:Level(Logger, TList),
    ok.

-spec report_metrics(pid() | binary(), integer()) -> not_found | ok.
report_metrics(ReqId, StatusCode) when is_binary(ReqId) ->
    case find_stats_hero(ReqId) of
        not_found -> not_found;
        Pid -> report_metrics(Pid, StatusCode)
    end;
report_metrics(Pid, StatusCode) when is_integer(StatusCode) ->
    EndTime = os:timestamp(),
    gen_server:cast(Pid, {report_metrics, EndTime, StatusCode}),
    ok.

%% @doc Start your personalized stats_hero process.
%%
%% `Config' is a proplist with keys: requet_label, request_action, estatsd_host,
%% estatsd_port, upstream_prefixes, my_app, org_name, and request_id.
%%
start_link(Config) ->
    %% this server is intended to be a short-lived companion to a request process, so we
    %% avoid registering by name.
    gen_server:start_link(?MODULE, Config, []).

-spec label(upstream(), atom()) ->  <<_:8,_:_*8>>.
%% @doc Generate a stats hero metric label for upstream `Prefix' and function name `Fun'.
%% An error is thrown if `Prefix' is unknown.
%% This is where we encode the mapping of module to upstream label.
label(chef_otto, Fun) ->
    label(couchdb, Fun);
label(chef_sql, Fun) ->
    label(rdbms, Fun);
label(chef_authz, Fun) ->
    label(authz, Fun);
label(chef_solr, Fun) ->
    label(solr, Fun);
label(Prefix, Fun) when Prefix =:= rdbms;
                        Prefix =:= couchdb;
                        Prefix =:= authz;
                        Prefix =:= solr ->
    PrefixBin = erlang:atom_to_binary(Prefix, utf8),
    FunBin = erlang:atom_to_binary(Fun, utf8),
    <<PrefixBin/binary, ".", FunBin/binary>>;
label(BadPrefix, Fun) ->
    erlang:error({bad_prefix, {BadPrefix, Fun}}).

%%
%% callbacks
%%

init(Config) ->
    UpstreamPrefixes = ?gv(upstream_prefixes, Config),
    State = #state{estatsd_host = ?gv(estatsd_host, Config),
                   estatsd_port = ?gv(estatsd_port, Config),
                   start_time = os:timestamp(),
                   my_app = as_bin(?gv(my_app, Config)),
                   my_host = hostname(),
                   request_label = as_bin(?gv(request_label, Config)),
                   request_action = as_bin(?gv(request_action, Config)),
                   org_name = as_bin(?gv(org_name, Config)),
                   request_id = as_bin(?gv(request_id, Config)),
                   metrics = dict:new(),
                   upstream_prefixes = UpstreamPrefixes},
    send_start_metrics(State),
    %% register this worker with the monitor who will make us findable by ReqId and will
    %% clean up the mapping when we exit.
    register(State#state.request_id),
    {ok, State}.

handle_call(_, _From, State) ->
    {reply, unhandled, State}.

handle_cast({ctime_time, Label, {Time, Unit}}, #state{metrics=Metrics}=State) ->
    CTimer = fetch_ctimer(Label, Metrics),
    CTimer1 = update_ctimer(CTimer, {Time, Unit}),
    State1 = State#state{metrics = store_ctimer(Label, CTimer1, Metrics)},
    {noreply, State1};
handle_cast({report_metrics, EndTime, StatusCode}, #state{start_time = StartTime}=State) ->
    ReqTime = timer:now_diff(EndTime, StartTime) div 1000,
    do_report_metrics(ReqTime, StatusCode, State),
    {noreply, State};
handle_cast({alog, {_Level, _Label}=Key, Msg}, #state{metrics=Metrics}=State) ->
    ALog = fetch_alog(Key, Metrics),
    ALog1 = update_alog(ALog, Msg),
    State1 = State#state{metrics = store_alog(Key, ALog1, Metrics)},
    {noreply, State1};
handle_cast(stop_worker, State) ->
    {stop, normal, State};
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%
%% private functions
%%

-spec worker_ctime(req_id(), binary(), timing()) -> ignored | ok.
worker_ctime(ReqId, Label, {Time, Unit}) when Unit =:= ms; Unit =:= micros ->
    case find_stats_hero(ReqId) of
        not_found ->
            %% FIXME: should we log something here?
            ignored;
        Pid ->
            gen_server:cast(Pid, {ctime_time, Label, {Time, Unit}}),
            ok
    end.

-spec find_stats_hero(req_id()) -> pid() | not_found.
%% @doc Find the pid of the stats_hero worker associated with request ID `ReqId'
%%
%% If no worker process is found, the atom 'not_found' is returned.
%%
find_stats_hero(ReqId) when is_binary(ReqId) ->
    case ets:lookup(?SH_WORKER_TABLE, ReqId) of
        [] -> not_found;
        [{ReqId, Pid}] -> Pid
    end.

-spec find_req_id(pid()) -> req_id() | not_found.
%% @doc Find the request ID associated with the stats_hero worker given by `Pid'.
%%
%% If the pid does not map to a request ID, the atom 'not_found' is returned.
find_req_id(Pid) when is_pid(Pid) ->
    case ets:lookup(?SH_WORKER_TABLE, Pid) of
        [] -> not_found;
        [{Pid, ReqId}] -> ReqId
    end.

-spec register(binary()) -> ok.
register(ReqId) ->
    Self = self(),
    ets:insert(?SH_WORKER_TABLE, {Self, ReqId}),
    ets:insert(?SH_WORKER_TABLE, {ReqId, Self}),
    stats_hero_monitor:register(Self),
    ok.

-spec fetch_ctimer(binary(), dict()) -> #ctimer{}.
%% @doc Return the #ctimer{} in the `Metrics' dict with key `Label'. If no such #ctimer{}
%% exists, return a new record (but leave it to the caller to put this record back into the
%% Metrics dict if desired).
fetch_ctimer(Label, Metrics) ->
    case dict:find(Label, Metrics) of
        error ->
            %% Create a new ctimer. It is the caller's responsibility to make sure it ends
            %% up saved in the Metrics dict.
            #ctimer{};
        {ok, #ctimer{} = CTimer} ->
            %% match on record type so we crash if user mismatches labels and type.
            CTimer
    end.

-spec update_ctimer(#ctimer{}, timing()) -> #ctimer{}.
%% Add time to a #ctimer{}.  Units currently supported are milliseconds as 'ms' and
%% microseconds as 'micros'. Call count is increased each time this is called.
update_ctimer(#ctimer{}=CTimer, {AddTime, micros}) ->
    update_ctimer(CTimer, {AddTime div 1000, ms});
update_ctimer(#ctimer{count = Count, time = Time}, {AddTime, ms}) ->
    #ctimer{count = Count + 1, time = Time + AddTime}.

-spec store_ctimer(binary(), #ctimer{}, dict()) -> dict().
%% Put #ctimer{} back into the `Metrics' dict with key `Label'. This helper enforces some
%% types and abstracts dict details.
store_ctimer(Label, #ctimer{}=CTimer, Metrics) ->
    dict:store(Label, CTimer, Metrics).

-spec merge_ctimer(#ctimer{}, #ctimer{}) -> #ctimer{}.
%% When two #ctimers{} love each other, they make a new #ctimer{} summing their
%% corresponding count and time fields.
merge_ctimer(#ctimer{count = CountA, time = TimeA},
             #ctimer{count = CountB, time = TimeB}) ->
    #ctimer{count = CountA + CountB, time = TimeA + TimeB}.

%% Return #alog{} associated with `Key' or a a new #alog{} record. It is the callers
%% responsibility to update the `Metrics' dict.
fetch_alog(Key, Metrics) ->
    case dict:find(Key, Metrics) of
        error ->
            %% Create a new alog. It is the caller's responsibility to make sure it ends
            %% up saved in the Metrics dict.
            #alog{};
        {ok, #alog{} = Alog} ->
            %% match on record type so we crash if user mismatches labels and type.
            Alog
    end.

update_alog(#alog{message = MsgList}, NewMsg) ->
    #alog{message = [NewMsg|MsgList]}.

%% %% Extract the message from an append log as an iolist().
%% message(#alog{message = MsgList}) ->
%%     lists:reverse(MsgList).

store_alog(Label, #alog{}=ALog, Metrics) ->
    dict:store(Label, ALog, Metrics).

-spec hostname() -> binary().
hostname() ->
    FullyQualified = net_adm:localhost(),
    case string:chr(FullyQualified, $.) of
        0 -> list_to_binary(FullyQualified);
        Dot -> list_to_binary(string:substr(FullyQualified, 1, Dot - 1))
    end.

-spec send_start_metrics(#state{}) -> ok.
%% @doc Send start metrics to estatsd. These are all meters and are sent when the stats_hero
%% process is initialized.
send_start_metrics(#state{my_app = MyApp, my_host = MyHost,
                          request_label = ReqLabel, request_action = ReqAction,
                          org_name = OrgName,
                          estatsd_host = EstatsdHost, estatsd_port = EstatsdPort}) ->
    Stats = [{[MyApp, ".application.byOrgName.", OrgName], 1, "m"},
             {[MyApp, ".application.allRequests"], 1, "m"},
             {[MyApp, ".", MyHost, ".allRequests"], 1, "m"},
             {[MyApp, ".application.byRequestType.", ReqLabel, ".", ReqAction], 1, "m"}
            ],
    Payload = [ make_metric_line(M) || M <- Stats ],
    send_payload(EstatsdHost, EstatsdPort, Payload),
    ok.

%% @doc This is where we package up the accumulated data and send to estatsd prior to
%% terminating.
%%
%% The upstream requests are collapsed according to the upstream prefix list.
%%
do_report_metrics(ReqTime, StatusCode,
                  #state{my_app = MyApp,
                         my_host = MyHost,
                         request_label = ReqLabel,
                         request_action = ReqAction,
                         org_name = OrgName,
                         metrics = Metrics,
                         upstream_prefixes = Prefixes,
                         estatsd_host = EstatsdHost,
                         estatsd_port = EstatsdPort}) ->
    Stats = [{[MyApp, ".application.byStatusCode.", integer_to_list(StatusCode)], 1, "m"},
             {[MyApp, ".", MyHost, ".byStatusCode.", StatusCode], 1, "m"},
             {[MyApp, ".application.byOrgName.", OrgName], ReqTime, "h"},
             {[MyApp, ".application.allRequests"], ReqTime, "h"},
             {[MyApp, ".", MyHost, ".allRequests"], ReqTime, "h"},
             {[MyApp, ".application.byRequestType.", ReqLabel, ".", ReqAction], ReqTime, "h"}
            ],
    UpAggregates = aggregate_by_prefix(Metrics, Prefixes),
    Upstreams = upstreams_by_prefix(Metrics, Prefixes),
    UpstreamStats =  [ {[MyApp, ".upstreamRequests.", Upstream], CTime#ctimer.time, "h"}
                       || {Upstream, CTime} <- dict:to_list(UpAggregates) ++ Upstreams ],
    Payload = [ make_metric_line(M) || M <- Stats ++ UpstreamStats ],
    send_payload(EstatsdHost, EstatsdPort, Payload),
    ok.

%% make_log_tuples(ReqTime, #state{metrics = Metrics}) ->
%%     Ans = dict:fold(fun(Label, #ctimer{}=CTimer, Acc) ->
%%                             [A, B] = ctimer_to_list(Label, CTimer),
%%                             [A, B | Acc];
%%                        (_, _, Acc) -> Acc end, [], Metrics),
%%     [{<<"req_time">>, ReqTime}| Ans].

%% ctimer_to_list(Label, #ctimer{count = Count, time = Time}) when is_binary(Label) ->
%%     [{<<Label/binary, "_time">>, Time},
%%      {<<Label/binary, "_count">>, Count}].

upstreams_by_prefix(Metrics, Prefixes) ->
    dict:fold(fun(Key, #ctimer{}=Value, Acc) ->
                      case prefix_match(Key, Prefixes) of
                          false ->
                              Acc;
                          _Prefix ->
                              [{Key, Value}|Acc]
                      end;
                 (_Key, _Value, Acc) ->
                      Acc
              end, [], Metrics).

aggregate_by_prefix(Metrics, Prefixes) ->
    dict:fold(fun(Key, #ctimer{}=Value, Acc) ->
                      case prefix_match(Key, Prefixes) of
                          false ->
                              Acc;
                          Prefix ->
                              dict:update(Prefix,
                                          fun(#ctimer{}=CTimer) ->
                                                  merge_ctimer(CTimer, Value)
                                          end, Value, Acc)
                      end;
                 (_Key, _Value, Acc) ->
                      Acc
              end,
              dict:new(), Metrics).

prefix_match(Key, [Prefix|Rest]) ->
    case has_prefix(Prefix, Key) of
        true -> Prefix;
        false -> prefix_match(Key, Rest)
    end;
prefix_match(_Key, []) ->
    false.

has_prefix(P, S) ->
    Size = size(P),
    case S of
        <<P:Size/binary, _/binary>> -> true;
        _Else -> false
    end.

send_payload(Server, Port, Payload) ->
    Length = iolist_size(Payload),
    Packet = io_lib:format("1|~B~n~s", [Length, Payload]),
    {ok, Socket} = gen_udp:open(0),
    try
        ok = gen_udp:send(Socket, Server, Port, Packet)
    after
        gen_udp:close(Socket)
    end.

%% Note this only supports integer values, but that is the only type of value currently
%% being used.
make_metric_line({Key, Value, Type}) when is_integer(Value) ->
    io_lib:format("~s:~B|~s~n", [Key, Value, Type]).

as_bin(X) when is_list(X) ->
    iolist_to_binary(X);
as_bin(X) when is_binary(X) ->
    X.


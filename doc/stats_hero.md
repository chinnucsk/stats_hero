

# Module stats_hero #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)


stats_hero metric collector worker gen_server.
__Behaviours:__ [`gen_server`](gen_server.md).

__Authors:__ John Keiser ([`jkeiser@opscode.com`](mailto:jkeiser@opscode.com)), Seth Falcon ([`seth@opscode.com`](mailto:seth@opscode.com)).
<a name="description"></a>

## Description ##


This module implements the stats_hero worker, a gen_server used by a another process
(e.g. Webmachine request), to aggregate timing data and send it to estatsd.

<a name="types"></a>

## Data Types ##




### <a name="type-req_id">req_id()</a> ###



```
req_id() = binary()
```





### <a name="type-time_unit">time_unit()</a> ###



```
time_unit() = ms | micros
```





### <a name="type-timing">timing()</a> ###



```
timing() = {non_neg_integer(), <a href="#type-time_unit">time_unit()</a>}
```


<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#alog-3">alog/3</a></td><td>Append <code>Msg</code> to log identified by <code>Label</code> using the stats_hero worker found via the
specified <code>ReqId</code>.</td></tr><tr><td valign="top"><a href="#clean_worker_data-1">clean_worker_data/1</a></td><td>Remove pid/req_id mapping for the stats_hero worker given by <code>Pid</code>.</td></tr><tr><td valign="top"><a href="#code_change-3">code_change/3</a></td><td></td></tr><tr><td valign="top"><a href="#ctime-3">ctime/3</a></td><td>Update cummulative timer identified by <code>Label</code>.</td></tr><tr><td valign="top"><a href="#handle_call-3">handle_call/3</a></td><td></td></tr><tr><td valign="top"><a href="#handle_cast-2">handle_cast/2</a></td><td></td></tr><tr><td valign="top"><a href="#handle_info-2">handle_info/2</a></td><td></td></tr><tr><td valign="top"><a href="#init-1">init/1</a></td><td></td></tr><tr><td valign="top"><a href="#init_storage-0">init_storage/0</a></td><td>Initialize the ETS storage for mapping ReqId to/from stats_hero worker Pids.</td></tr><tr><td valign="top"><a href="#read_alog-2">read_alog/2</a></td><td>Retrieve log message stored at <code>Label</code> for the worker associated with <code>ReqId</code>.</td></tr><tr><td valign="top"><a href="#report_metrics-2">report_metrics/2</a></td><td>Send accumulated metric data to estatsd.</td></tr><tr><td valign="top"><a href="#snapshot-2">snapshot/2</a></td><td>Return a snapshot of currently tracked metrics.</td></tr><tr><td valign="top"><a href="#start_link-1">start_link/1</a></td><td>Start your personalized stats_hero process.</td></tr><tr><td valign="top"><a href="#stop_worker-1">stop_worker/1</a></td><td>Stop the worker with the specified <code>Pid</code>.</td></tr><tr><td valign="top"><a href="#terminate-2">terminate/2</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="alog-3"></a>

### alog/3 ###


```
alog(ReqId::binary(), Label::binary(), Msg::iolist()) -&gt; ok | not_found
```

<br></br>


Append `Msg` to log identified by `Label` using the stats_hero worker found via the
specified `ReqId`.
<a name="clean_worker_data-1"></a>

### clean_worker_data/1 ###


```
clean_worker_data(Pid::pid()) -&gt; ok | not_found
```

<br></br>



Remove pid/req_id mapping for the stats_hero worker given by `Pid`.


This is intended to be called by a process that monitors all stats_hero workers and
cleans up their data when they exit. Returns `not_found` if no data was found in the table
and `ok` otherwise.
<a name="code_change-3"></a>

### code_change/3 ###

`code_change(OldVsn, State, Extra) -> any()`


<a name="ctime-3"></a>

### ctime/3 ###


```
ctime(ReqId::<a href="#type-req_id">req_id()</a>, Label::term(), Fun::fun(() -> any()) | <a href="#type-timing">timing()</a>) -> any()
```

<br></br>



Update cummulative timer identified by `Label`.



If `Fun` is a fun/0, the metric is updated with the time required to execute `Fun()` and
its value is returned. You can also specify a time explicitly in milliseconds or
microseconds as `{Time, ms}` or `{Time, micros}`, respectively. The `ReqId` is used to
find the appropriate stats_hero worker process. If no such process is found, the timing
data is thrown away.



You probably want to use the `?SH_TIME` macro in stats_hero.hrl instead of calling this
function directly.



`?SH_TIME(ReqId, Mod, Fun, Args)`



The `Mod` argument will be mapped to an upstream label as defined in this module (one of
'rdbms', 'couchdb', 'authz', or 'solr'). If `Mod` is not recognized, we currently raise
an error, but this could be changed to just accept it as part of the label for the metric
as-is.



The specified MFA will be evaluated and its execution time sent to the stats_hero
worker. This macro returns the value returned by the specified MFA.  NOTE: `Args` must be
a parenthesized list of args. This is non-standard, but allows us to avoid an apply and
still get by with a simple macro.


Here's an example call:

```
      ?SH_TIME(ReqId, chef_db, fetch_node, (Ctx, OrgName, NodeName))
```

And here's the intended expansion:

```
  stats_hero:ctime(ReqId, <<"rdbms.fetch_node">>,
                   fun() -> chef_db:fetch_node(Ctx, OrgName, NodeName) end)
```


`ReqId`: binary(); `Mod`: atom(); `Fun`: atom();
`Args`: '(a1, a2, ..., aN)'

<a name="handle_call-3"></a>

### handle_call/3 ###

`handle_call(X1, From, State) -> any()`


<a name="handle_cast-2"></a>

### handle_cast/2 ###

`handle_cast(Request, State) -> any()`


<a name="handle_info-2"></a>

### handle_info/2 ###

`handle_info(Info, State) -> any()`


<a name="init-1"></a>

### init/1 ###

`init(Config) -> any()`


<a name="init_storage-0"></a>

### init_storage/0 ###


```
init_storage() -&gt; atom()
```

<br></br>



Initialize the ETS storage for mapping ReqId to/from stats_hero worker Pids.


This should be called by the supervisor that supervises the stats_hero_monitor process.
<a name="read_alog-2"></a>

### read_alog/2 ###


```
read_alog(ReqId::pid() | binary(), Label::binary()) -&gt; iolist() | not_found
```

<br></br>


Retrieve log message stored at `Label` for the worker associated with `ReqId`.
<a name="report_metrics-2"></a>

### report_metrics/2 ###


```
report_metrics(ReqId::pid() | binary(), StatusCode::integer()) -&gt; not_found | ok
```

<br></br>



Send accumulated metric data to estatsd. `ReqId` is used to find the appropriate
stats_hero worker process. `StatusCode` is an integer (usually an HTTP status code) used
in some of the generated metric labels. The atom `not_found` is returned if no worker
process was found.


The time reported for the entire request is the time between worker start and this call.
<a name="snapshot-2"></a>

### snapshot/2 ###


```
snapshot(ReqId::pid() | binary(), Type::agg | no_agg | all) -&gt; [{binary(), integer()}]
```

<br></br>



Return a snapshot of currently tracked metrics. The return value is a proplist with
binary keys and integer values. If [`stats_hero:report_metrics/2`](stats_hero.md#report_metrics-2) has already been
called, the request time recorded at the time of that call is returned in the
`<<"req_time">>` key. Otherwise, the request time thus far is returned, but not stored.


This function is useful for obtaining metrics related to upstream service calls for
logging. If no stats_hero worker is associated with `ReqId`, then an empty list is
returned.

<a name="start_link-1"></a>

### start_link/1 ###

`start_link(Config) -> any()`


Start your personalized stats_hero process.


`Config` is a proplist with keys: request_label, request_action, upstream_prefixes,
my_app, org_name, and request_id.

<a name="stop_worker-1"></a>

### stop_worker/1 ###


```
stop_worker(ReqId::pid() | binary()) -&gt; ok
```

<br></br>



Stop the worker with the specified `Pid`.


This will remove the worker's entries from the ETS table and then send an asynchronous
stop message to the worker.

<a name="terminate-2"></a>

### terminate/2 ###

`terminate(Reason, State) -> any()`



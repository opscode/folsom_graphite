%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% @copyright 2012 Opscode Inc.

-module(folsom_graphite_worker).

-behaviour(gen_server).

-include_lib("eunit/include/eunit.hrl").

-record(state, {send_interval :: integer(),
                prefix :: string(),
                reset_metrics :: atom()
               }).

-define(METER_FIELDS, [{count, "count"},
                       {one, "1MinuteRate"},
                       {five, "5MinuteRate"},
                       {fifteen, "15MinuteRate"},
                       {mean, "meanRate"}]).
-define(HISTOGRAM_FIELDS, [{min, "min"},
                           {max, "max"},
                           {arithmetic_mean, "mean"},
                           {standard_deviation, "stddev"}]).
-define(PERCENTILE_FIELDS, [{75, "75percentile"},
                            {95, "95percentile"},
                            {99, "99percentile"},
                            {999, "999percentile"}]).
%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/4
        ]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Prefix, Application, SendInterval, ResetMetrics) ->
    gen_server:start_link(?MODULE, [Prefix, Application, SendInterval, ResetMetrics], []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([Prefix, Application, SendInterval, ResetMetrics]) ->
    State = #state{send_interval = SendInterval,
                   prefix = prefix(Prefix, Application),
                   reset_metrics = ResetMetrics
                   },
    timer:send_after(SendInterval, publish),
    {ok, State}.

handle_call(Request, _From, State) ->
    lager:info("Unepected message: handle_call ~p", [Request]),
    {noreply, ok, State}.

handle_cast(Msg, State) ->
    lager:info("Unepected message: handle_cast ~p", [Msg]),
    {noreply, State}.

handle_info(publish, #state{send_interval = SendInterval} = State) ->
    ok = publish_to_graphite(State),
    timer:send_after(SendInterval, publish),
    {noreply, State};
handle_info(Info, State) ->
    lager:info("Unepected message: handle_info ~p", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec hostname() -> string().
hostname() ->
    {ok, Hostname} = inet:gethostname(),
    folsom_graphite_util:sanitize(Hostname).

-spec publish_to_graphite(#state{}) -> ok.
publish_to_graphite(#state{prefix = Prefix, reset_metrics = ResetMetrics}) ->
    Timestamp = make_timestamp(),
    %% In some cases we want to reset metrics in folsom,
    %% so the persisted values correctly reflect the
    %% time period.
    %% This is a configuration option. See folsom_graphite_sup.erl.
    F = case ResetMetrics of
        true ->
            fun({Name, _} = E, A) ->
                R = extract_value(E, A),
                folsom_metrics:delete_metric(Name),
                R
            end;
        _ ->
            fun(E, A) ->
                extract_value(E, A)
            end
    end,

    {_, _, Lines} = lists:foldl(F, {Prefix, Timestamp, []}, folsom_metrics:get_metrics_info()),
    folsom_graphite_sender:send(Lines),
    ok.

extract_value({Name, [{type, histogram}]}, {Prefix, Timestamp, Acc}) ->
    Values = folsom_metrics:get_histogram_statistics(Name),
    {_, _, Acc1} = extract_values(Name, Values, ?HISTOGRAM_FIELDS, {Prefix, Timestamp, Acc}),
    Percentiles = proplists:get_value(percentile, Values),
    extract_values(Name, Percentiles, ?PERCENTILE_FIELDS, {Prefix, Timestamp, Acc1});
extract_value({Name, [{type, gauge}]}, {Prefix, Timestamp, Acc}) ->
    Value = folsom_metrics:get_metric_value(Name),
    {Prefix, Timestamp, [folsom_graphite_util:graphite_format(Prefix, Timestamp, {io_lib:format("~s.value", [Name]), Value})|Acc]};
extract_value({Name, [{type, meter}]}, {Prefix, Timestamp, Acc}) ->
    Values = folsom_metrics:get_metric_value(Name),
    extract_values(Name, Values, ?METER_FIELDS, {Prefix, Timestamp, Acc});
extract_value({Name, [{type, counter}]}, {Prefix, Timestamp, Acc}) ->
    Value = folsom_metrics:get_metric_value(Name),
    {Prefix, Timestamp, [folsom_graphite_util:graphite_format(Prefix, Timestamp, {io_lib:format("~s.count", [Name]), Value})|Acc]}.

extract_values(Name, Values, Fields, {Prefix, Timestamp, StartAcc}) ->
    {Prefix, Timestamp, lists:foldl(fun({MetricName, PrettyName}, Acc) ->
                                            V = proplists:get_value(MetricName, Values),
                                            [folsom_graphite_util:graphite_format(Prefix, Timestamp, {io_lib:format("~s.~s",[Name, PrettyName]), V})| Acc]
                                    end,
                                    StartAcc,
                                    Fields)}.

-spec make_timestamp() -> non_neg_integer().
make_timestamp() ->
    {MegaSecs, Secs, _Microsecs} = os:timestamp(),
    integer_to_list(MegaSecs*1000000 + Secs).

-spec append_hostname(Prefix :: string()) -> string().
append_hostname(Prefix) ->
    string:join([Prefix, hostname()], ".").

-spec prefix(Prefix :: string(),
             Application :: string() | undefined) -> string().
prefix(Prefix, undefined) ->
    append_hostname(folsom_graphite_util:sanitize(Prefix));
prefix(Prefix, Application) ->
    append_hostname(string:join([folsom_graphite_util:sanitize(Prefix),
                                 folsom_graphite_util:sanitize(Application)],".")).


%% -------------------------------------------------------------------
%%
%% basho_bench: Benchmarking Suite
%%
%% Copyright (c) 2009-2010 Basho Techonologies
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.    
%%
%% -------------------------------------------------------------------
-module(basho_bench_app).

-behaviour(application).

%% API
-export([start/0,
         stop/0,
         is_running/0,
         halt_or_kill/0]).

%% Application callbacks
-export([start/2, stop/1]).


%% ===================================================================
%% API
%%===================================================================

start() ->
    %% Redirect all SASL logging into a text file
    case application:get_env(basho_bench,app_run_mode) of
       {ok, included} ->
          %%Make sure sasl and crypto is available
          true=lists:keymember(sasl,1,application:which_applications()),
          true=lists:keymember(crypto,1,application:which_applications()),
          
          %% Start up our application
          application:start(basho_bench);
       NotInc when NotInc == {ok, standalone} orelse NotInc == undefined ->
          application:load(sasl),
          application:set_env(sasl, sasl_error_logger, {file, "log.sasl.txt"}),
          %% Make sure crypto is available
          ensure_started([sasl, crypto]),

          _ = ets:new(final_cdf, [public, named_table, set, {write_concurrency, true}]),
          _ = ets:new(percv_cdf, [public, named_table, set, {write_concurrency, true}]),

          %% Start up our application -- mark it as permanent so that the node
          %% will be killed if we go down
          application:start(basho_bench, permanent)
    end.

stop() ->
    ok = basho_bench_fsm_worker:cleanup(basho_bench_sup:workers()),
    %ok = basho_bench_fsm_worker:suspend(basho_bench_sup:workers()),
    write_cdf(),
    application:stop(basho_bench).

is_running() ->
    application:get_env(basho_bench_app, is_running) == {ok, true}.

halt_or_kill() ->
    lager:info("Halt or kill..."),
    %% If running standalone, halt and kill node.  Otherwise, just
    %% kill top supervisor.
    case application:get_env(basho_bench,app_run_mode) of
        {ok, included} ->
            exit(whereis(basho_bench_sup),kill);
        _ ->
            init:stop()
    end.

%% ===================================================================
%% Application callbacks
%%===================================================================

start(_StartType, _StartArgs) ->
    {ok, Pid} = basho_bench_sup:start_link(),
    ets:new(load_info, [set, public, named_table]),
    basho_bench_sup:start_children(basho_bench_config:get(concurrent)),
    application:set_env(basho_bench_app, is_running, true),
    ok = basho_bench_stats:run(),
    ok = basho_bench_measurement:run(),
    %_Children = basho_bench_sup:workers(),
    ok = basho_bench_fsm_worker:run(basho_bench_sup:workers()),
    {ok, Pid}.


stop(_State) ->
    %% intentionally left in to show where worker profiling start/stop calls go.
    %% eprof:stop_profiling(),
    %% eprof:analyze(total),
    %% eprof:log("bb.eprof"),
    ok.

%% ===================================================================
%% Internal functions
%% ===================================================================

write_cdf() ->
    [{start_time, StartTime}] = ets:lookup(final_cdf, start_time),
    StartTimeInt = to_integer(StartTime) + 1000000*20, 
    EndTimeInt = to_integer(StartTime) + basho_bench_config:get(duration)*1000000 - 1000000*20, 
    true = ets:delete(final_cdf, start_time),

    PercvCdf = ets:tab2list(percv_cdf),
    FinalCdf = ets:tab2list(final_cdf),
    PercvCdfSort = lists:sort(PercvCdf),
    FinalCdfSort = lists:sort(FinalCdf),

    {ok, PercvLatFile} = file:open("percv_latency", [raw, binary, write]),
    %file:write(PercvLatFile,  io_lib:format("StartTime is ~w \n", [to_integer(StartTime)/1000000])),
    lists:foreach(fun({{_Count, _}, LatList}) ->
                output_when(StartTimeInt, EndTimeInt, LatList, PercvLatFile)
                end, PercvCdfSort),
    %file:write(PercvLatFile,  io_lib:format("EndTimeInt is ~w, EndTime is ~w \n", [EndTimeInt/1000000+15, to_integer(now())/1000000])),
    file:close(PercvLatFile),

    {ok, FinalLatFile} = file:open("final_latency", [raw, binary, write]),
    %file:write(FinalLatFile,  io_lib:format("StartTime is ~w \n", [to_integer(StartTime)/1000000])),
    lists:foreach(fun({{_Count, _}, LatList}) ->
                output_when(StartTimeInt, EndTimeInt, LatList, FinalLatFile)
                end, FinalCdfSort),
    %file:write(FinalLatFile,  io_lib:format("EndTimeInt is ~w, EndTime is ~w \n", [EndTimeInt/1000000+15, to_integer(now())/1000000])),
    file:close(FinalLatFile).

output_when(_Start, _End, [], _File) ->
    ok;
output_when(Start, End, [{Time, Latency}|Rest], File) ->
    IntTime = to_integer(Time),
    case IntTime > Start of
        true -> case IntTime < End of
                    true -> file:write(File,  io_lib:format("~w\n", [Latency])); 
                    false -> output_when(Start, End, Rest, File) 
                end;
        false -> ok
    end.

ensure_started(Applications) when is_list(Applications) ->
  [ensure_started(Application) || Application <- Applications];

ensure_started(Application) ->
  case application:start(Application) of
    ok ->
      ok;
    {error, {already_started, Application}} ->
      ok;
    Error ->
      throw(Error)
  end.

to_integer({A, B, C}) ->
    (A * 1000000 + B) * 1000000 + C.

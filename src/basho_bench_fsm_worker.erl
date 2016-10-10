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
-module(basho_bench_fsm_worker).

-behaviour(gen_fsm).
-define(DELTA, 100000).

%% API
-export([start_link/1,
         run/1,
         cleanup/2,
         suspend/1,
         stop/1]).

%% gen_server callbacks
-export([init/1, execute/2, suspended/2, 
         handle_info/3,
         handle_event/3,
         handle_sync_event/4,
         terminate/3, code_change/4]).

-record(state, { id,
    		 name,
                 keygen,
                 valgen,
                 think_time,
                 driver,
                 auto_tune,
                 driver_state,
                 shutdown_on_error,
                 ops,
                 all_update,
                 todo_op,
                 specula_length,
                 mode,
                 rate_sleep,
                 seed,
                 %%
                 last_update_cnt,
                 update_seq,
                 read_seq,
                 op_type,
                 specula_txs,
                 read_txs,
                 msg_id,
                 final_cdf,
                 specula_cdf, 
                 do_specula,
                 store_cdf,
                 %op_list,
                 %cdf,
                 txn_start,
                 abort_stat,
                 transition,
                 ops_len,
                 rng_seed}).

-include("basho_bench.hrl").

%% ====================================================================
%% API
%% ====================================================================

start_link(Id) ->
    Name = list_to_atom("FSM"++integer_to_list(Id)),
    %lager:warning("Starting with name ~w", [Name]),
    gen_fsm:start_link({local, Name}, ?MODULE, [Id, Name], []).

run(Pids) ->
    [ok = gen_fsm:send_event(Pid, start) || Pid <- Pids],
    ok.

cleanup(Children, Stat0) ->
    Failed = lists:foldl(fun(C, F) -> 
		    case catch ( gen_fsm:send_event(C, {'CLEANUP', self()})) of
                ok -> F;
                _ -> [C|F] 
		    end end, [], Children),
    {Stat, RecvNames} = lists:foldl(fun(_, {OldStat, RNames}) -> 
                receive {Name, {stat, Value}} -> OldStat = nil, {Value, [Name|RNames]};
                        {Name, cleaned_up} -> {OldStat, [Name|RNames]}
		        after
			    100 ->
			      {OldStat, RNames}
                end end, 
                {Stat0, []}, Children),
    RemainNames = Children -- RecvNames -- Failed,
    case RemainNames of
	[] -> Stat;
	_ -> 
    	     lager:info("So many has not finished... w!!!!", [RemainNames]),
	     %cleanup(RemainNames, Stat)
	     Stat
    end.

suspend(Pids) ->
    [ok = gen_fsm:send_event(Pid, 'SUSPEND') || Pid <- Pids],
    ok.

stop(Pids) ->
   %lager:warning("Sending stop"),
    [ok = gen_fsm:send_event(Pid, {'EXIT', normal}) || Pid <- Pids],
    ok.

%% ====================================================================
%% gen_server callbacks
%% ====================================================================

init([Id, Name]) ->
    %Name = list_to_atom("FSM"++integer_to_list(Id)),
    %% Setup RNG seed for worker sub-process to use; incorporate the ID of
    %% the worker to ensure consistency in load-gen
    %%
    %% NOTE: If the worker process dies, this obviously introduces some entroy
    %% into the equation since you'd be restarting the RNG all over.
    %%
    %% The RNG_SEED is static by default for replicability of key size
    %% and value size generation between test runs.


    %process_flag(trap_exit, true),
    {A1, A2, A3} =
        case basho_bench_config:get(rng_seed, {42, 23, 12}) of
            {Aa, Ab, Ac} -> {Aa, Ab, Ac};
            now -> now()
        end,

    RngSeed = {A1+Id, A2+Id, A3+Id},

    %% Pull all config settings from environment
    Driver  = basho_bench_config:get(driver),
    Ops     = ops_tuple(),
    ShutdownOnError = basho_bench_config:get(shutdown_on_error, false),
   
    ThinkTime = case basho_bench_config:get(think_time, 0) of
                Time -> Time
            end,

    AutoTune = case basho_bench_config:get(auto_tune, false) of
                true -> true;
                false -> false
            end,

    {ToDoOp, Transition} = case basho_bench_config:get(transition, false) of
                true -> LoadTransition = rubis_tool:load_transition(), 
                     {{[], home}, LoadTransition}; 
                _ -> {Info, FirstOpTag} = element(random:uniform(size(Ops)), Ops), 
                     {{Info, FirstOpTag}, undef}
            end,

    %lager:info("Transition is ~w", [dict:to_list(Transition)]),
    %% Finally, initialize key and value generation. We pass in our ID to the
    %% initialization to enable (optional) key/value space partitioning
    KeyGen = basho_bench_keygen:new(basho_bench_config:get(key_generator), Id),
    ValGen = basho_bench_valgen:new(basho_bench_config:get(value_generator), Id),
    Now = now(),
    AllUpdate = basho_bench_config:get(all_update, false),

    State = #state { id = Id, keygen = KeyGen, valgen = ValGen,
                     driver = Driver, %cdf=CDF,
                     shutdown_on_error = ShutdownOnError,
                     ops = Ops, ops_len = size(Ops),
                     rng_seed = RngSeed,
                     think_time = ThinkTime,
                     auto_tune = AutoTune,
                     do_specula = basho_bench_config:get(do_specula, false),
                     all_update = AllUpdate, 
                     op_type = get_op_type(ToDoOp, AllUpdate),
	    	         name=Name,
                     specula_txs=[],
                     specula_length = 0,
                     seed=Now,
                     read_txs=[],
                     abort_stat={0,0},
                     update_seq=0,
                     read_seq=0,
                     store_cdf = {1, ignore, basho_bench_config:get(store_to_table, 5000)*1000},
                     last_update_cnt=0,
                     msg_id=0,
                     specula_cdf=[],
                     final_cdf=[],
                     transition = Transition,
                     todo_op = ToDoOp},

    {_, OpName} = ToDoOp,

    State1 = case get_op_type(ToDoOp, AllUpdate) of
                update -> State#state{specula_txs=[{1, OpName, Now, ignore}], update_seq=1, last_update_cnt=1}; 
                read -> State#state{read_txs=[{1, Now, OpName}], read_seq=1}
             end,

    %% Use a dedicated sub-process to do the actual work. The work loop may need
    %% to sleep or otherwise delay in a way that would be inappropriate and/or
    %% inefficient for a gen_server. Furthermore, we want the loop to be as
    %% tight as possible for peak load generation and avoid unnecessary polling
    %% of the message queue.
    %%
    %% Link the worker and the sub-process to ensure that if either exits, the
    %% other goes with it.
    %WorkerPid = spawn_link(fun() -> worker_init(State1) end),
    %WorkerPid ! {init_driver, self()},
    %receive
    %    driver_ready ->
    %        ok
    %end,
    Driver = State#state.driver,
    DriverState = case catch(Driver:new(State#state.id)) of
                  {ok, DState} ->
                      DState;
                  Error ->
                      ?FAIL_MSG("Failed to initialize driver ~p: ~p\n", [Driver, Error]),
                      undefined % Make erlc happy
              end,

    %% If the system is marked as running this is a restart; queue up the run
    %% message for this worker
    case basho_bench_app:is_running() of
        true ->
            ?WARN("Restarting crashed worker.\n", []),
            gen_fsm:send_event(self(), start);
        false ->
            ok
    end,
    random:seed(State#state.rng_seed),
    %{Mode, RateSleep} = case basho_bench_config:get(mode) of max -> ?INFO("Starting MAX worker: ~p\n", [self()]), {max, 0};
    %                                                    {rate, max} -> ?INFO("Starting MAX worker: ~p\n", [self()]), {max, 0};
    %                                                    {rate, Rate} ->  ?INFO("Starting ~w ms/req fixed rate worker: ~p\n", [1000/Rate, self()]), {rate, Rate/1000}
    %                end, 
    {Mode, RateSleep} = case basho_bench_config:get(mode) of max ->  {max, 0};
                                                        {rate, max} ->  {max, 0};
                                                        {rate, Rate} ->  {rate, Rate/1000}
                    end, 

    {ok, execute, State1#state{driver_state=DriverState, mode=Mode, rate_sleep=RateSleep}}.

execute(start, State=#state{mode=Mode, rate_sleep=RateSleep, store_cdf=StoreCdf, id=Id}) ->
    {Count, ignore, Period} = StoreCdf, 
    case Mode of
        max -> ok; 
        rate -> timer:sleep(trunc(basho_bench_stats:exponential(RateSleep)))
    end,
    case Id of
        1 -> ets:insert(final_cdf, {start_time, os:timestamp()});
        _ -> ok
    end,
    worker_next_op(State#state{store_cdf={Count, os:timestamp(), Period}});

execute({specula_length, NewLength}, State) ->
    worker_next_op(State#state{specula_length=NewLength});

execute(timeout, State=#state{mode=Mode, rate_sleep=RateSleep}) ->
    case Mode of
        max -> ok; 
        rate -> timer:sleep(trunc(basho_bench_stats:exponential(RateSleep)))
    end,
    worker_next_op(State);

execute({final_abort, NewMsgId, TxId, AbortedReads, FinalCommitUpdates, FinalCommitReads}, 
        State=#state{msg_id=MsgId, final_cdf=FinalCdf, specula_cdf=SpeculaCdf, specula_txs=SpeculaTxs,
            read_txs=ReadTxs, update_seq=PreviousSeq, abort_stat=AbortStat, todo_op=ToDoOp}) ->
    %lager:warning("Got final abort msg, NewMsgId is ~w, OldMsgId is ~w", [NewMsgId, MsgId]),
    NewMsgId = MsgId + 1,
    {FinalCdf1, SpeculaCdf1, SpeculaTxs1} =
        commit_updates(FinalCdf, SpeculaCdf, FinalCommitUpdates, SpeculaTxs, [], os:timestamp()),
    ReadTxs1 = finalize_reads(lists:sort(FinalCommitReads), ReadTxs, [], ok),
    ReadTxs2 = finalize_reads(lists:sort(AbortedReads), ReadTxs1, [], {error, specula_abort}),
    {tx_id, _, _, _, TxSeq} = TxId,
    {StartTime, {TxSeq, OpName}} = find_specula_tx(TxSeq, SpeculaTxs1),
    %lager:warning("previous seq is ~w, now seq is ~w", [PreviousSeq, TxSeq]),
    case (TxSeq =< PreviousSeq) of
	true -> 
	    {PreviousOps, _} = ToDoOp,
            {Sum, Cnt} = AbortStat,	
            AbortStat1 = {Sum+timer:now_diff(os:timestamp(), StartTime), Cnt+1},
	    {next_state, execute, State#state{final_cdf=FinalCdf1, specula_cdf=SpeculaCdf1, specula_txs=SpeculaTxs1, read_txs=ReadTxs2,
		    msg_id=NewMsgId, update_seq=TxSeq, todo_op={PreviousOps, OpName}, abort_stat=AbortStat1, seed=StartTime, op_type=update}, 0};
	false ->
	    {next_state, execute, State, 0}
    end;

execute({'EXIT', Reason}, State) ->
    case Reason of
        normal ->
            %% Clean shutdown of the worker; spawn a process to terminate this
            %% process via the supervisor API and make sure it doesn't restart.
            lager:info("Stopping for normal"),
            %% TODO: This is removed, but not sure if it is OK
            %spawn(fun() -> stop_worker(State#state.sup_id) end),
	        (catch (State#state.driver):terminate({'EXIT', Reason}, State#state.driver_state)),
            {stop, normal, State};
	    cleanup ->
	        lager:info("Stopping for cleaning up"),
	        (catch (State#state.driver):terminate({'EXIT', Reason}, State#state.driver_state)),
            {stop, normal, State};
        _ ->
	        lager:info("Stopping for other reasons"),
	        (catch (State#state.driver):terminate({'EXIT', Reason}, State#state.driver_state)),
            %% Worker process exited for some other reason; stop this process
            %% as well so that everything gets restarted by the sup
            {stop, normal, State}
    end;

execute({'CLEANUP', Sender}, State=#state{store_cdf=StoreCdf, id=Id, name=Name, final_cdf=FinalCdf, abort_stat=AbortStat, specula_cdf=SpeculaCdf}) ->
    {Cnt, _Start, _Period} = StoreCdf,
    ets:insert(final_cdf, {{Cnt, State#state.id}, FinalCdf}), 
    ets:insert(percv_cdf, {{Cnt, State#state.id}, SpeculaCdf}),
    ets:insert(abort_stat, {{abort_stat, State#state.id}, AbortStat}),
    case Id of 
        1 ->
            Value = (State#state.driver):get_stat(State#state.driver_state),
            Sender ! {Name, {stat, Value}};
        _ ->
            Sender ! {Name, cleaned_up}
    end,
    (catch (State#state.driver):terminate(haha, State#state.driver_state)),
    {stop, normal, State};

execute('SUSPEND', State) ->
    (State#state.driver):terminate(haha, State#state.driver_state),
    {next_state, suspended, State, 50}.

suspended(_Msg, State) ->
    {next_state, suspended, State, 50}.

handle_info(_Info, _StateName, StateData) ->
    {stop, badmsg, StateData}.

handle_event(_Event, _StateName, StateData) ->
    {stop, badmsg, StateData}.

handle_sync_event(_Event, _From, _StateName, StateData) ->
    {stop, badmsg, StateData}.

terminate(_Reason, _, _State) ->
    ok.

code_change(_OldVsn, _, State, _Extra) ->
    {ok, execute, State}.


%% ====================================================================
%% Internal functions
%% ====================================================================

worker_next_op2(State, OpTag, Seed, update) ->
    AutoTune = State#state.auto_tune,
    SpeculaLength = State#state.specula_length,
    case AutoTune of
        true -> 
           catch (State#state.driver):run(OpTag, State#state.update_seq, State#state.msg_id, Seed, SpeculaLength, 
                                  State#state.driver_state);
        false ->
           catch (State#state.driver):run(OpTag, State#state.update_seq, State#state.msg_id, Seed, 
                                  State#state.driver_state)
    end;
worker_next_op2(State, OpTag, Seed, read) ->
    catch (State#state.driver):run(OpTag, State#state.read_seq, State#state.msg_id, Seed,
                          State#state.driver_state).

worker_next_op(State) ->
    Transition = State#state.transition,
    ToDo = State#state.todo_op,
    Seed = State#state.seed,
    ThinkTime = State#state.think_time,
    {PreviousOps, OpTag} = ToDo,
    FinalCdf0 = State#state.final_cdf,
    SpeculaCdf0 = State#state.specula_cdf,
    AbortStat = State#state.abort_stat,
    ReadTxs = State#state.read_txs,
    SpeculaTxs = State#state.specula_txs,
    LastUpdateCnt = State#state.last_update_cnt,
    CurrentOpType = State#state.op_type,
    UpdateSeq = State#state.update_seq,
    ReadSeq = State#state.read_seq,
    {Cnt, ExprStart, Period} = State#state.store_cdf,
    Result = worker_next_op2(State, OpTag, Seed, CurrentOpType),
    case Result of crash -> lager:warning("***************WTF, CRASHED!!!!************");
		   _ -> ok
    end,
    Now = os:timestamp(),
    TimerDiff = timer:now_diff(Now, ExprStart),
    AllUpdate = State#state.all_update,
    {FinalCdf, SpeculaCdf, StoreCdf} 
            = case (TimerDiff > Period*Cnt) or (Period*Cnt-TimerDiff < ?DELTA) of
                 true -> ets:insert(final_cdf, {{Cnt, State#state.id}, FinalCdf0}), 
                         ets:insert(percv_cdf, {{Cnt, State#state.id}, SpeculaCdf0}),
                         {[], [], {Cnt+1, ExprStart, Period}};
                false -> {FinalCdf0, SpeculaCdf0, {Cnt, ExprStart, Period}}
              end,
    case Result of
        {prev_state, DriverState} ->
            case PreviousOps of
                [] ->
                    case ThinkTime of rubis -> timer:sleep(rubis_tool:get_think_time({1,1}, Transition));
                                        _ -> timer:sleep(ThinkTime)
                    end, 
                    {next_state, execute, State#state {driver_state = DriverState, todo_op={[], 1}, final_cdf=FinalCdf, specula_cdf=SpeculaCdf, store_cdf=StoreCdf}, 0};
                [H|T] ->
                    case ThinkTime of rubis -> timer:sleep(rubis_tool:get_think_time({H,H}, Transition));
                                        _ -> timer:sleep(ThinkTime)
                    end,
                    {next_state, execute, State#state {driver_state = DriverState, todo_op={T, H}, final_cdf=FinalCdf, specula_cdf=SpeculaCdf, store_cdf=StoreCdf, seed=Now}, 0}
            end;
        %%% A no-op has finished
        {Res, DriverState} when Res == ok orelse element(1, Res) == ok ->
            AllUpdate = false,
            ReadTxs1 = finalize_reads([ReadSeq], ReadTxs, [], ok),
            NextOp = case Transition of
                        undef ->
                            element(random:uniform(State#state.ops_len), State#state.ops);
                        _ ->
                            {PreviousStates, CurrentOpName} = ToDo,
                            rubis_tool:get_next_state(PreviousStates, Transition, CurrentOpName)
                    end,
            {_, NextOpName} = NextOp,

            OpThinkTime = op_think_time(ToDo, NextOp, ThinkTime, Transition),
            case get_op_type(NextOpName, AllUpdate) of
                update ->
                    NextUpdateSeq = UpdateSeq + 1,
                    timer:sleep(OpThinkTime),
                    SpeculaTxs2 = SpeculaTxs ++ [{NextUpdateSeq, NextOpName, Now, ignore}],
                    %lager:warning("Update seq is ~w", [NextUpdateSeq]),
                    {next_state, execute, State#state{driver_state=DriverState, todo_op=NextOp, update_seq=NextUpdateSeq, last_update_cnt=NextUpdateSeq, store_cdf=StoreCdf, specula_cdf=SpeculaCdf, final_cdf=FinalCdf, specula_txs=SpeculaTxs2, read_txs=ReadTxs1, op_type=update, seed=Now}, 0};
                read ->
                    NextReadSeq = ReadSeq + 1,
                    timer:sleep(OpThinkTime),
                    ReadTxs2 = ReadTxs1 ++ [{NextReadSeq, Now, NextOpName}],
                    {next_state, execute, State#state{driver_state=DriverState, todo_op=NextOp, read_seq=NextReadSeq, 
                          read_txs=ReadTxs2, specula_cdf=SpeculaCdf, final_cdf=FinalCdf, store_cdf=StoreCdf, seed=Now, op_type=read}, 0}
            end;
        %% Committed! Means all previous update txns are committed. So just start a new txn
        {Res, {AbortedReads, FinalCommitUpdates, FinalCommitReads}, DriverState} when Res == ok orelse element(1, Res) == ok ->
            %case CurrentOpType of  update ->lager:warning("Op ~p committed", [UpdateSeq]); read -> ok end,
            %lager:warning("Op ~w finished, op type is ~w, specula txs are ~w", [OpTag, CurrentOpType, SpeculaTxs]),
            ReadTxs1 = finalize_reads(lists:sort(FinalCommitReads), ReadTxs, [], ok),
            ReadTxs2 = finalize_reads(lists:sort(AbortedReads), ReadTxs1, [], {error, specula_abort}),
            {FinalCdf1, SpeculaCdf1, SpeculaTxs1} = commit_updates(FinalCdf, SpeculaCdf, FinalCommitUpdates, SpeculaTxs, [], Now),
            CurrentOpType = update,
            {FinalCdf2, SpeculaCdf2, SpeculaTxs2} = commit_updates(FinalCdf1, SpeculaCdf1, [{UpdateSeq, Now}], SpeculaTxs1, [], Now),

            case LastUpdateCnt of
                UpdateSeq ->
                    SpeculaTxs2 = [],
                    NextOp = case Transition of
                                undef ->
                                    element(random:uniform(State#state.ops_len), State#state.ops);
                                _ ->
                                    {PreviousStates, CurrentOpName} = ToDo,
                                    rubis_tool:get_next_state(PreviousStates, Transition, CurrentOpName)
                            end,
                    {_, NextOpName} = NextOp,
                    OpThinkTime = op_think_time(ToDo, NextOp, ThinkTime, Transition),
                    timer:sleep(OpThinkTime),
                    case get_op_type(NextOpName, AllUpdate) of 
                        update ->
                            NextUpdateSeq = UpdateSeq +1,
                            SpeculaTxs4 = [{NextUpdateSeq, NextOpName, Now, ignore}], 
                            {next_state, execute, State#state { driver_state = DriverState, todo_op=NextOp, final_cdf=FinalCdf2, update_seq=NextUpdateSeq, 
                                specula_cdf=SpeculaCdf2, specula_txs=SpeculaTxs4, read_txs=ReadTxs2, last_update_cnt=NextUpdateSeq
                                , store_cdf=StoreCdf, op_type=update, seed=Now}, 0};
                        read ->
                            NextReadSeq = ReadSeq +1,
                            ReadTxs3 = ReadTxs2 ++ [{NextReadSeq, Now, NextOpName}], 
                            {next_state, execute, State#state { driver_state = DriverState, todo_op=NextOp, read_seq=NextReadSeq, read_txs=ReadTxs3, 
                                specula_txs=[], specula_cdf=SpeculaCdf2, final_cdf=FinalCdf2, store_cdf=StoreCdf, seed=Now, op_type=read}, 0}
                    end;
                _ ->
                    {NewSeed, NextOp} = get_next_op(SpeculaTxs, UpdateSeq+1, ToDo),
                    {next_state, execute, State#state{driver_state=DriverState, todo_op=NextOp, update_seq=UpdateSeq+1, op_type=update,
                                    specula_txs=SpeculaTxs2, read_txs=ReadTxs2, specula_cdf=SpeculaCdf1, final_cdf=FinalCdf1, store_cdf=StoreCdf, seed=NewSeed}, 0}
            end;
        {Res, DriverState} when Res == silent orelse element(1, Res) == silent ->
            %% Not implemented here
            {ok, State#state { driver_state = DriverState, todo_op=false}};
        %% Report final committed and final aborted.
        %% Wait for msg. Either retrying some ops if final abort msg is received or continue 
        {specula_commit, {AbortedReads, FinalCommitUpdates, FinalCommitReads}, DriverState} ->
            %case CurrentOpType of  update ->lager:warning("Op ~p specula-committed", [UpdateSeq]); read -> ok end,
            %lager:warning("Finall commit updates are ~w, FinallComm Reads are ~w", [FinalCommitUpdates, FinalCommitReads]),
            ReadTxs1 = finalize_reads(lists:sort(FinalCommitReads), ReadTxs, [], ok),
            ReadTxs2 = finalize_reads(lists:sort(AbortedReads), ReadTxs1, [], {error, specula_abort}),
            %case FinalCommitUpdates of [] -> ok; _ ->%lager:warning("FinalComm is ~w", [FinalCommitUpdates]) end,
            {FinalCdf1, SpeculaCdf1, SpeculaTxs1} = commit_updates(FinalCdf, SpeculaCdf, FinalCommitUpdates, SpeculaTxs, [], Now),
            %% If I am update: add my specula-commit time to the list
            %% If I am read: add my txid to the list
            SpeculaTxs2 = case CurrentOpType of read -> SpeculaTxs1; 
                                            update -> add_sctime_to_list(SpeculaTxs1, UpdateSeq, Now)
                                      end,
            %% Decide new operations to perform
            case LastUpdateCnt == UpdateSeq of
                true -> %% Already performing the last operation, can choose new operation freely 
                    NextOp = case Transition of
                          undef ->
                              element(random:uniform(State#state.ops_len), State#state.ops);
                          _ ->
                              {PreviousStates, CurrentOpName} = ToDo,
                              rubis_tool:get_next_state(PreviousStates, Transition, CurrentOpName)
                    end,
                    {_, NextOpName} = NextOp,
                    %TransNextOp = rubis_tool:translate_op(NextOpName),
                    OpThinkTime = op_think_time(ToDo, NextOp, ThinkTime, Transition), 
                    case get_op_type(NextOpName, AllUpdate) of 
                        update ->  
                            NextUpdateSeq = UpdateSeq + 1,
                            SpeculaTxs3 = SpeculaTxs2 ++ [{NextUpdateSeq, NextOpName, Now, ignore}],
                            %lager:warning("Update seq is ~w", [NextUpdateSeq]),
                            {next_state, execute, State#state{driver_state=DriverState, todo_op=NextOp, update_seq=NextUpdateSeq, last_update_cnt=NextUpdateSeq, store_cdf=StoreCdf, seed=Now, 
                                specula_txs=SpeculaTxs3, read_txs=ReadTxs2, specula_cdf=SpeculaCdf1, final_cdf=FinalCdf1, op_type=update}, OpThinkTime};
                        read ->
                            NextReadSeq = ReadSeq + 1,
                            ReadTxs3 = ReadTxs2 ++ [{NextReadSeq, Now, NextOpName}],
                            {next_state, execute, State#state{driver_state=DriverState, todo_op=NextOp, read_seq=NextReadSeq, 
                                  specula_txs=SpeculaTxs2, read_txs=ReadTxs3, specula_cdf=SpeculaCdf1, final_cdf=FinalCdf1
                                , store_cdf=StoreCdf, op_type=read, seed=Now}, OpThinkTime}
                    end;
                false -> %% Should redo previous operations!!! 
                    {NewSeed, NextOp} = get_next_op(SpeculaTxs, UpdateSeq+1, ToDo),
                    %lager:warning("Update seq is ~w", [UpdateSeq+1]),
                    {next_state, execute, State#state{driver_state=DriverState, todo_op=NextOp, update_seq=UpdateSeq+1, op_type=update,
                                    specula_txs=SpeculaTxs2, read_txs=ReadTxs2, specula_cdf=SpeculaCdf1, final_cdf=FinalCdf1, store_cdf=StoreCdf, seed=NewSeed}, 0}
            end;
        %% Report abort of all cascaded txns, including the current one; also report commits of all committed.
        %% Retry txns from the aborted one.
        {cascade_abort, {AbortedTxId, AbortedReads, FinalCommitUpdates, FinalCommitReads}, DriverState} ->
            %case CurrentOpType of  update ->lager:warning("Op ~p cascade-aborted", [UpdateSeq]); read -> ok end,
           %lager:warning("Cascade abort!!! Specula txs are ~w, abortedtx id is ~w, op aborted ~w, AbortedReads are ~w, FinalCommUpates ~w, FinalCommReads ~w", [SpeculaTxs, AbortedTxId, OpTag, AbortedReads, FinalCommitUpdates, FinalCommitReads]),
            State#state.shutdown_on_error andalso
                erlang:send_after(500, basho_bench,
                                  {shutdown, "Shutdown on errors requested", 1}),
            ReadTxs1 = finalize_reads(lists:sort(FinalCommitReads), ReadTxs, [], ok),
            ReadTxs2 = finalize_reads(lists:sort(AbortedReads), ReadTxs1, [], {error, specula_abort}),
            {FinalCdf1, SpeculaCdf1, SpeculaTxs1} = commit_updates(FinalCdf, SpeculaCdf, FinalCommitUpdates, SpeculaTxs, [], Now),
            
            {StartTime, {RetryOpSeq, NextOpName}} = find_specula_tx(AbortedTxId, SpeculaTxs1),
            {Sum, Count} = AbortStat,
            AbortStat1 = {timer:now_diff(Now, StartTime)+Sum, Count+1},
           %lager:warning("Cascading abort: previous seq is ~w, retry op seq is ~w, op name is ~w", [UpdateSeq, RetryOpSeq, NextOpName]),
            {next_state, execute, State#state{driver_state=DriverState, todo_op={RetryOpSeq, NextOpName}, update_seq=RetryOpSeq, op_type=update, specula_txs=SpeculaTxs1, read_txs=ReadTxs2, abort_stat=AbortStat1, specula_cdf=SpeculaCdf1, final_cdf=FinalCdf1, seed=StartTime, store_cdf=StoreCdf}, 0};
        {aborted, {AbortedReads, FinalCommitUpdates, FinalCommitReads}, DriverState} ->
            State#state.shutdown_on_error andalso
                erlang:send_after(500, basho_bench,
                                  {shutdown, "Shutdown on errors requested", 1}),
            ReadTxs1 = finalize_reads(lists:sort(FinalCommitReads), ReadTxs, [], ok),
            ReadTxs2 = finalize_reads(lists:sort(AbortedReads), ReadTxs1, [], {error, specula_abort}),
            {FinalCdf1, SpeculaCdf1, SpeculaTxs1} = commit_updates(FinalCdf, SpeculaCdf, FinalCommitUpdates, SpeculaTxs, [], Now),
                      %% Add abort of this txn to stat, if no cascading abort was found 
            basho_bench_stats:op_complete({OpTag, OpTag}, {error, immediate_abort}),
            {Sum, Count} = AbortStat,
            AbortStat1 = {timer:now_diff(Now, Seed)+Sum, Count+1},
            {next_state, execute, State#state{driver_state=DriverState, update_seq=UpdateSeq, store_cdf=StoreCdf,
                    specula_txs=SpeculaTxs1, read_txs=ReadTxs2, abort_stat=AbortStat1, specula_cdf=SpeculaCdf1, final_cdf=FinalCdf1}, 0};
        {wrong_msg, DriverState} ->
            basho_bench_stats:op_complete({OpTag, OpTag}, {error, immediate_abort}),
            {next_state, execute, State#state{driver_state=DriverState, final_cdf=FinalCdf, specula_cdf=SpeculaCdf, store_cdf=StoreCdf}, 100};
        crash -> %% Got timeout 
            basho_bench_stats:op_complete({OpTag, OpTag}, {error, immediate_abort}),
            {next_state, execute, State#state{final_cdf=FinalCdf, specula_cdf=SpeculaCdf, store_cdf=StoreCdf}, 100};
        {error, Reason, DriverState} ->
            basho_bench_stats:op_complete({OpTag, OpTag}, {error, Reason}),
            State#state.shutdown_on_error andalso
                erlang:send_after(500, basho_bench,
                                  {shutdown, "Shutdown on errors requested", 1}),
            {next_state, execute, State#state { driver_state = DriverState, todo_op=ToDo, store_cdf=StoreCdf}, 0};
        {'EXIT', Reason} ->
            %% Driver crashed, generate a crash error and terminate. This will take down
            %% the corresponding worker which will get restarted by the appropriate supervisor.
            basho_bench_stats:op_complete(ToDo, {error, crash}),

            %% Give the driver a chance to cleanup
            (catch (State#state.driver):terminate({'EXIT', Reason}, State#state.driver_state)),

            ?DEBUG("Driver ~p crashed: ~p\n", [State#state.driver, Reason]),
            case State#state.shutdown_on_error of
                true ->
                    erlang:send_after(500, basho_bench,
                                      {shutdown, "Shutdown on errors requested", 2}),
                    {next_state, execute, State#state{store_cdf=StoreCdf}, 0};
                false ->
                    %% Not implemented here
                    crash
            end;
        {stop, Reason} ->
            %% Driver (or something within it) has requested that this worker
            %% terminate cleanly.
            ?INFO("Driver ~p (~p) has requested stop: ~p\n", [State#state.driver, self(), Reason]),

            %% Give the driver a chance to cleanup
            (catch (State#state.driver):terminate(normal, State#state.driver_state)),

            %% Not implemented here
            normal
    end.

%%
%% Stop a worker process via the supervisor and terminate the app
%% if there are no workers remaining
%%
%% WARNING: Must run from a process other than the worker!
%%
%stop_worker(SupChild) ->
%    ok = basho_bench_sup:stop_child(SupChild),
%    case basho_bench_sup:workers() of
%        [] ->
%            %% No more workers -- stop the system
%	        lager:info("Worker trying to stop app"),
%            basho_bench_app:stop();
%        _ ->
%            ok
%    end.

%%
%% Expand operations list into tuple suitable for weighted, random draw
%%
ops_tuple() ->
    F =
        fun({OpTag, Count}) ->
                lists:duplicate(Count, {OpTag, OpTag});
           ({Label, OpTag, Count}) ->
                lists:duplicate(Count, {Label, OpTag})
        end,
    Ops = [F(X) || X <- basho_bench_config:get(operations, [])],
    list_to_tuple(lists:flatten(Ops)).

get_next_op([{UpdateSeq, OpName, StartTime, _}|_T], UpdateSeq, CurrentOp) ->
    {PreviousStates, _} = CurrentOp,
    {StartTime, {PreviousStates, OpName}};
get_next_op([_H|T], UpdateSeq, CurrentOp) ->
    get_next_op(T, UpdateSeq, CurrentOp).

op_think_time(CurrentOp, NextOp, ThinkTime, Transition) ->
    case Transition of
        undef ->
            {_, OpTag} = CurrentOp,
            {_, NewOpTag} = NextOp,
            case ThinkTime of tpcc -> 
                                tpcc_tool:get_think_time(OpTag) + tpcc_tool:get_key_time(NewOpTag);
                              _ -> ThinkTime
            end;
        _ ->
            {PreviousStates, CurrentState} = CurrentOp,
            NextToDo = rubis_tool:get_next_state(PreviousStates, Transition, CurrentState), 
            case ThinkTime of rubis -> rubis_tool:get_think_time(NextToDo, Transition);
                              _ -> ThinkTime
            end
    end.

%% Report the stat about the cascading abort after this txid. Then report its name and index
find_specula_tx(Seq, [{Seq, OpName, StartTime, _SpecTime}|_T]=List) ->
    report_cascade(List),
    {StartTime, {Seq, OpName}};
find_specula_tx({tx_id, _, _, _,Seq}, [{Seq, OpName, StartTime, _SpecTime}|_T]=List) ->
    report_cascade(List),
    {StartTime, {Seq, OpName}};
find_specula_tx(Seq, [{_Seq1, _OpName, _StartTime, _SpecTime}|T]) ->
    find_specula_tx(Seq, T).

report_cascade([]) ->
    ok;
report_cascade([{_Seq, OpName, _StartTime, _}|T]) ->
    %% Does elasped time matter?
    basho_bench_stats:op_complete({OpName, OpName}, {error, specula_abort}),
    report_cascade(T).


%get_next_op(undef, ThinkTime, StateOps, StateOpLen, CurrentOp, CurrentIndex, SpeculaTxs) ->
%    {_, OpTag} = CurrentOp,
%    {Info, NewOpTag} = element(random:uniform(StateOpLen), StateOps),
%    case ThinkTime of tpcc -> 
%                        {tpcc_tool:get_think_time(OpTag) + tpcc_tool:get_key_time(NewOpTag), {Info, NewOpTag}};
%                      _ -> {ThinkTime, {Info, NewOpTag}} 
%    end;
%get_next_op(Transition, ThinkTime, StateOps, StateOpLen, CurrentOp, CurrentIndex, SpeculaTxs) ->
%    {PreviousStates, CurrentState} = CurrentOp,
%    NextToDo = rubis_tool:get_next_state(PreviousStates, Transition, CurrentState), 
%    case ThinkTime of rubis -> {rubis_tool:get_think_time(NextToDo, Transition), NextToDo};
%                      _ -> {timer:sleep(ThinkTime), NextToDo}
%    end.

add_sctime_to_list([{TxnSeq, _OpName, StartTime, _}|Rest], TxnSeq, SpecCommitTime) -> 
    [{TxnSeq, _OpName, StartTime, SpecCommitTime}|Rest];
add_sctime_to_list([TxInfo|Rest], TxnSeq, SpecCommitTime) ->
    [TxInfo|add_sctime_to_list(Rest, TxnSeq, SpecCommitTime)].

commit_updates(FinalCdf, SpeculaCdf, [], SpeculaTxs, PreviousSpecula, _) ->
    {FinalCdf, SpeculaCdf, lists:reverse(PreviousSpecula)++SpeculaTxs};
commit_updates(FinalCdf, SpeculaCdf, [{{tx_id, _A, _B, _C, TxnSeq}, EndTime}|Rest], [{TxnSeq, OpName, StartTime, SpecTime}|SpeculaRest], PreviousSpecula, Now)->
    %case EndTime of ignore -> lager:warning("End Time is ~w, SpecTime is ~w, TxId is ~w", [EndTime, SpecTime, TxId]); _ -> ok end, 
    UsedTime = timer:now_diff(EndTime, StartTime),
    %case SpecTime of ignore -> lager:warning("End Time is ~w, SpecTime is ~w, TxId is ~w", [EndTime, SpecTime, TxId]); _ -> ok end, 
    PercvTime = timer:now_diff(SpecTime, StartTime),
    basho_bench_stats:op_complete({OpName, OpName}, ok),
    commit_updates([{Now, UsedTime}|FinalCdf], [{Now, PercvTime}|SpeculaCdf], Rest, SpeculaRest, PreviousSpecula, Now);
commit_updates(FinalCdf, SpeculaCdf, [{tx_id, _A, _B, _C, TxnSeq}|Rest], [{TxnSeq, OpName, _StartTime, _SpecTime}|SpeculaRest], PreviousSpecula, Now)->
    basho_bench_stats:op_complete({OpName, OpName}, ok),
    commit_updates(FinalCdf, SpeculaCdf, Rest, SpeculaRest, PreviousSpecula, Now);
%% In case of non-specula
commit_updates(FinalCdf, SpeculaCdf, [{TxnSeq, EndTime}|Rest], [{TxnSeq, OpName, StartTime, ignore}|SpeculaRest], PreviousSpecula, Now)->
    %case EndTime of ignore -> lager:warning("End Time is ~w, TxId is ~w", [EndTime, TxnSeq]); _ -> ok end, 
    UsedTime = timer:now_diff(EndTime, StartTime),
    basho_bench_stats:op_complete({OpName, OpName}, ok),
    commit_updates([{Now, UsedTime}|FinalCdf], SpeculaCdf, Rest, SpeculaRest, PreviousSpecula, Now); 
commit_updates(FinalCdf, SpeculaCdf, [{TxnSeq, EndTime}|Rest], [{TxnSeq, OpName, StartTime, SpecTime}|SpeculaRest], PreviousSpecula, Now)->
    %case EndTime of ignore -> lager:warning("End Time is ~w, SpecTime is ~w, TxSeq is ~w", [EndTime, SpecTime, TxnSeq]); _ -> ok end, 
    UsedTime = timer:now_diff(EndTime, StartTime),
    %case SpecTime of ignore -> lager:warning("End Time is ~w, SpecTime is ~w, TxId is ~w", [EndTime, SpecTime, TxnSeq]); _ -> ok end, 
    PercvTime = timer:now_diff(SpecTime, StartTime),
    basho_bench_stats:op_complete({OpName, OpName}, ok),
    commit_updates([{Now, UsedTime}|FinalCdf], [{Now, PercvTime}|SpeculaCdf], Rest, SpeculaRest, PreviousSpecula, Now); 
commit_updates(FinalCdf, SpeculaCdf, List, [Entry|SpeculaRest]=SpeculaList, PreviousSpecula, Now) ->
    lager:error("List is ~w, Specula list is ~w", [List, SpeculaList]),
    Now = error,
    commit_updates(FinalCdf, SpeculaCdf, List, SpeculaRest, [Entry|PreviousSpecula], Now).

finalize_reads([], ReadTxs, Previous, _Result) ->
    lists:reverse(Previous)++ReadTxs;
finalize_reads([{tx_id, _,_,_,TxnSeq}|T], [{TxnSeq, _, OpName}|Rest],Previous, Result) ->
    basho_bench_stats:op_complete({OpName, OpName}, Result),
    finalize_reads(T, Rest, Previous, Result);
finalize_reads([TxnSeq|T], [{TxnSeq, _, OpName}|Rest], Previous, Result) ->
    basho_bench_stats:op_complete({OpName, OpName}, Result),
    finalize_reads(T, Rest, Previous, Result);
finalize_reads(List, [Entry|SpeculaRest], PreviousSpecula, Result) ->
    finalize_reads(List, SpeculaRest, [Entry|PreviousSpecula], Result);
finalize_reads(List, [], Previous, Result) ->
    lager:error("List is ~p, Previous is ~p, result is ~p", [List, Previous, Result]),
    List = 1.

get_op_type(_, true) ->
    update;
get_op_type(OpName, false) ->
    get_op_type(OpName).

get_op_type(register_user) ->
    update;
get_op_type(register_item) ->
    update;
get_op_type(store_bid) ->
    update;
get_op_type(store_comment) ->
    update;
get_op_type(store_buy_now) ->
    update;
get_op_type(txn) ->
    update;
get_op_type(new_order) ->
    update;
get_op_type(payment) ->
    update;
get_op_type(order_status) ->
    read;
get_op_type({_, register_user}) ->
    update;
get_op_type({_, register_item}) ->
    update;
get_op_type({_, store_bid}) ->
    update;
get_op_type({_, store_comment}) ->
    update;
get_op_type({_, store_buy_now}) ->
    update;
get_op_type({_, txn}) ->
    update;
get_op_type({_, new_order}) ->
    update;
get_op_type({_, payment}) ->
    update;
get_op_type({_, order_status}) ->
    read;
get_op_type(_Name) ->
    read.
   

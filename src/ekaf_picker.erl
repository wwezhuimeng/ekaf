-module(ekaf_picker).
-export([pick/1, pick/2, pick/3, pick/4]).
-export([pick_sync/3, pick_sync/4,
        pick_async/2, join_group_if_not_present/2]).

-include("ekaf_definitions.hrl").

%% Each topic gets its own gen_server to
%%  pick a partition worker
%% This step is blocking so that it can optimize
%%  picking the same worker until it crosses batch_size, etc

%% pick_async is what is directly called for sending events
%% pick_sync is what is called when the topics ekaf_server
%%  needs to pick the next worker ( usually checked once a second )

pick(Topic)->
    Callback = undefined,
    pick(Topic,Callback).
% occurance of a null callback, indicates sync when Mode is not specified
pick(Topic, undefined) ->
    pick(Topic, undefined, sync);
% occurance of a callback that is not null, indicates async when Mode is not specified
pick(Topic, Callback) ->
    pick(Topic, Callback, async).
pick(Topic, Callback, Mode) ->
    pick(Topic, Callback, Mode, ?EKAF_DEFAULT_PARTITION_STRATEGY).
pick(Topic, Callback, Mode, Strategy) ->
    case Mode of
        %_ when Strategy =:= sticky_round_robin ->
        %    pick_sync(Topic, Callback, Strategy);
        sync ->
            pick_sync(Topic,Callback, Strategy);
        _ when Callback =:= undefined->
            pick_sync(Topic,Callback, Strategy);
        _ ->
            %% non-blocking
            %% and the picked worker is sent to the Callback
            pick_async(Topic, Callback)
    end.

pick_async(Topic,Callback)->
    RegName = (catch gproc:where({n,l,Topic})),
    TempCallback = fun(_With)->
                           Pid = spawn(fun()->
                                               receive
                                                   {ok, Worker}->
                                                       Callback(Worker);
                                                   _UE ->
                                                       {error, _UE}
                                               end
                                       end),
                           gproc:send({n,l,Topic}, {pick, Topic, Pid})
                   end,
    case RegName of
        {'EXIT',Reason} ->
            Callback({error,Reason});
        undefined ->
            ekaf:prepare(Topic, TempCallback);
        _ ->
            TempCallback(undefined)
    end.

pick_sync(Topic, Callback, Strategy)->
    pick_sync(Topic, Callback, Strategy, 0).
%% if strategy is ketama
pick_sync(_Topic, _Callback, ketama, _Attempt)->
    %TODO
    error;
%% if strategy is sticky_round_robin or strict_round_robin or random
pick_sync(Topic, Callback, _Strategy, _Attempt)->
    case pg2l:get_closest_pid(Topic) of
        PoolPid when is_pid(PoolPid) ->
            handle_callback(Callback,PoolPid);
        {error, {no_process,_}}->
            handle_callback(Callback,{error,bootstrapping});
        {error,{no_such_group,_}}->
            ekaf:prepare(Topic, Callback);
        _E ->
            error_logger:info_msg("~p pick_sync ERROR: ~p",[?MODULE,_E]),
            handle_callback(Callback,_E)
    end.

handle_callback(Callback, Pid)->
    case Callback of
        undefined -> Pid;
        _ -> Callback(Pid)
    end.

join_group_if_not_present(PG, Pid)->
    Pids = pg2l:get_members(PG),
    case lists:member(Pid, Pids) of
        true ->
            ok;
        _ ->
            pg2l:join(PG, Pid)
    end.

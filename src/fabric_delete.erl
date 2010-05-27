-module(fabric_delete).
-author('Brad Anderson <brad@cloudant.com>').

-include("../../couch/src/couch_db.hrl").
-include("../../dynomite/include/membership.hrl").

%% api
-export([delete_db/2]).


%% =====================
%%   api
%% =====================

%% @doc Delete a database, and all its partition files across the cluster
%%      Options is proplist with user_ctx, n, q
-spec delete_db(binary(), list()) -> {ok, #db{}} | {error, any()}.
delete_db(DbName, Options) ->
    Parts = partitions:all_parts(DbName),
    RefPartMap = send_calls(DbName, Options, Parts),
    Acc0 = {true, length(RefPartMap)},
    case fabric_util:receive_loop(
        RefPartMap, 1, fun handle_delete_msg/3, Acc0, 5000, infinity) of
    {ok, _Results} ->
        delete_fullmap(DbName),
        ok;
    Error -> Error
    end.


%% =====================
%%   internal
%% =====================

%% @doc delete the partitions on all appropriate nodes (rexi calls)
-spec send_calls(binary(), list(), fullmap()) -> [{reference(), part()}].
send_calls(DbName, Options, Parts) ->
    lists:map(fun(#shard{node=Node, range=[Beg,_]} = Part) ->
        ShardName = showroom_utils:shard_name(Beg, DbName),
        Ref = rexi:async_server_call({couch_server, Node},
                                     {delete, ShardName, Options}),
        {Ref, Part}
    end, Parts).

handle_delete_msg(_, not_found, {NotFound, N}) ->
    {ok, {NotFound, N-1}};
handle_delete_msg(_, {rexi_EXIT, _Reason}, {NotFound, N}) ->
    {ok, {NotFound, N-1}};
handle_delete_msg(_, {rexi_DOWN, _, _, _}, _Acc) ->
    {error, delete_db_fubar};
handle_delete_msg(_, _, {NotFound, 1}) ->
    if
    NotFound -> {stop, not_found};
    true -> {stop, ok}
    end;
handle_delete_msg(_, ok, {_NotFound, N}) ->
    {ok, {false, N-1}}.

delete_fullmap(DbName) ->
    case couch_db:open(<<"dbs">>, []) of
    {ok, Db} ->
        {ok, Doc} = couch_api:open_doc(Db, DbName, nil, []),
        couch_api:update_doc(Db, Doc#doc{deleted=true});
    Error -> Error
    end.
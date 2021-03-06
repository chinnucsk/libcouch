% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(libcouch_db_updater).
-behaviour(gen_server).

-export([btree_by_id_reduce/2,btree_by_seq_reduce/2]).
-export([make_doc_summary/2]).
-export([init/1,terminate/2,handle_call/3,handle_cast/2,code_change/3,handle_info/2]).

-include("libcouch.hrl")


init({DbName, Filepath, Fd, Options}) ->
    case lists:member(create, Options) of
    true ->
        % create a new header and writes it to the file
        Header =  #db_header{},
        ok = libcouch_file:write_header(Fd, Header),
        % delete any old compaction files that might be hanging around
        RootDir = libcouch_server:database_dir(),
        libcouch_file:delete(RootDir, Filepath ++ ".compact");
    false ->
        case libcouch_file:read_header(Fd) of
        {ok, Header} ->
            ok;
        no_valid_header ->
            % create a new header and writes it to the file
            Header =  #db_header{},
            ok = libcouch_file:write_header(Fd, Header),
            % delete any old compaction files that might be hanging around
            file:delete(Filepath ++ ".compact")
        end
    end,
    Db = init_db(DbName, Filepath, Fd, Header, Options),
    {ok, Db#db{main_pid = self()}}.


terminate(_Reason, Db) ->
    ok = libcouch_file:close(Db#db.fd),
    libcouch_util:shutdown_sync(Db#db.compactor_pid),
    libcouch_util:shutdown_sync(Db#db.fd),
    ok.

handle_call(get_db, _From, Db) ->
    {reply, {ok, Db}, Db};
handle_call(full_commit, _From, #db{waiting_delayed_commit=nil}=Db) ->
    {reply, ok, Db}; % no data waiting, return ok immediately
handle_call(full_commit, _From,  Db) ->
    {reply, ok, commit_data(Db)}; % commit the data and return ok
handle_call(start_compact, _From, Db) ->
    {noreply, NewDb} = handle_cast(start_compact, Db),
    {reply, {ok, NewDb#db.compactor_pid}, NewDb};
handle_call(compactor_pid, _From, #db{compactor_pid = Pid} = Db) ->
    {reply, Pid, Db};
handle_call(cancel_compact, _From, #db{compactor_pid = nil} = Db) ->
    {reply, ok, Db};
handle_call(cancel_compact, _From, #db{compactor_pid = Pid} = Db) ->
    unlink(Pid),
    exit(Pid, kill),
    RootDir = libcouch_server:database_dir(),
    ok = libcouch_file:delete(RootDir, Db#db.filepath ++ ".compact"),
    Db2 = Db#db{compactor_pid = nil},
    ok = gen_server:call(libcouch_server, {db_updated, Db2}, infinity),
    {reply, ok, Db2};
handle_call(increment_update_seq, _From, Db) ->
    Db2 = commit_data(Db#db{update_seq=Db#db.update_seq+1}),
    ok = gen_server:call(libcouch_server, {db_updated, Db2}, infinity),
    libcouch_db_update_notifier:notify({updated, Db#db.name}),
    {reply, {ok, Db2#db.update_seq}, Db2};

handle_call({set_revs_limit, Limit}, _From, Db) ->
    Db2 = commit_data(Db#db{revs_limit=Limit,
            update_seq=Db#db.update_seq+1}),
    ok = gen_server:call(libcouch_server, {db_updated, Db2}, infinity),
    {reply, ok, Db2};

handle_call({purge_docs, _IdRevs}, _From,
        #db{compactor_pid=Pid}=Db) when Pid /= nil ->
    {reply, {error, purge_during_compaction}, Db};
handle_call({purge_docs, IdRevs}, _From, Db) ->
    #db{
        fd = Fd,
        fulldocinfo_by_id_btree = DocInfoByIdBTree,
        docinfo_by_seq_btree = DocInfoBySeqBTree,
        update_seq = LastSeq,
        header = Header = #db_header{purge_seq=PurgeSeq},
        compression = Comp
        } = Db,
    DocLookups = libcouch_btree:lookup(DocInfoByIdBTree,
            [Id || {Id, _Revs} <- IdRevs]),

    NewDocInfos = lists:zipwith(
        fun({_Id, Revs}, {ok, #full_doc_info{rev_tree=Tree}=FullDocInfo}) ->
            case libcouch_key_tree:remove_leafs(Tree, Revs) of
            {_, []=_RemovedRevs} -> % no change
                nil;
            {NewTree, RemovedRevs} ->
                {FullDocInfo#full_doc_info{rev_tree=NewTree},RemovedRevs}
            end;
        (_, not_found) ->
            nil
        end,
        IdRevs, DocLookups),

    SeqsToRemove = [Seq
            || {#full_doc_info{update_seq=Seq},_} <- NewDocInfos],

    FullDocInfoToUpdate = [FullInfo
            || {#full_doc_info{rev_tree=Tree}=FullInfo,_}
            <- NewDocInfos, Tree /= []],

    IdRevsPurged = [{Id, Revs}
            || {#full_doc_info{id=Id}, Revs} <- NewDocInfos],

    {DocInfoToUpdate, NewSeq} = lists:mapfoldl(
        fun(#full_doc_info{rev_tree=Tree}=FullInfo, SeqAcc) ->
            Tree2 = libcouch_key_tree:map_leafs(
                fun(_RevId, LeafVal) ->
                    IsDeleted = element(1, LeafVal),
                    BodyPointer = element(2, LeafVal),
                    {IsDeleted, BodyPointer, SeqAcc + 1}
                end, Tree),
            {libcouch_doc:to_doc_info(FullInfo#full_doc_info{rev_tree=Tree2}),
                SeqAcc + 1}
        end, LastSeq, FullDocInfoToUpdate),

    IdsToRemove = [Id || {#full_doc_info{id=Id,rev_tree=[]},_}
            <- NewDocInfos],

    {ok, DocInfoBySeqBTree2} = libcouch_btree:add_remove(DocInfoBySeqBTree,
            DocInfoToUpdate, SeqsToRemove),
    {ok, DocInfoByIdBTree2} = libcouch_btree:add_remove(DocInfoByIdBTree,
            FullDocInfoToUpdate, IdsToRemove),
    {ok, Pointer, _} = libcouch_file:append_term(
            Fd, IdRevsPurged, [{compression, Comp}]),

    Db2 = commit_data(
        Db#db{
            fulldocinfo_by_id_btree = DocInfoByIdBTree2,
            docinfo_by_seq_btree = DocInfoBySeqBTree2,
            update_seq = NewSeq + 1,
            header=Header#db_header{purge_seq=PurgeSeq+1, purged_docs=Pointer}}),

    ok = gen_server:call(libcouch_server, {db_updated, Db2}, infinity),
    libcouch_db_update_notifier:notify({updated, Db#db.name}),
    {reply, {ok, (Db2#db.header)#db_header.purge_seq, IdRevsPurged}, Db2}.


handle_cast(start_compact, Db) ->
    case Db#db.compactor_pid of
    nil ->
        ?LOG_INFO("Starting compaction for db \"~s\"", [Db#db.name]),
        Pid = spawn_link(fun() -> start_copy_compact(Db) end),
        Db2 = Db#db{compactor_pid=Pid},
        ok = gen_server:call(libcouch_server, {db_updated, Db2}, infinity),
        {noreply, Db2};
    _ ->
        % compact currently running, this is a no-op
        {noreply, Db}
    end;
handle_cast({compact_done, CompactFilepath}, #db{filepath=Filepath}=Db) ->
    {ok, NewFd} = libcouch_file:open(CompactFilepath),
    {ok, NewHeader} = libcouch_file:read_header(NewFd),
    #db{update_seq=NewSeq} = NewDb =
        init_db(Db#db.name, Filepath, NewFd, NewHeader, Db#db.options),
    unlink(NewFd),
    case Db#db.update_seq == NewSeq of
    true ->
        % suck up all the local docs into memory and write them to the new db
        {ok, _, LocalDocs} = libcouch_btree:foldl(Db#db.local_docs_btree,
                fun(Value, _Offset, Acc) -> {ok, [Value | Acc]} end, []),
        {ok, NewLocalBtree} = libcouch_btree:add(NewDb#db.local_docs_btree, LocalDocs),

        NewDb2 = commit_data(NewDb#db{
            local_docs_btree = NewLocalBtree,
            main_pid = self(),
            filepath = Filepath,
            instance_start_time = Db#db.instance_start_time,
            revs_limit = Db#db.revs_limit
        }),

        ?LOG_DEBUG("CouchDB swapping files ~s and ~s.",
                [Filepath, CompactFilepath]),
        RootDir = libcouch_server:database_dir(),
        libcouch_file:delete(RootDir, Filepath),
        ok = file:rename(CompactFilepath, Filepath),
        close_db(Db),
        ok = gen_server:call(libcouch_server, {db_updated, NewDb2}, infinity),
        libcouch_db_update_notifier:notify({compacted, NewDb2#db.name}),
        ?LOG_INFO("Compaction for db \"~s\" completed.", [Db#db.name]),
        {noreply, NewDb3#db{compactor_pid=nil}};
    false ->
        ?LOG_INFO("Compaction file still behind main file "
            "(update seq=~p. compact update seq=~p). Retrying.",
            [Db#db.update_seq, NewSeq]),
        close_db(NewDb),
        Pid = spawn_link(fun() -> start_copy_compact(Db) end),
        Db2 = Db#db{compactor_pid=Pid},
        ok = gen_server:call(libcouch_server, {db_updated, Db2}, infinity),
        {noreply, Db2}
    end;

handle_cast(Msg, #db{name = Name} = Db) ->
    ?LOG_ERROR("Database `~s` updater received unexpected cast: ~p", [Name, Msg]),
    {stop, Msg, Db}.


handle_info({update_docs, Client, GroupedDocs, NonRepDocs, MergeConflicts,
        FullCommit}, Db) ->
    GroupedDocs2 = [[{Client, D} || D <- DocGroup] || DocGroup <- GroupedDocs],
    if NonRepDocs == [] ->
        {GroupedDocs3, Clients, FullCommit2} = collect_updates(GroupedDocs2,
                [Client], MergeConflicts, FullCommit);
    true ->
        GroupedDocs3 = GroupedDocs2,
        FullCommit2 = FullCommit,
        Clients = [Client]
    end,
    NonRepDocs2 = [{Client, NRDoc} || NRDoc <- NonRepDocs],
    try update_docs_int(Db, GroupedDocs3, NonRepDocs2, MergeConflicts,
                FullCommit2) of
    {ok, Db2, UpdatedDDocIds} ->
        ok = gen_server:call(libcouch_server, {db_updated, Db2}, infinity),
        if Db2#db.update_seq /= Db#db.update_seq ->
            libcouch_db_update_notifier:notify({updated, Db2#db.name});
        true -> ok
        end,
        [catch(ClientPid ! {done, self()}) || ClientPid <- Clients],
        lists:foreach(fun(DDocId) ->
            libcouch_db_update_notifier:notify({ddoc_updated, {Db#db.name, DDocId}})
        end, UpdatedDDocIds),
        {noreply, Db2}
    catch
        throw: retry ->
            [catch(ClientPid ! {retry, self()}) || ClientPid <- Clients],
            {noreply, Db}
    end;
handle_info(delayed_commit, #db{waiting_delayed_commit=nil}=Db) ->
    %no outstanding delayed commits, ignore
    {noreply, Db};
handle_info(delayed_commit, Db) ->
    case commit_data(Db) of
        Db ->
            {noreply, Db};
        Db2 ->
            ok = gen_server:call(libcouch_server, {db_updated, Db2}, infinity),
            {noreply, Db2}
    end;
handle_info({'EXIT', _Pid, normal}, Db) ->
    {noreply, Db};
handle_info({'EXIT', _Pid, Reason}, Db) ->
    {stop, Reason, Db};
handle_info({'DOWN', Ref, _, _, Reason}, #db{fd_monitor=Ref, name=Name} = Db) ->
    ?LOG_ERROR("DB ~s shutting down - Fd ~p", [Name, Reason]),
    {stop, normal, Db}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


merge_updates([], RestB, AccOutGroups) ->
    lists:reverse(AccOutGroups, RestB);
merge_updates(RestA, [], AccOutGroups) ->
    lists:reverse(AccOutGroups, RestA);
merge_updates([[{_, {#doc{id=IdA}, _}}|_]=GroupA | RestA],
        [[{_, {#doc{id=IdB}, _}}|_]=GroupB | RestB], AccOutGroups) ->
    if IdA == IdB ->
        merge_updates(RestA, RestB, [GroupA ++ GroupB | AccOutGroups]);
    IdA < IdB ->
        merge_updates(RestA, [GroupB | RestB], [GroupA | AccOutGroups]);
    true ->
        merge_updates([GroupA | RestA], RestB, [GroupB | AccOutGroups])
    end.

collect_updates(GroupedDocsAcc, ClientsAcc, MergeConflicts, FullCommit) ->
    receive
        % Only collect updates with the same MergeConflicts flag and without
        % local docs. It's easier to just avoid multiple _local doc
        % updaters than deal with their possible conflicts, and local docs
        % writes are relatively rare. Can be optmized later if really needed.
        {update_docs, Client, GroupedDocs, [], MergeConflicts, FullCommit2} ->
            GroupedDocs2 = [[{Client, Doc} || Doc <- DocGroup]
                    || DocGroup <- GroupedDocs],
            GroupedDocsAcc2 =
                merge_updates(GroupedDocsAcc, GroupedDocs2, []),
            collect_updates(GroupedDocsAcc2, [Client | ClientsAcc],
                    MergeConflicts, (FullCommit or FullCommit2))
    after 0 ->
        {GroupedDocsAcc, ClientsAcc, FullCommit}
    end.


btree_by_seq_split(#doc_info{id=Id, high_seq=KeySeq, revs=Revs}) ->
    {RevInfos, DeletedRevInfos} = lists:foldl(
        fun(#rev_info{deleted = false, seq = Seq} = Ri, {Acc, AccDel}) ->
                {[{Ri#rev_info.rev, Seq, Ri#rev_info.body_sp} | Acc], AccDel};
            (#rev_info{deleted = true, seq = Seq} = Ri, {Acc, AccDel}) ->
                {Acc, [{Ri#rev_info.rev, Seq, Ri#rev_info.body_sp} | AccDel]}
        end,
        {[], []}, Revs),
    {KeySeq, {Id, lists:reverse(RevInfos), lists:reverse(DeletedRevInfos)}}.

btree_by_seq_join(KeySeq, {Id, RevInfos, DeletedRevInfos}) ->
    #doc_info{
        id = Id,
        high_seq=KeySeq,
        revs =
            [#rev_info{rev=Rev,seq=Seq,deleted=false,body_sp = Bp} ||
                {Rev, Seq, Bp} <- RevInfos] ++
            [#rev_info{rev=Rev,seq=Seq,deleted=true,body_sp = Bp} ||
                {Rev, Seq, Bp} <- DeletedRevInfos]}.

btree_by_id_split(#full_doc_info{id=Id, update_seq=Seq,
        deleted=Deleted, rev_tree=Tree}) ->
    DiskTree =
    libcouch_key_tree:map(
        fun(_RevId, ?REV_MISSING) ->
            ?REV_MISSING;
        (_RevId, RevValue) ->
            IsDeleted = element(1, RevValue),
            BodyPointer = element(2, RevValue),
            UpdateSeq = element(3, RevValue),
            Size = case tuple_size(RevValue) of
            4 ->
                element(4, RevValue);
            3 ->
                % pre 1.2 format, will be upgraded on compaction
                nil
            end,
            {if IsDeleted -> 1; true -> 0 end, BodyPointer, UpdateSeq, Size}
        end, Tree),
    {Id, {Seq, if Deleted -> 1; true -> 0 end, DiskTree}}.

btree_by_id_join(Id, {HighSeq, Deleted, DiskTree}) ->
    {Tree, LeafsSize} =
    libcouch_key_tree:mapfold(
        fun(_RevId, {IsDeleted, BodyPointer, UpdateSeq}, leaf, _Acc) ->
            % pre 1.2 format, will be upgraded on compaction
            {{IsDeleted == 1, BodyPointer, UpdateSeq, nil}, nil};
        (_RevId, {IsDeleted, BodyPointer, UpdateSeq}, branch, Acc) ->
            {{IsDeleted == 1, BodyPointer, UpdateSeq, nil}, Acc};
        (_RevId, {IsDeleted, BodyPointer, UpdateSeq, Size}, leaf, Acc) ->
            Acc2 = sum_leaf_sizes(Acc, Size),
            {{IsDeleted == 1, BodyPointer, UpdateSeq, Size}, Acc2};
        (_RevId, {IsDeleted, BodyPointer, UpdateSeq, Size}, branch, Acc) ->
            {{IsDeleted == 1, BodyPointer, UpdateSeq, Size}, Acc};
        (_RevId, ?REV_MISSING, _Type, Acc) ->
            {?REV_MISSING, Acc}
        end, 0, DiskTree),
    #full_doc_info{
        id = Id,
        update_seq = HighSeq,
        deleted = (Deleted == 1),
        rev_tree = Tree,
        leafs_size = LeafsSize
    }.

btree_by_id_reduce(reduce, FullDocInfos) ->
    lists:foldl(
        fun(Info, {NotDeleted, Deleted, Size}) ->
            Size2 = sum_leaf_sizes(Size, Info#full_doc_info.leafs_size),
            case Info#full_doc_info.deleted of
            true ->
                {NotDeleted, Deleted + 1, Size2};
            false ->
                {NotDeleted + 1, Deleted, Size2}
            end
        end,
        {0, 0, 0}, FullDocInfos);
btree_by_id_reduce(rereduce, Reds) ->
    lists:foldl(
        fun({NotDeleted, Deleted}, {AccNotDeleted, AccDeleted, _AccSize}) ->
            % pre 1.2 format, will be upgraded on compaction
            {AccNotDeleted + NotDeleted, AccDeleted + Deleted, nil};
        ({NotDeleted, Deleted, Size}, {AccNotDeleted, AccDeleted, AccSize}) ->
            AccSize2 = sum_leaf_sizes(AccSize, Size),
            {AccNotDeleted + NotDeleted, AccDeleted + Deleted, AccSize2}
        end,
        {0, 0, 0}, Reds).

sum_leaf_sizes(nil, _) ->
    nil;
sum_leaf_sizes(_, nil) ->
    nil;
sum_leaf_sizes(Size1, Size2) ->
    Size1 + Size2.

btree_by_seq_reduce(reduce, DocInfos) ->
    % count the number of documents
    length(DocInfos);
btree_by_seq_reduce(rereduce, Reds) ->
    lists:sum(Reds).

simple_upgrade_record(Old, New) when tuple_size(Old) < tuple_size(New) ->
    OldSz = tuple_size(Old),
    NewValuesTail =
        lists:sublist(tuple_to_list(New), OldSz + 1, tuple_size(New) - OldSz),
    list_to_tuple(tuple_to_list(Old) ++ NewValuesTail);
simple_upgrade_record(Old, _New) ->
    Old.

-define(OLD_DISK_VERSION_ERROR,
    "Database files from versions smaller than 0.10.0 are no longer supported").

init_db(DbName, Filepath, Fd, Header0, Options) ->
    Header1 = simple_upgrade_record(Header0, #db_header{}),
    Header =
    case element(2, Header1) of
    1 -> throw({database_disk_version_error, ?OLD_DISK_VERSION_ERROR});
    2 -> throw({database_disk_version_error, ?OLD_DISK_VERSION_ERROR});
    3 -> throw({database_disk_version_error, ?OLD_DISK_VERSION_ERROR});
    4 -> Header1#db_header{security_ptr = nil}; % 0.10 and pre 0.11
    5 -> Header1; % pre 1.2
    ?LATEST_DISK_VERSION -> Header1;
    _ -> throw({database_disk_version_error, "Incorrect disk header version"})
    end,

    {ok, FsyncOptions} = libcouch_util:parse_term(
            libcouch_config:get("couchdb", "fsync_options",
                    "[before_header, after_header, on_file_open]")),

    case lists:member(on_file_open, FsyncOptions) of
    true -> ok = libcouch_file:sync(Fd);
    _ -> ok
    end,

    Compression = libcouch_compress:get_compression_method(),

    {ok, IdBtree} = libcouch_btree:open(Header#db_header.fulldocinfo_by_id_btree_state, Fd,
        [{split, fun(X) -> btree_by_id_split(X) end},
        {join, fun(X,Y) -> btree_by_id_join(X,Y) end},
        {reduce, fun(X,Y) -> btree_by_id_reduce(X,Y) end},
        {compression, Compression}]),
    {ok, SeqBtree} = libcouch_btree:open(Header#db_header.docinfo_by_seq_btree_state, Fd,
            [{split, fun(X) -> btree_by_seq_split(X) end},
            {join, fun(X,Y) -> btree_by_seq_join(X,Y) end},
            {reduce, fun(X,Y) -> btree_by_seq_reduce(X,Y) end},
            {compression, Compression}]),
    {ok, LocalDocsBtree} = libcouch_btree:open(Header#db_header.local_docs_btree_state, Fd,
        [{compression, Compression}]),
    case Header#db_header.security_ptr of
    nil ->
        Security = [],
        SecurityPtr = nil;
    SecurityPtr ->
            {ok, _} = libcouch_file:pread_term(Fd, SecurityPtr)
    end,
    % convert start time tuple to microsecs and store as a binary string
    {MegaSecs, Secs, MicroSecs} = now(),
    StartTime = ?l2b(io_lib:format("~p",
            [(MegaSecs*1000000*1000000) + (Secs*1000000) + MicroSecs])),
    ok = libcouch_file:set_db_pid(Fd, self()),
    #db{
        fd=Fd,
        fd_monitor = erlang:monitor(process, Fd),
        header=Header,
        fulldocinfo_by_id_btree = IdBtree,
        docinfo_by_seq_btree = SeqBtree,
        local_docs_btree = LocalDocsBtree,
        committed_update_seq = Header#db_header.update_seq,
        update_seq = Header#db_header.update_seq,
        name = DbName,
        filepath = Filepath,
        security = Security,
        security_ptr = SecurityPtr,
        instance_start_time = StartTime,
        revs_limit = Header#db_header.revs_limit,
        fsync_options = FsyncOptions,
        options = Options,
        compression = Compression,
        before_doc_update = libcouch_util:get_value(before_doc_update, Options, nil),
        after_doc_read = libcouch_util:get_value(after_doc_read, Options, nil)
        }.


close_db(#db{fd_monitor = Ref}) ->
    erlang:demonitor(Ref).

% rev tree functions

flush_trees(_Db, [], AccFlushedTrees) ->
    {ok, lists:reverse(AccFlushedTrees)};
flush_trees(#db{fd = Fd} = Db,
        [InfoUnflushed | RestUnflushed], AccFlushed) ->
    #full_doc_info{update_seq=UpdateSeq, rev_tree=Unflushed} = InfoUnflushed,
    {Flushed, LeafsSize} = libcouch_key_tree:mapfold(
        fun(_Rev, Value, Type, Acc) ->
            case Value of
            #doc{deleted = IsDeleted, body = {summary, Summary, AttsFd}} ->
                % this node value is actually an unwritten document summary,
                % write to disk.
                % make sure the Fd in the written bins is the same Fd we are
                % and convert bins, removing the FD.
                % All bins should have been written to disk already.
                case {AttsFd, Fd} of
                {nil, _} ->
                    ok;
                {SameFd, SameFd} ->
                    ok;
                _ ->
                    % Fd where the attachments were written to is not the same
                    % as our Fd. This can happen when a database is being
                    % switched out during a compaction.
                    ?LOG_DEBUG("File where the attachments are written has"
                            " changed. Possibly retrying.", []),
                    throw(retry)
                end,
                {ok, NewSummaryPointer, SummarySize} =
                    libcouch_file:append_raw_chunk(Fd, Summary),
                TotalSize = lists:foldl(
                    fun(#att{att_len = L}, A) -> A + L end,
                    SummarySize, Value#doc.atts),
                NewValue = {IsDeleted, NewSummaryPointer, UpdateSeq, TotalSize},
                case Type of
                leaf ->
                    {NewValue, Acc + TotalSize};
                branch ->
                    {NewValue, Acc}
                end;
             {_, _, _, LeafSize} when Type =:= leaf, LeafSize =/= nil ->
                {Value, Acc + LeafSize};
             _ ->
                {Value, Acc}
            end
        end, 0, Unflushed),
    InfoFlushed = InfoUnflushed#full_doc_info{
        rev_tree = Flushed,
        leafs_size = LeafsSize
    },
    flush_trees(Db, RestUnflushed, [InfoFlushed | AccFlushed]).


send_result(Client, Ref, NewResult) ->
    % used to send a result to the client
    catch(Client ! {result, self(), {Ref, NewResult}}).

merge_rev_trees(_Limit, _Merge, [], [], AccNewInfos, AccRemoveSeqs, AccSeq) ->
    {ok, lists:reverse(AccNewInfos), AccRemoveSeqs, AccSeq};
merge_rev_trees(Limit, MergeConflicts, [NewDocs|RestDocsList],
        [OldDocInfo|RestOldInfo], AccNewInfos, AccRemoveSeqs, AccSeq) ->
    #full_doc_info{id=Id,rev_tree=OldTree,deleted=OldDeleted0,update_seq=OldSeq}
            = OldDocInfo,
    {NewRevTree, _} = lists:foldl(
        fun({Client, {#doc{revs={Pos,[_Rev|PrevRevs]}}=NewDoc, Ref}}, {AccTree, OldDeleted}) ->
            if not MergeConflicts ->
                case libcouch_key_tree:merge(AccTree, libcouch_doc:to_path(NewDoc),
                    Limit) of
                {_NewTree, conflicts} when (not OldDeleted) ->
                    send_result(Client, Ref, conflict),
                    {AccTree, OldDeleted};
                {NewTree, conflicts} when PrevRevs /= [] ->
                    % Check to be sure if prev revision was specified, it's
                    % a leaf node in the tree
                    Leafs = libcouch_key_tree:get_all_leafs(AccTree),
                    IsPrevLeaf = lists:any(fun({_, {LeafPos, [LeafRevId|_]}}) ->
                            {LeafPos, LeafRevId} == {Pos-1, hd(PrevRevs)}
                        end, Leafs),
                    if IsPrevLeaf ->
                        {NewTree, OldDeleted};
                    true ->
                        send_result(Client, Ref, conflict),
                        {AccTree, OldDeleted}
                    end;
                {NewTree, no_conflicts} when  AccTree == NewTree ->
                    % the tree didn't change at all
                    % meaning we are saving a rev that's already
                    % been editted again.
                    if (Pos == 1) and OldDeleted ->
                        % this means we are recreating a brand new document
                        % into a state that already existed before.
                        % put the rev into a subsequent edit of the deletion
                        #doc_info{revs=[#rev_info{rev={OldPos,OldRev}}|_]} =
                                libcouch_doc:to_doc_info(OldDocInfo),
                        NewRevId = libcouch_db:new_revid(
                                NewDoc#doc{revs={OldPos, [OldRev]}}),
                        NewDoc2 = NewDoc#doc{revs={OldPos + 1, [NewRevId, OldRev]}},
                        {NewTree2, _} = libcouch_key_tree:merge(AccTree,
                                libcouch_doc:to_path(NewDoc2), Limit),
                        % we changed the rev id, this tells the caller we did
                        send_result(Client, Ref, {ok, {OldPos + 1, NewRevId}}),
                        {NewTree2, OldDeleted};
                    true ->
                        send_result(Client, Ref, conflict),
                        {AccTree, OldDeleted}
                    end;
                {NewTree, _} ->
                    {NewTree, NewDoc#doc.deleted}
                end;
            true ->
                {NewTree, _} = libcouch_key_tree:merge(AccTree,
                            libcouch_doc:to_path(NewDoc), Limit),
                {NewTree, OldDeleted}
            end
        end,
        {OldTree, OldDeleted0}, NewDocs),
    if NewRevTree == OldTree ->
        % nothing changed
        merge_rev_trees(Limit, MergeConflicts, RestDocsList, RestOldInfo,
            AccNewInfos, AccRemoveSeqs, AccSeq);
    true ->
        % we have updated the document, give it a new seq #
        NewInfo = #full_doc_info{id=Id,update_seq=AccSeq+1,rev_tree=NewRevTree},
        RemoveSeqs = case OldSeq of
            0 -> AccRemoveSeqs;
            _ -> [OldSeq | AccRemoveSeqs]
        end,
        merge_rev_trees(Limit, MergeConflicts, RestDocsList, RestOldInfo,
            [NewInfo|AccNewInfos], RemoveSeqs, AccSeq+1)
    end.



new_index_entries([], AccById, AccBySeq, AccDDocIds) ->
    {AccById, AccBySeq, AccDDocIds};
new_index_entries([FullDocInfo|RestInfos], AccById, AccBySeq, AccDDocIds) ->
    #doc_info{revs=[#rev_info{deleted=Deleted}|_], id=Id} = DocInfo =
            libcouch_doc:to_doc_info(FullDocInfo),
    AccDDocIds2 = case Id of
    <<?DESIGN_DOC_PREFIX, _/binary>> ->
        [Id | AccDDocIds];
    _ ->
        AccDDocIds
    end,
    new_index_entries(RestInfos,
        [FullDocInfo#full_doc_info{deleted=Deleted}|AccById],
        [DocInfo|AccBySeq],
        AccDDocIds2).


stem_full_doc_infos(#db{revs_limit=Limit}, DocInfos) ->
    [Info#full_doc_info{rev_tree=libcouch_key_tree:stem(Tree, Limit)} ||
            #full_doc_info{rev_tree=Tree}=Info <- DocInfos].

update_docs_int(Db, DocsList, NonRepDocs, MergeConflicts, FullCommit) ->
    #db{
        fulldocinfo_by_id_btree = DocInfoByIdBTree,
        docinfo_by_seq_btree = DocInfoBySeqBTree,
        update_seq = LastSeq,
        revs_limit = RevsLimit
        } = Db,
    Ids = [Id || [{_Client, {#doc{id=Id}, _Ref}}|_] <- DocsList],
    % lookup up the old documents, if they exist.
    OldDocLookups = libcouch_btree:lookup(DocInfoByIdBTree, Ids),
    OldDocInfos = lists:zipwith(
        fun(_Id, {ok, FullDocInfo}) ->
            FullDocInfo;
        (Id, not_found) ->
            #full_doc_info{id=Id}
        end,
        Ids, OldDocLookups),
    % Merge the new docs into the revision trees.
    {ok, NewFullDocInfos, RemoveSeqs, NewSeq} = merge_rev_trees(RevsLimit,
            MergeConflicts, DocsList, OldDocInfos, [], [], LastSeq),

    % All documents are now ready to write.

    {ok, Db2}  = update_local_docs(Db, NonRepDocs),

    % Write out the document summaries (the bodies are stored in the nodes of
    % the trees, the attachments are already written to disk)
    {ok, FlushedFullDocInfos} = flush_trees(Db2, NewFullDocInfos, []),

    {IndexFullDocInfos, IndexDocInfos, UpdatedDDocIds} =
            new_index_entries(FlushedFullDocInfos, [], [], []),

    % and the indexes
    {ok, DocInfoByIdBTree2} = libcouch_btree:add_remove(DocInfoByIdBTree, IndexFullDocInfos, []),
    {ok, DocInfoBySeqBTree2} = libcouch_btree:add_remove(DocInfoBySeqBTree, IndexDocInfos, RemoveSeqs),

    Db3 = Db2#db{
        fulldocinfo_by_id_btree = DocInfoByIdBTree2,
        docinfo_by_seq_btree = DocInfoBySeqBTree2,
        update_seq = NewSeq},

    {ok, commit_data(Db3, not FullCommit), UpdatedDDocIds}.

update_local_docs(Db, []) ->
    {ok, Db};
update_local_docs(#db{local_docs_btree=Btree}=Db, Docs) ->
    Ids = [Id || {_Client, {#doc{id=Id}, _Ref}} <- Docs],
    OldDocLookups = libcouch_btree:lookup(Btree, Ids),
    BtreeEntries = lists:zipwith(
        fun({Client, {#doc{id=Id,deleted=Delete,revs={0,PrevRevs},body=Body}, Ref}}, OldDocLookup) ->
            case PrevRevs of
            [RevStr|_] ->
                PrevRev = list_to_integer(?b2l(RevStr));
            [] ->
                PrevRev = 0
            end,
            OldRev =
            case OldDocLookup of
                {ok, {_, {OldRev0, _}}} -> OldRev0;
                not_found -> 0
            end,
            case OldRev == PrevRev of
            true ->
                case Delete of
                    false ->
                        send_result(Client, Ref, {ok,
                                {0, ?l2b(integer_to_list(PrevRev + 1))}}),
                        {update, {Id, {PrevRev + 1, Body}}};
                    true  ->
                        send_result(Client, Ref,
                                {ok, {0, <<"0">>}}),
                        {remove, Id}
                end;
            false ->
                send_result(Client, Ref, conflict),
                ignore
            end
        end, Docs, OldDocLookups),

    BtreeIdsRemove = [Id || {remove, Id} <- BtreeEntries],
    BtreeIdsUpdate = [{Key, Val} || {update, {Key, Val}} <- BtreeEntries],

    {ok, Btree2} =
        libcouch_btree:add_remove(Btree, BtreeIdsUpdate, BtreeIdsRemove),

    {ok, Db#db{local_docs_btree = Btree2}}.


commit_data(Db) ->
    commit_data(Db, false).

db_to_header(Db, Header) ->
    Header#db_header{
        update_seq = Db#db.update_seq,
        docinfo_by_seq_btree_state = libcouch_btree:get_state(Db#db.docinfo_by_seq_btree),
        fulldocinfo_by_id_btree_state = libcouch_btree:get_state(Db#db.fulldocinfo_by_id_btree),
        local_docs_btree_state = libcouch_btree:get_state(Db#db.local_docs_btree),
        security_ptr = Db#db.security_ptr,
        revs_limit = Db#db.revs_limit}.

commit_data(#db{waiting_delayed_commit=nil} = Db, true) ->
    Db#db{waiting_delayed_commit=erlang:send_after(1000,self(),delayed_commit)};
commit_data(Db, true) ->
    Db;
commit_data(Db, _) ->
    #db{
        fd = Fd,
        filepath = Filepath,
        header = OldHeader,
        fsync_options = FsyncOptions,
        waiting_delayed_commit = Timer
    } = Db,
    if is_reference(Timer) -> erlang:cancel_timer(Timer); true -> ok end,
    case db_to_header(Db, OldHeader) of
    OldHeader ->
        Db#db{waiting_delayed_commit=nil};
    Header ->
        case lists:member(before_header, FsyncOptions) of
        true -> ok = libcouch_file:sync(Filepath);
        _    -> ok
        end,

        ok = libcouch_file:write_header(Fd, Header),

        case lists:member(after_header, FsyncOptions) of
        true -> ok = libcouch_file:sync(Filepath);
        _    -> ok
        end,

        Db#db{waiting_delayed_commit=nil,
            header=Header,
            committed_update_seq=Db#db.update_seq}
    end.


copy_doc_attachments(#db{fd = SrcFd} = SrcDb, SrcSp, DestFd) ->
    {ok, {BodyData, BinInfos0}} = libcouch_db:read_doc(SrcDb, SrcSp),
    BinInfos = case BinInfos0 of
    _ when is_binary(BinInfos0) ->
        libcouch_compress:decompress(BinInfos0);
    _ when is_list(BinInfos0) ->
        % pre 1.2 file format
        BinInfos0
    end,
    % copy the bin values
    NewBinInfos = lists:map(
        fun({Name, Type, BinSp, AttLen, RevPos, Md5}) ->
            % 010 UPGRADE CODE
            {NewBinSp, AttLen, AttLen, Md5, _IdentityMd5} =
                libcouch_stream:copy_to_new_stream(SrcFd, BinSp, DestFd),
            {Name, Type, NewBinSp, AttLen, AttLen, RevPos, Md5, identity};
        ({Name, Type, BinSp, AttLen, DiskLen, RevPos, Md5, Enc1}) ->
            {NewBinSp, AttLen, _, Md5, _IdentityMd5} =
                libcouch_stream:copy_to_new_stream(SrcFd, BinSp, DestFd),
            Enc = case Enc1 of
            true ->
                % 0110 UPGRADE CODE
                gzip;
            false ->
                % 0110 UPGRADE CODE
                identity;
            _ ->
                Enc1
            end,
            {Name, Type, NewBinSp, AttLen, DiskLen, RevPos, Md5, Enc}
        end, BinInfos),
    {BodyData, NewBinInfos}.

copy_docs(Db, #db{fd = DestFd} = NewDb, InfoBySeq0, Retry) ->
    % COUCHDB-968, make sure we prune duplicates during compaction
    InfoBySeq = lists:usort(fun(#doc_info{id=A}, #doc_info{id=B}) -> A =< B end,
        InfoBySeq0),
    Ids = [Id || #doc_info{id=Id} <- InfoBySeq],
    LookupResults = libcouch_btree:lookup(Db#db.fulldocinfo_by_id_btree, Ids),

    NewFullDocInfos1 = lists:map(
        fun({ok, #full_doc_info{rev_tree=RevTree}=Info}) ->
            Info#full_doc_info{rev_tree=libcouch_key_tree:map(
                fun(_, _, branch) ->
                    ?REV_MISSING;
                (_Rev, LeafVal, leaf) ->
                    IsDel = element(1, LeafVal),
                    Sp = element(2, LeafVal),
                    Seq = element(3, LeafVal),
                    {_Body, AttsInfo} = Summary = copy_doc_attachments(
                        Db, Sp, DestFd),
                    SummaryChunk = make_doc_summary(NewDb, Summary),
                    {ok, Pos, SummarySize} = libcouch_file:append_raw_chunk(
                        DestFd, SummaryChunk),
                    TotalLeafSize = lists:foldl(
                        fun({_, _, _, AttLen, _, _, _, _}, S) -> S + AttLen end,
                        SummarySize, AttsInfo),
                    {IsDel, Pos, Seq, TotalLeafSize}
                end, RevTree)}
        end, LookupResults),

    NewFullDocInfos = stem_full_doc_infos(Db, NewFullDocInfos1),
    NewDocInfos = [libcouch_doc:to_doc_info(Info) || Info <- NewFullDocInfos],
    RemoveSeqs =
    case Retry of
    false ->
        [];
    true ->
        % We are retrying a compaction, meaning the documents we are copying may
        % already exist in our file and must be removed from the by_seq index.
        Existing = libcouch_btree:lookup(NewDb#db.fulldocinfo_by_id_btree, Ids),
        [Seq || {ok, #full_doc_info{update_seq=Seq}} <- Existing]
    end,

    {ok, DocInfoBTree} = libcouch_btree:add_remove(
            NewDb#db.docinfo_by_seq_btree, NewDocInfos, RemoveSeqs),
    {ok, FullDocInfoBTree} = libcouch_btree:add_remove(
            NewDb#db.fulldocinfo_by_id_btree, NewFullDocInfos, []),
    NewDb#db{ fulldocinfo_by_id_btree=FullDocInfoBTree,
              docinfo_by_seq_btree=DocInfoBTree}.



copy_compact(Db, NewDb0, Retry) ->
    FsyncOptions = [Op || Op <- NewDb0#db.fsync_options, Op == before_header],
    Compression = libcouch_compress:get_compression_method(),
    NewDb = NewDb0#db{fsync_options=FsyncOptions, compression=Compression},
    TotalChanges = libcouch_db:count_changes_since(Db, NewDb#db.update_seq),
    BufferSize = list_to_integer(
        libcouch_config:get("database_compaction", "doc_buffer_size", "524288")),
    CheckpointAfter = libcouch_util:to_integer(
        libcouch_config:get("database_compaction", "checkpoint_after",
            BufferSize * 10)),

    EnumBySeqFun =
    fun(#doc_info{high_seq=Seq}=DocInfo, _Offset,
        {AccNewDb, AccUncopied, AccUncopiedSize, AccCopiedSize}) ->

        AccUncopiedSize2 = AccUncopiedSize + ?term_size(DocInfo),
        if AccUncopiedSize2 >= BufferSize ->
            NewDb2 = copy_docs(
                Db, AccNewDb, lists:reverse([DocInfo | AccUncopied]), Retry),
            AccCopiedSize2 = AccCopiedSize + AccUncopiedSize2,
            if AccCopiedSize2 >= CheckpointAfter ->
                {ok, {commit_data(NewDb2#db{update_seq = Seq}), [], 0, 0}};
            true ->
                {ok, {NewDb2#db{update_seq = Seq}, [], 0, AccCopiedSize2}}
            end;
        true ->
            {ok, {AccNewDb, [DocInfo | AccUncopied], AccUncopiedSize2,
                AccCopiedSize}}
        end
    end,

    TaskProps0 = [
        {type, database_compaction},
        {database, Db#db.name},
        {progress, 0},
        {changes_done, 0},
        {total_changes, TotalChanges}
    ],
    {ok, _, {NewDb2, Uncopied, _, _}} =
        libcouch_btree:foldl(Db#db.docinfo_by_seq_btree, EnumBySeqFun,
            {NewDb, [], 0, 0},
            [{start_key, NewDb#db.update_seq + 1}]),

    NewDb3 = copy_docs(Db, NewDb2, lists:reverse(Uncopied), Retry),

    % copy misc header values
    if NewDb3#db.security /= Db#db.security ->
        {ok, Ptr, _} = libcouch_file:append_term(
            NewDb3#db.fd, Db#db.security,
            [{compression, NewDb3#db.compression}]),
        NewDb4 = NewDb3#db{security=Db#db.security, security_ptr=Ptr};
    true ->
        NewDb4 = NewDb3
    end,

    commit_data(NewDb4#db{update_seq=Db#db.update_seq}).

start_copy_compact(#db{name=Name,filepath=Filepath,header=#db_header{purge_seq=PurgeSeq}}=Db) ->
    CompactFile = Filepath ++ ".compact",
    ?LOG_DEBUG("Compaction process spawned for db \"~s\"", [Name]),
    case libcouch_file:open(CompactFile) of
    {ok, Fd} ->
        Retry = true,
        case libcouch_file:read_header(Fd) of
        {ok, Header} ->
            ok;
        no_valid_header ->
            ok = libcouch_file:write_header(Fd, Header=#db_header{})
        end;
    {error, enoent} ->
        {ok, Fd} = libcouch_file:open(CompactFile, [create]),
        Retry = false,
        ok = libcouch_file:write_header(Fd, Header=#db_header{})
    end,
    NewDb = init_db(Name, CompactFile, Fd, Header, Db#db.options),
    NewDb2 = if PurgeSeq > 0 ->
        {ok, PurgedIdsRevs} = libcouch_db:get_last_purged(Db),
        {ok, Pointer, _} = libcouch_file:append_term(
            Fd, PurgedIdsRevs, [{compression, NewDb#db.compression}]),
        NewDb#db{header=Header#db_header{purge_seq=PurgeSeq, purged_docs=Pointer}};
    true ->
        NewDb
    end,
    unlink(Fd),

    NewDb3 = copy_compact(Db, NewDb2, Retry),
    close_db(NewDb3),
    gen_server:cast(Db#db.main_pid, {compact_done, CompactFile}).

make_doc_summary(#db{compression = Comp}, {Body0, Atts0}) ->
    Body = case libcouch_compress:is_compressed(Body0, Comp) of
    true ->
        Body0;
    false ->
        % pre 1.2 database file format
        libcouch_compress:compress(Body0, Comp)
    end,
    Atts = case libcouch_compress:is_compressed(Atts0, Comp) of
    true ->
        Atts0;
    false ->
        libcouch_compress:compress(Atts0, Comp)
    end,
    SummaryBin = ?term_to_bin({Body, Atts}),
    libcouch_file:assemble_file_chunk(SummaryBin, libcouch_util:md5(SummaryBin)).

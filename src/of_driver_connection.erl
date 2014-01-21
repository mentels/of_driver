%%%-------------------------------------------------------------------
%%% @copyright (C) 1999-2013, Erlang Solutions Ltd
%%% @author Ruan Pienaar <ruan.pienaar@erlang-solutions.com>
%%% @doc 
%%% OF Driver switch connection 
%%% @end
%%%-------------------------------------------------------------------
-module(of_driver_connection).
-copyright("2013, Erlang Solutions Ltd.").

-behaviour(gen_server).

-export([ sync_call/2 
    ]).

-export([ start_link/1,
          init/1,
          handle_call/3,
          handle_cast/2,
          handle_info/2,
          terminate/2,
          code_change/3
        ]).

-define(STATE, of_driver_connection_state).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_driver/include/of_driver_acl.hrl").
-include_lib("of_driver/include/of_driver_logger.hrl").

-record(?STATE,{ switch_handler      :: atom(),
                 switch_handler_opts :: list(),
                 socket              :: inet:socket(),
                 ctrl_versions       :: list(),
                 version             :: integer(),
                 pid                 :: pid(),
                 address             :: inet:ip_address(),
                 port                :: port(),
                 parser              :: #ofp_parser{},
                 hello_buffer = <<>> :: binary(),
                 protocol            :: tcp | ssl,
                 conn_role = main    :: main | aux,
                 aux_id              :: integer(),
                 datapath_info       :: { DatapathId :: integer(), DatapathMac :: term() },
                 connection_init     :: boolean(),
                 handler_state       :: term(),
                 handler_pid         :: pid(),
                 pending_msgs=[]     :: list({ XIDs :: integer(), OfpMessage :: #ofp_message{} | undefined }),
                 xid = 0             :: integer()
               }).

%%------------------------------------------------------------------

sync_call(ConnectionPid,Msgs) when is_list(Msgs) ->
    lists:foreach(fun(Msg) -> 
                    {ok,_XID} = gen_server:call(ConnectionPid,{send,Msg}) 
                  end, Msgs),
    gen_server:call(ConnectionPid,{send,barrier});
sync_call(ConnectionPid,Msg) ->
    {ok,_XID} = gen_server:call(ConnectionPid,{send,Msg}),
    gen_server:call(ConnectionPid,{send,barrier}).

%%------------------------------------------------------------------

start_link(Socket) ->
    gen_server:start_link(?MODULE, [Socket], []).

init([Socket]) ->
    process_flag(trap_exit, true),
    {ok, {Address, Port}} = inet:peername(Socket),
    case of_driver:allowed_ipaddr(Address) of
        {true, #?ACL_TBL{switch_handler = SwitchHandler,
                         opts           = Opts } = _Entry} ->
            ?INFO("Connected to Switch on ~p:~p. Connection : ~p \n",[Address, Port, self()]),
            Versions = of_driver_utils:conf_default(of_compatible_versions, fun erlang:is_list/1, [3, 4]),
            Protocol = tcp,
            of_driver_utils:setopts(Protocol, Socket, [{active, once}]),
            ok = gen_server:cast(self(),{send,hello}),
            {ok, #?STATE{ switch_handler      = SwitchHandler,
                          switch_handler_opts = Opts,
                          socket              = Socket,
                          ctrl_versions       = Versions,
                          protocol            = Protocol,
                          aux_id              = 0,
                          connection_init     = false,
                          address             = Address,
                          port                = Port
                        }};
        false ->
            terminate_connection(Socket),
            ?WARNING("Rejecting connection - "
                    "IP Address not allowed ipaddr(~p) port(~p)\n",
                                                        [Address, Port]),
            ignore
    end.

%%------------------------------------------------------------------

handle_call(close_connection,_From,State) ->
    close_of_connection(State,called_close_connection);
handle_call({send,barrier},From,#?STATE{ version  = Version } = State) ->
    Barrier = of_msg_lib:barrier(Version),
    XID = handle_send(Barrier,State),
    {noreply,State#?STATE{ xid          = XID,
                           pending_msgs = [{XID,From}|State#?STATE.pending_msgs]
                          }};
handle_call({send,OfpMsg},_From,State) ->
    XID = handle_send(OfpMsg,State),
    {reply,{ok,XID},State#?STATE{ xid          = XID,
                                  pending_msgs = [{XID,no_response}|State#?STATE.pending_msgs]
                                 }};
handle_call(pending_msgs,_From,State) -> %% ***DEBUG
    {reply,{ok,State#?STATE.pending_msgs},State}.

handle_send(Msg,#?STATE{ protocol = Protocol,
                         socket   = Socket,
                         xid      = XID } = _State) ->
  NextXID = XID+1,
  {ok,EncodedMessage} = of_protocol:encode( Msg#ofp_message{ xid = NextXID } ),
  ok = of_driver_utils:send(Protocol,Socket,EncodedMessage),
  NextXID.
    
%%------------------------------------------------------------------

handle_cast({send,hello},State) ->
    Versions = of_driver_utils:conf_default(of_compatible_versions, fun erlang:is_list/1, [3, 4]),
    Msg=of_driver_utils:create_hello(Versions),
    handle_cast_send(Msg,State),
    {noreply, State};
handle_cast({send,Msg},State) ->
    handle_cast_send(Msg,State),
    {noreply, State}.

handle_cast_send(Msg,#?STATE{ protocol = Protocol,
                              socket   = Socket } = _State) ->
    {ok,EncodedMessage} = of_protocol:encode(Msg),
    ok = of_driver_utils:send(Protocol,Socket,EncodedMessage).

%%------------------------------------------------------------------

handle_info({'EXIT',_FromPid,_Reason},State) ->
    close_of_connection(State,trap_exit_close);
handle_info({tcp, Socket, Data},#?STATE{ parser        = undefined,
                                         version       = undefined,
                                         ctrl_versions = Versions,
                                         hello_buffer  = Buffer,
                                         protocol      = Protocol
                                       } = State) ->
    of_driver_utils:setopts(Protocol, Socket, [{active, once}]),
    case of_protocol:decode(<<Buffer/binary, Data/binary>>) of
        {ok, #ofp_message{xid = Xid, body = #ofp_hello{}} = Hello, _Leftovers} -> %% and do something with Leftovers ... 
            case decide_on_version(Versions, Hello) of
                {failed, Reason} ->
                    handle_failed_negotiation(Xid, Reason, State);
                Version = 3 -> %% of_msg_lib only currently supports V4... 
                    {ok, Parser} = ofp_parser:new(Version),
                    {ok,FeaturesBin} = of_protocol:encode(of_driver_utils:create_features_request(Version)),
                    send_features_reply(FeaturesBin,State#?STATE{ parser = Parser, version = Version });
                Version ->
                    {ok, Parser} = ofp_parser:new(Version),
                    {ok,FeaturesBin} = of_protocol:encode(of_msg_lib:get_features(Version)),
                    send_features_reply(FeaturesBin,State#?STATE{ parser = Parser, version = Version })
            end;
        {error, binary_too_small} ->
            {noreply, State#?STATE{hello_buffer = <<Buffer/binary,
                                                    Data/binary>>}};
        {error, unsupported_version, Xid} ->
            handle_failed_negotiation(Xid, unsupported_version_or_bad_message,
                                      State)
    end;
handle_info({tcp, Socket, Data},#?STATE{ protocol = Protocol, socket = Socket } = State) ->
    of_driver_utils:setopts(Protocol,Socket,[{active, once}]),
    do_handle_tcp(State,Data);
handle_info({tcp_closed,_Socket},State) ->
    close_of_connection(State,tcp_closed);
handle_info({tcp_error, _Socket, _Reason},State) ->
    close_of_connection(State,tcp_error).

%%------------------------------------------------------------------

terminate(_Reason,State) ->
    close_of_connection(State,gen_server_terminate),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%-----------------------------------------------------------------------------

send_features_reply(FeaturesBin,#?STATE{ socket = Socket, protocol = Protocol } = State) ->
    ok = of_driver_utils:send(Protocol, Socket, FeaturesBin),
    {noreply, State}.

%%-----------------------------------------------------------------------------

do_handle_tcp(#?STATE{ parser = Parser} = State,Data) ->
    case ofp_parser:parse(Parser, Data) of
        {ok, NewParser, Messages} ->
            case do_handle_message(Messages,State) of
                {ok,NewState} ->
                    {noreply, NewState#?STATE{parser = NewParser}};
                {stop, Reason, NewState} ->
                    {stop, Reason, NewState}
            end;
        _Else ->
            close_of_connection(State,parse_error)
    end.  

do_handle_message([],NewState) ->
    {ok,NewState};
do_handle_message([Message|Rest],NewState) ->
    case handle_message(Message,NewState) of
        {stop, Reason, State} ->
            {stop, Reason, State};
        NextState ->
            do_handle_message(Rest,NextState)
    end.

handle_message(#ofp_message{version = Version = 3,
                            type    = features_reply,
                            body    = Body} = _Msg,
                            #?STATE{connection_init     = false,
                                    switch_handler      = SwitchHandler,
                                    switch_handler_opts = Opts,
                                    address             = IpAddr,
                                    port                = Port} = State) ->
    {ok,DatapathInfo} = of_driver_utils:get_datapath_info(Version, Body),
    NewState = State#?STATE{datapath_info = DatapathInfo},
    ok = of_driver_db:insert_switch_connection(IpAddr, Port, self(),NewState#?STATE.conn_role),
    {ok, HandlerPid, _HandlerState} = SwitchHandler:init(IpAddr, DatapathInfo, Body, Version, self(), Opts),
    NewHandlerState = SwitchHandler:handle_connect(HandlerPid,self(),NewState#?STATE.conn_role,NewState#?STATE.aux_id),
    NewState#?STATE{ handler_pid   = HandlerPid,
                     handler_state = NewHandlerState };
handle_message(#ofp_message{version = Version,
                            type    = features_reply,
                            body    = Body} = _Msg,
                            #?STATE{connection_init     = false,
                                    switch_handler      = SwitchHandler,
                                    switch_handler_opts = Opts,
                                    address             = IpAddr,
                                    port                = Port} = State) ->
    {ok,DatapathInfo} = of_driver_utils:get_datapath_info(Version, Body),
    {ok,AuxID} = of_driver_utils:get_aux_id(Version, Body),
    case handle_datapath(State#?STATE{ datapath_info = DatapathInfo, 
                                       aux_id        = AuxID }) of 
        {stop, Reason, State} ->
            {stop, Reason, State};
        NewState ->
            ok = of_driver_db:insert_switch_connection(IpAddr, Port, self(),NewState#?STATE.conn_role),
            {ok, HandlerPid, _HandlerState} = SwitchHandler:init(IpAddr, DatapathInfo, Body, Version, self(), Opts),
            NewHandlerState = SwitchHandler:handle_connect(HandlerPid,self(),NewState#?STATE.conn_role,NewState#?STATE.aux_id),
            NewState#?STATE{ handler_pid   = HandlerPid,
                             handler_state = NewHandlerState }
    end;

handle_message(Msg, #?STATE{connection_init = true,
                            pending_msgs = [] } = State) ->
    switch_handler_next_state(Msg,State);
handle_message(Msg, #?STATE{connection_init = true,
                            pending_msgs = _PSM } = State) ->
    NextState=handle_pending_msg(Msg,State),
    switch_handler_next_state(Msg,NextState).

handle_pending_msg(#ofp_message{ xid = XID, type = barrier_reply } = Msg,#?STATE{ pending_msgs = PSM } = State) ->
    {XID,From} = lists:keyfind(XID, 1, PSM),
    ReplyListWithBarrier = lists:keyreplace(XID,1,PSM,{XID,Msg}),
    F = fun({_SomeXID,no_reply}) -> false; ({_SomeXID,#ofp_message{} = _Reply}) -> true end,
    {ReplyList,PendingList} = lists:partition(F,ReplyListWithBarrier),
    gen_server:reply(From, {ok,lists:foldl(fun({_MsgXID,M},Acc) -> [M|Acc] end,[],ReplyList)}),
    State#?STATE{ pending_msgs = PendingList };
handle_pending_msg(#ofp_message{ xid = XID, type = _Type } = Msg,#?STATE{ pending_msgs = PSM } = State) ->
    {XID,no_response} = lists:keyfind(XID, 1, PSM),
    State#?STATE{ pending_msgs = lists:keyreplace(XID,1,PSM,{XID,Msg}) }.

handle_datapath(#?STATE{ datapath_info  = DatapathInfo,
                         aux_id         = AuxID} = State) ->
    case of_driver_db:lookup_datapath_id(DatapathInfo) of
        [] when AuxID =:= 0 ->
            of_driver_db:insert_datapath_id(DatapathInfo,self()),
            State#?STATE{conn_role       = main,
                         connection_init = true};
        [] when AuxID =/= 0 ->
            close_of_connection(State,aux_conflict);
        [Entry] when AuxID =/= 0 ->
            of_driver_db:add_aux_id(Entry,DatapathInfo,{AuxID, self()}),
            State#?STATE{conn_role       = aux,
                         connection_init = true,
                         aux_id          = AuxID};
        _ ->
            close_of_connection(State,aux_conflict)
    end.

switch_handler_next_state(Msg,#?STATE{ switch_handler = SwitchHandler,
                                       handler_pid    = HandlerPid } = State) ->
    {ok,NewHandlerState} = SwitchHandler:handle_message(Msg,HandlerPid),
    State#?STATE{handler_state = NewHandlerState}.

%%-----------------------------------------------------------------------------

close_of_connection(#?STATE{ socket        = Socket,
                             datapath_info = DatapathInfo,
                             conn_role     = ConnRole,
                             aux_id        = AuxID,
                             handler_pid   = HandlerPid,
                             address       = Address,
                             port          = Port } = State, Reason) ->
    ok = gen_server:cast(HandlerPid,close_connection),
    of_driver_db:remove_datapath_id(ConnRole,DatapathInfo,AuxID),   
    ok = of_driver_db:remove_switch_connection(Address, Port),
    ok = terminate_connection(Socket),
    ?WARNING("connection terminated: datapathid(~p) aux_id(~p) reason(~p)\n",
                            [DatapathInfo, AuxID, Reason]),
    {stop, normal, State}.

%%-----------------------------------------------------------------------------

decide_on_version(SupportedVersions, #ofp_message{version = CtrlHighestVersion,
                                                  body    = HelloBody}) ->
    SupportedHighestVersion = lists:max(SupportedVersions),
    if
        SupportedHighestVersion == CtrlHighestVersion ->
            SupportedHighestVersion;
        SupportedHighestVersion >= 4 andalso CtrlHighestVersion >= 4 ->
            decide_on_version_with_bitmap(SupportedVersions, CtrlHighestVersion,
                                          HelloBody);
        true ->
            decide_on_version_without_bitmap(SupportedVersions,
                                             CtrlHighestVersion)
    end.

decide_on_version_with_bitmap(SupportedVersions, CtrlHighestVersion,
                                                                  HelloBody) ->
    Elements = HelloBody#ofp_hello.elements,
    SwitchVersions = get_opt(versionbitmap, Elements, []),
    SwitchVersions2 = lists:umerge([CtrlHighestVersion], SwitchVersions),
    case greatest_common_version(SupportedVersions, SwitchVersions2) of
        no_common_version ->
            {failed, {no_common_version, SupportedVersions, SwitchVersions2}};
        Version ->
            Version
    end.

decide_on_version_without_bitmap(SupportedVersions, CtrlHighestVersion) ->
    case lists:member(CtrlHighestVersion, SupportedVersions) of
        true ->
            CtrlHighestVersion;
        false ->
            {failed, {unsupported_version, CtrlHighestVersion}}
    end.

get_opt(Opt, Opts, Default) ->
    case lists:keyfind(Opt, 1, Opts) of
        false ->
            Default;
        {Opt, Value} ->
            Value
    end.

greatest_common_version([], _) ->
    no_common_version;
greatest_common_version(_, []) ->
    no_common_version;
greatest_common_version(ControllerVersions, SwitchVersions) ->
    lists:max([CtrlVersion || CtrlVersion <- ControllerVersions,
                              lists:member(CtrlVersion, SwitchVersions)]).

handle_failed_negotiation(Xid, _Reason, #?STATE{socket        = Socket,
                                                ctrl_versions = Versions } = State) ->
    send_incompatible_version_error(Xid, Socket, tcp,lists:max(Versions)),
    close_of_connection(State,failed_version_negotiation).

send_incompatible_version_error(Xid, Socket, Proto, OFVersion) ->
    ErrorMessageBody = create_error(OFVersion, hello_failed, incompatible),
    ErrorMessage = #ofp_message{version = OFVersion,
                                xid     = Xid,
                                body    = ErrorMessageBody},
    {ok, EncodedErrorMessage} = of_protocol:encode(ErrorMessage),
    ok = of_driver_utils:send(Proto, Socket, EncodedErrorMessage).

%% TODO: move to of_msg_lib...
create_error(3, Type, Code) ->
    ofp_client_v3:create_error(Type, Code);
create_error(4, Type, Code) ->
    ofp_client_v4:create_error(Type, Code).

terminate_connection(Socket) ->
    % XXX call appropriate callback
    of_driver_utils:close(tcp, Socket).

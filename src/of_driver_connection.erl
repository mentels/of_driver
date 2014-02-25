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
-define(NOREPLY, noreply).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_driver/include/of_driver_logger.hrl").

% XXX can only handle one sync_send at a time.  Can organize
% XIDs by XID of barrier reply to get around this.

-record(?STATE,{ switch_handler          :: atom(),
                 switch_handler_opts     :: list(),
                 socket                  :: inet:socket(),
                 ctrl_versions           :: list(),
                 version                 :: integer(),
                 pid                     :: pid(),
                 main_monitor            :: reference(),
                 address                 :: inet:ip_address(),
                 port                    :: port(),
                 parser                  :: #ofp_parser{},
                 hello_buffer = <<>>     :: binary(),
                 protocol                :: tcp | ssl,
                 aux_id = 0              :: integer(),
                 datapath_info           :: { DatapathId :: integer(), DatapathMac :: term() },
                 connection_init = false :: boolean(),
                 handler_state           :: term(),
                 pending_msgs=[]         :: list({ XIDs :: integer(), OfpMessage :: #ofp_message{} | undefined }),
                 xid = 0                 :: integer(),
                 startup_leftovers       :: binary()
               }).

%%------------------------------------------------------------------

sync_call(ConnectionPid, Msgs) when is_list(Msgs) ->
    lists:foreach(fun(Msg) -> 
                    {ok,_XID} = gen_server:call(ConnectionPid,{send, Msg},infinity) %% TODO, work on timeout scenario
                  end, Msgs),
    gen_server:call(ConnectionPid,{send, barrier},infinity);
sync_call(ConnectionPid, Msg) ->
    {ok,_XID} = gen_server:call(ConnectionPid,{send, Msg},infinity), %% TODO, work on timeout scenario
    case gen_server:call(ConnectionPid,{send, barrier},infinity) of
        {ok, [{ok, Reply}]} ->
            {ok, Reply};
        Reply ->
            Reply
    end.

%%------------------------------------------------------------------

start_link(Socket) ->
    gen_server:start_link(?MODULE, [Socket], []).

init([Socket]) ->
    Protocol = tcp,
    of_driver_utils:setopts(Protocol, Socket, [{active, once}]),
    {ok, {Address, Port}} = inet:peername(Socket),
    SwitchHandler = of_driver_utils:conf_default(callback_module, of_driver_default_handler),
    Opts          = of_driver_utils:conf_default(init_opt,[ {enable_ping,false},
                                                            {ping_timeout,1000},
                                                            {ping_idle,5000},
                                                            {multipart_timeout,30000},
                                                            {callback_mod,echo_logic}
                                                          ]),
    ?INFO("Connected to Switch on ~s:~p. Connection : ~p \n",[inet_parse:ntoa(Address), Port, self()]),
    Versions = of_driver_utils:conf_default(of_compatible_versions, fun erlang:is_list/1, [3, 4]),
    ok = gen_server:cast(self(),{send,hello}),
    {ok, #?STATE{ switch_handler      = SwitchHandler,
                  switch_handler_opts = Opts,
                  socket              = Socket,
                  ctrl_versions       = Versions,
                  protocol            = Protocol,
                  address             = Address,
                  port                = Port
                }}.

%%------------------------------------------------------------------

handle_call(close_connection, _From, State) ->
    close_of_connection(State,called_close_connection);
handle_call({send, barrier}, From, #?STATE{version  = Version} = State) ->
    Barrier = of_msg_lib:barrier(Version),
    XID = handle_send(Barrier, State),
    {noreply, State#?STATE{ xid          = XID,
                           pending_msgs = [{XID, From} | State#?STATE.pending_msgs]
                          }};
handle_call({send, OfpMsg}, _From, State) ->
    XID = handle_send(OfpMsg,State),
    {reply, {ok, XID}, State#?STATE{xid          = XID,
                                    pending_msgs = [{XID, ?NOREPLY} | State#?STATE.pending_msgs]
                                   }};
handle_call(next_xid,_From,#?STATE{ xid = XID } = State) ->
    NextXID = XID + 1,
    {reply,{ok,NextXID},State#?STATE{ xid = NextXID}};
handle_call(pending_msgs,_From,State) -> %% ***DEBUG
    {reply,{ok,State#?STATE.pending_msgs},State};
handle_call(state,_From,State) ->
    {reply,{ok,State},State}.

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
    case of_protocol:encode(Msg) of
        {ok,EncodedMessage} ->
            ok = of_driver_utils:send(Protocol,Socket,EncodedMessage);
        {error, Error} ->
            % XXX communicate this back somehow
            ?ERROR("bad message: ~p ~p~n", [Error, Msg])
    end.

%%------------------------------------------------------------------

handle_info({'DOWN', MonitorRef, process, _MainPid, Reason},
                            State = #?STATE{main_monitor = MonitorRef}) ->
    close_of_connection(State, {main_closed, Reason});
handle_info({tcp, Socket, Data},#?STATE{ protocol = Protocol, socket = Socket } = State) ->
    of_driver_utils:setopts(Protocol,Socket,[{active, once}]),
    do_handle_tcp(State, Data);
handle_info({tcp_closed,_Socket},State) ->
    close_of_connection(State,tcp_closed);
handle_info({tcp_error, _Socket, _Reason},State) ->
    close_of_connection(State,tcp_error).

%%------------------------------------------------------------------

terminate(Reason, #?STATE{socket = undefined}) ->
    % terminating after connection is closed
    ?INFO("[~p] terminating: ~p~n",[?MODULE, Reason]),
    ok;
terminate(Reason, State) ->
    % terminate and close connection
    ?INFO("[~p] terminating (crash): ~p~n",[?MODULE, Reason]),
    close_of_connection(State,gen_server_terminate),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%-----------------------------------------------------------------------------

do_handle_tcp(State, <<>>) ->
    {noreply, State};
do_handle_tcp(#?STATE{parser        = undefined,
                      version       = undefined,
                      socket        = Socket,
                      ctrl_versions = Versions,
                      hello_buffer  = Buffer,
                      protocol      = Protocol
                     } = State, Data) ->
    case of_protocol:decode(<<Buffer/binary, Data/binary>>) of
        {ok, #ofp_message{xid = Xid, body = #ofp_hello{}} = Hello, Leftovers} ->
            case decide_on_version(Versions, Hello) of
                {failed, Reason} ->
                    handle_failed_negotiation(Xid, Reason, State);
                Version ->
                    {ok, Parser} = ofp_parser:new(Version),
                    {ok, FeaturesBin} = of_protocol:encode(create_features_request(Version)),
                    ok = of_driver_utils:send(Protocol, Socket, FeaturesBin),
                    do_handle_tcp(State#?STATE{parser = Parser,
                                               version = Version}, Leftovers)
            end;
        {ok, #ofp_message{xid = _Xid, body = _Body} = Msg, Leftovers} ->
            ?WARNING("Hello handshake in progress, dropping message: ~p~n",[Msg]),
            do_handle_tcp(State, Leftovers);
        {error, binary_too_small} ->
            {noreply, State#?STATE{hello_buffer = <<Buffer/binary,
                                                    Data/binary>>}};
        {error, unsupported_version, Xid} ->
            handle_failed_negotiation(Xid, unsupported_version_or_bad_message,
                                      State)
    end;
do_handle_tcp(#?STATE{ parser = Parser} = State, Data) ->
    case ofp_parser:parse(Parser, Data) of
        {ok, NewParser, Messages} ->
            case handle_messages(Messages, State) of
                {ok,NewState} ->
                    {noreply, NewState#?STATE{parser = NewParser}};
                {stop, Reason, NewState} ->
                    {stop, Reason, NewState}
            end;
        _Else ->
            close_of_connection(State,parse_error)
    end.  

handle_messages([], NewState) ->
    {ok, NewState};
handle_messages([Message|Rest], NewState) ->
    case handle_message(Message, NewState) of
        {stop, Reason, State} ->
            {stop, Reason, State};
        NextState ->
            handle_messages(Rest, NextState)
    end.

handle_message(#ofp_message{version = Version,
                            type    = features_reply,
                            body    = Features} = _Msg,
                            #?STATE{connection_init     = false,
                                    switch_handler      = SwitchHandler,
                                    switch_handler_opts = Opts,
                                    address             = IpAddr} = State) ->
    % process feature reply from our initial handshake
    {ok, DatapathInfo} = of_driver_utils:get_datapath_info(Version, Features),
    NewState1 = State#?STATE{datapath_info = DatapathInfo},
    NewState2 = case Version of
        3 ->
            NewState1#?STATE{aux_id = 0};
        _ ->
            {ok, AuxID} = of_driver_utils:get_aux_id(Version, Features),
            NewState1#?STATE{aux_id = AuxID}
    end,
    case handle_datapath(NewState2) of 
        Error1 = {stop, _, _} ->
            Error1;
        NewState3 ->
            InitAuxID = NewState3#?STATE.aux_id,
            R = case InitAuxID of
                0 ->
                    do_callback(SwitchHandler, init,
                                        [IpAddr, DatapathInfo,
                                         Features, Version, self(), Opts],
                                        NewState3);
                _ ->
                    MainPid = of_driver_db:lookup_connection(DatapathInfo, 0),
                    MonitorRef = erlang:monitor(process, MainPid),
                    NewState4 = NewState3#?STATE{main_monitor = MonitorRef},
                    do_callback(SwitchHandler, handle_connect,
                                        [IpAddr, DatapathInfo, Features,
                                         Version, self(), InitAuxID, Opts],
                                        NewState4)
            end,
            case R of
                Error2 = {stop, _, _} ->
                    Error2;
                NewState5 ->
                    NewState5#?STATE{connection_init = true}
            end
    end;
handle_message(#ofp_message{} = Msg, #?STATE{connection_init = false} = State) ->
    ?WARNING("Features handshake in progress, dropping message: ~p~n",[Msg]),
    State;
handle_message(Msg, #?STATE{pending_msgs = []} = State) ->
    % no sync requests to process
    switch_handler_next_state(Msg, State);
handle_message(#ofp_message{xid = XID, type = barrier_reply} = Msg,
                                    #?STATE{pending_msgs = PSM} = State) ->
    case lists:keyfind(XID, 1, PSM) of 
        {XID, ?NOREPLY} ->
            % Prevent intentional barrier REPLY's in list of
            % msg's from trying to gen_server:reply
            update_response(XID, Msg, PSM, State);
        {XID, From} ->
            ReplyListWithoutBarrier = lists:keydelete(XID, 1, PSM),
            gen_server:reply(From, {ok,
                lists:reverse([{ok, R} || {_XID, R} <- ReplyListWithoutBarrier])}),
            State#?STATE{pending_msgs = []}
    end;
handle_message(#ofp_message{ xid = XID, type = _Type } = Msg,#?STATE{ pending_msgs = PSM } = State) ->
    update_response(XID, Msg, PSM, State).
    
% XXX is PSM a necessary parameter?  just read from state?
update_response(XID, Msg, PSM, State) ->
    case lists:keyfind(XID, 1, PSM) of
        {XID, ?NOREPLY} ->
            State#?STATE{pending_msgs = lists:keyreplace(XID, 1, PSM, {XID,Msg})};
        {XID, _} ->
            % XXX more than one response - report an error
            State;
        false ->
            % these aren't the droids you're looking for...
            switch_handler_next_state(Msg, State)
    end.

handle_datapath(#?STATE{ datapath_info = DatapathInfo,
                         aux_id        = AuxID} = State) ->
    case of_driver_db:insert_connection(DatapathInfo, AuxID, self()) of
        true ->
            State;
        false ->
            % duplicate main connection
            close_of_connection(State, already_connected)
    end.

switch_handler_next_state(Msg, #?STATE{ switch_handler = SwitchHandler,
                                       handler_state = HandlerState
                                       } = State) ->
    {ok, NewHandlerState} = SwitchHandler:handle_message(Msg, HandlerState),
    State#?STATE{handler_state = NewHandlerState}.

%%-----------------------------------------------------------------------------

close_of_connection(#?STATE{ socket        = Socket,
                             datapath_info = DatapathInfo,
                             aux_id        = AuxID,
                             switch_handler= SwitchHandler,
                             handler_state = HandlerState } = State, Reason) ->
    ?WARNING("connection terminated: datapathid(~p) aux_id(~p) reason(~p)~n",
                            [DatapathInfo, AuxID, Reason]),
    of_driver_db:delete_connection(DatapathInfo, AuxID),   
    connection_close_callback(SwitchHandler,HandlerState,AuxID),
    ok = terminate_connection(Socket),
    {stop, normal, State#?STATE{socket = undefined}}.

connection_close_callback(Module, HandlerState, 0) ->
    Module:terminate(driver_closed_connection, HandlerState);
connection_close_callback(Module, HandlerState, _AuxID) ->
    Module:handle_disconnect(driver_closed_connection,HandlerState).

%%-----------------------------------------------------------------------------

create_features_request(3) ->
    of_driver_utils:create_features_request(3);
create_features_request(Version) ->
    of_msg_lib:get_features(Version).

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
    of_driver_utils:close(tcp, Socket).

do_callback(M, F, A, State) ->
    case erlang:apply(M, F, A) of
        {ok, HandlerState} ->
            State#?STATE{handler_state = HandlerState};
        {error, Reason} ->
            {stop, Reason, State}
    end.

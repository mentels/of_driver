%%%-------------------------------------------------------------------
%%% @copyright (C) 1999-2013, Erlang Solutions Ltd
%%% @author Ruan Pienaar <ruan.pienaar@erlang-solutions.com>
%%% @doc 
%%% 
%%% @end
%%%-------------------------------------------------------------------
-module(of_driver_v4).
-copyright("2013, Erlang Solutions Ltd.").

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v4.hrl").

-export([features_request/0,
         get_datapath_info/1,
	 get_aux_id/1
        ]).

features_request() ->
    Body = #ofp_features_request{},
    {ok,#ofp_message{version = 4, xid = 0, body = Body}}.

get_datapath_info(Rec) ->
    #ofp_features_reply{datapath_id = DatapathID, datapath_mac = DatapathMac} = Rec,
    {ok,{DatapathID,DatapathMac}}.

get_aux_id(Rec) ->
    #ofp_features_reply{auxiliary_id = AuxID} = Rec,
    {ok,AuxID}.

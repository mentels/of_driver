%%%-------------------------------------------------------------------
%%% @copyright (C) 1999-2013, Erlang Solutions Ltd
%%% @author Ruan Pienaar <ruan.pienaar@erlang-solutions.com>
%%% @doc 
%%% OF Driver channel
%%% @end
%%%-------------------------------------------------------------------
-module(of_driver_channel).
-copyright("2013, Erlang Solutions Ltd.").

-behaviour(gen_server).

-export([start_link/1, init/1, handle_call/3, handle_cast/2, handle_info/2,terminate/2, code_change/3]).
-export([
	]).

-define(STATE,of_driver_channel_state).

-record(?STATE, {}).

%%------------------------------------------------------------------

start_link(DatapathId) ->
    gen_server:start_link(?MODULE, [DatapathId], []).

init([_DatapathId]) ->
    {ok, #?STATE{ }}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%------------------------------------------------------------------

%% create channels.......................

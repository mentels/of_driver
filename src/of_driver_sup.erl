-module(of_driver_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    
    case ets:info(of_driver_channel_datapath) of
        undefined ->
            of_driver_channel_datapath = ets:new(of_driver_channel_datapath,[ordered_set,public,named_table]);
        Options ->
            ok
    end,
    
    RestartStrategy = one_for_one,
    
    MaxRestarts = 1000,
    MaxSecondsBetweenRestarts = 3600,

    SupFlags = {RestartStrategy, MaxRestarts, MaxSecondsBetweenRestarts},
    
    Restart = permanent,
    Shutdown = 2000,
    Type = worker,
    
    Ch = of_driver_channel_sup,
    ChSup = {Ch, {Ch, start_link, []}, Restart, Shutdown, Type, [Ch]},
    
    C = of_driver_connection_sup,
    CSup = {C, {C, start_link, []}, Restart, Shutdown, Type, [C]},
    
    L = of_driver_listener,
    LChild = {L, {L, start_link, []}, Restart, Shutdown, Type, [L]},
    
    {ok, {SupFlags, [ ChSup,
		      CSup,
                      LChild
		    ]}
    }.

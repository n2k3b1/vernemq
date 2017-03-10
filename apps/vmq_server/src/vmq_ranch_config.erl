%% Copyright 2014 Erlio GmbH Basel Switzerland (http://erl.io)
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(vmq_ranch_config).

%% API
-export([start_listener/4,
         reconfigure_listeners/1,
         stop_listener/2,
         stop_listener/3,
         stop_all_mqtt_listeners/1,
         delete_listener/2,
         restart_listener/2,
         get_listener_config/2,
         listeners/0]).

listener_sup_sup(Addr, Port) ->
    AAddr = addr(Addr),
    Ref = listener_name(AAddr, Port),
    case lists:keyfind({ranch_listener_sup, Ref}, 1, supervisor:which_children(ranch_sup)) of
        false ->
            {error, not_found};
        {_, ListenerSupSupPid, supervisor, _} when is_pid(ListenerSupSupPid) ->
            {ok, ListenerSupSupPid}
    end.

stop_all_mqtt_listeners(KillSessions) ->
    lists:foreach(
      fun
          ({mqtt, Addr, Port, _, _, _}) -> stop_listener(Addr, Port, KillSessions);
          ({mqtts, Addr, Port, _, _, _}) -> stop_listener(Addr, Port, KillSessions);
          ({mqttws, Addr, Port, _, _, _}) -> stop_listener(Addr, Port, KillSessions);
          ({mqttwss, Addr, Port, _, _, _}) -> stop_listener(Addr, Port, KillSessions);
          (_) -> ignore
      end, listeners()).

stop_listener(Addr, Port) ->
    stop_listener(Addr, Port, false).
stop_listener(Addr, Port, KillSessions) when is_list(Port) ->
    stop_listener(Addr, list_to_integer(Port), KillSessions);
stop_listener(Addr, Port, KillSessions) ->
    case listener_sup_sup(Addr, Port) of
        {ok, Pid} when KillSessions ->
            supervisor:terminate_child(Pid, ranch_conns_sup),
            supervisor:terminate_child(Pid, ranch_acceptors_sup);
        {ok, Pid} ->
            supervisor:terminate_child(Pid, ranch_acceptors_sup);
        E -> E
    end.

restart_listener(Addr, Port) ->
    case listener_sup_sup(Addr, Port) of
        {ok, Pid} ->
            case {supervisor:restart_child(Pid, ranch_conns_sup),
                  supervisor:restart_child(Pid, ranch_acceptors_sup)} of
                {{ok, _}, {ok, _}} ->
                    ok;
                {{error, running}, {ok, _}} ->
                    ok;
                {{error, R1}, {error, R2}} ->
                    {error, {R1, R2}}
            end;
        E ->
            E
    end.

delete_listener(Addr, Port) ->
    AAddr = addr(Addr),
    Ref = listener_name(AAddr, Port),
    delete_listener(Ref).

delete_listener(ListenerRef) ->
    case supervisor:terminate_child(ranch_sup, {ranch_listener_sup, ListenerRef}) of
        {error, _} ->
            ok;
        ok ->
            _ = supervisor:delete_child(ranch_sup, {ranch_listener_sup, ListenerRef}),
            ranch_server:cleanup_listener_opts(ListenerRef)
    end.

start_listener(Type, Addr, Port, Opts) when is_list(Opts) ->
    TCPOpts = vmq_config:get_env(tcp_listen_options),
    TransportOpts = TCPOpts ++ transport_opts_for_type(Type, Opts),
    start_listener(Type, Addr, Port, {TransportOpts, Opts});
start_listener(Type, Addr, Port, {TransportOpts, Opts}) ->
    AAddr = addr(Addr),
    Ref = listener_name(AAddr, Port),
    MaxConns = proplists:get_value(max_connections, Opts,
                                   vmq_config:get_env(max_connections)),
    NrOfAcceptors = proplists:get_value(nr_of_acceptors, Opts,
                                        vmq_config:get_env(nr_of_acceptors)),
    TransportMod =
    case proplists:get_value(proxy_protocol, Opts, false) of
        false -> transport_for_type(Type);
        true -> vmq_ranch_proxy_protocol
    end,
    case ranch:start_listener(Ref, NrOfAcceptors, TransportMod,
                              [{ip, AAddr}, {port, Port}|TransportOpts],
                              protocol_for_type(Type),
                              protocol_opts_for_type(Type, Opts)) of
        {ok, _} ->
            ranch:set_max_connections(Ref, MaxConns);
        E ->
            E
    end.

listeners() ->
    lists:foldl(
      fun ({ranch_server, _, _, _}, Acc) ->
              Acc;
          ({{ranch_listener_sup, {Ip, Port}}, Status, supervisor, _}, Acc) ->
              {ok, {Type, Opts}} = get_listener_config(Ip, Port),
              MountPoint = proplists:get_value(mountpoint, Opts, ""),
              MaxConnections = proplists:get_value(max_connections, Opts,
                                                  vmq_config:get_env(max_connections)),
              Status1 =
              case Status of
                  restarting -> restarting;
                  undefined -> stopped;
                  Pid when is_pid(Pid) ->
                      case lists:keyfind(ranch_acceptors_sup, 1, supervisor:which_children(Pid)) of
                          false ->
                              not_found;
                          {_, restarting, supervisor, _} ->
                              restarting;
                          {_, undefined, supervisor, _} ->
                              stopped;
                          {_, AcceptorPid, supervisor, _} when is_pid(AcceptorPid) ->
                              running
                      end
              end,
              StrIp = inet:ntoa(Ip),
              StrPort = integer_to_list(Port),
              [{Type, StrIp, StrPort, Status1, MountPoint, MaxConnections}|Acc]
      end, [], supervisor:which_children(ranch_sup)).

get_listener_config(Addr, Port) ->
    get_listener_config(Addr, Port, vmq_config:get_env(listeners)).
get_listener_config(Addr, Port, [{T, Listeners}|Rest]) ->
    case lists:keyfind({Addr, Port}, 1, Listeners) of
        false ->
            get_listener_config(Addr, Port, Rest);
        {_, Opts} ->
            {ok, {T, Opts}}
    end;
get_listener_config(_, _, []) -> {error, not_found}.


reconfigure_listeners(Config) ->
    TCPListenOptions = proplists:get_value(tcp_listen_options, Config,
                                          vmq_config:get_env(tcp_listen_options)),
    ListenerConfig = proplists:get_value(listeners, Config,
                                        vmq_config:get_env(listeners)),
    Listeners = supervisor:which_children(ranch_sup),
    reconfigure_listeners(TCPListenOptions, ListenerConfig, Listeners).
reconfigure_listeners(TCPListenOptions, [{T, Config}|Rest], Listeners) ->
    NewListeners = reconfigure_listeners_for_type(T, Config, TCPListenOptions, Listeners),
    reconfigure_listeners(TCPListenOptions, Rest, NewListeners);
reconfigure_listeners(_, [], ListenersToDelete) ->
    lists:foreach(fun({Ref, _, _, _}) ->
                          delete_listener(Ref)
                  end, ListenersToDelete).

addr(Addr) when is_list(Addr) ->
    {ok, Ip} = inet:parse_address(Addr),
    Ip;
addr(Addr) -> Addr.


reconfigure_listeners_for_type(Type, [{{Addr, Port}, Opts}|Rest], TCPOpts, Listeners) ->
    TransportOpts = TCPOpts ++ transport_opts_for_type(Type, Opts),
    case start_listener(Type, Addr, Port, {TransportOpts, Opts}) of
        ok ->
            ok;
        {error, Reason} ->
            lager:error("can't reconfigure ~p listener(~p, ~p) with Options ~p due to ~p",
                        [Type, Addr, Port, Opts, Reason])
    end,
    Key = {ranch_listener_sup, listener_name(addr(Addr), Port)},
    reconfigure_listeners_for_type(Type, Rest, TCPOpts, lists:keydelete(Key, 1, Listeners));
reconfigure_listeners_for_type(_, [], _, Listeners) -> Listeners.

listener_name(Ip, Port) ->
    {Ip, Port}.

transport_for_type(mqtt) -> ranch_tcp;
transport_for_type(mqtts) -> ranch_ssl;
transport_for_type(mqttws) -> ranch_tcp;
transport_for_type(mqttwss) -> ranch_ssl;
transport_for_type(http) -> ranch_tcp;
transport_for_type(https) -> ranch_ssl;
transport_for_type(vmq) -> ranch_tcp;
transport_for_type(vmqs) -> ranch_ssl.

protocol_for_type(mqtt) -> vmq_ranch;
protocol_for_type(mqtts) -> vmq_ranch;
protocol_for_type(mqttws) -> cowboy_protocol;
protocol_for_type(mqttwss) -> cowboy_protocol;
protocol_for_type(http) -> cowboy_protocol;
protocol_for_type(https) -> cowboy_protocol;
protocol_for_type(vmq) -> vmq_cluster_com;
protocol_for_type(vmqs) -> vmq_cluster_com.

transport_opts_for_type(Type, Opts) ->
    transport_opts(transport_for_type(Type), Opts).
transport_opts(ranch_tcp, _) -> [];
transport_opts(ranch_ssl, Opts) -> vmq_ssl:opts(Opts).

protocol_opts_for_type(Type, Opts) ->
    protocol_opts(protocol_for_type(Type), Type, Opts).
protocol_opts(vmq_ranch, _, Opts) -> default_session_opts(Opts);
protocol_opts(cowboy_protocol, Type, Opts)
  when (Type == mqttws) or (Type == mqttwss) ->
    Dispatch = cowboy_router:compile(
                 [{'_', [{"/mqtt", vmq_websocket, [default_session_opts(Opts)]}]}
                 ]),
    [{env, [{dispatch, Dispatch}]}];
protocol_opts(cowboy_protocol, _, Opts) ->
    Routes =
    case {lists:keyfind(config_mod, 1, Opts),
          lists:keyfind(config_fun, 1, Opts)} of
        {{_, ConfigMod}, {_, ConfigFun}} ->
            try
                apply(ConfigMod, ConfigFun, [])
            catch
                E:R ->
                    lager:error("can't setup HTTP modules due to ~p:~p", [E, R]),
                    []
            end;
        _ ->
            []
    end,
    CowboyRoutes = [{'_', Routes}],
    Dispatch = cowboy_router:compile(CowboyRoutes),
    [{env, [{dispatch, Dispatch}]}];
protocol_opts(vmq_cluster_com, _, _) -> [].

default_session_opts(Opts) ->
    MaybeSSLDefaults =
    case lists:keyfind(use_identity_as_username, 1, Opts) of
        false -> [];
        {_, V} -> [{use_identity_as_username, V}]
    end,
    %% currently only the mountpoint option is supported
    [{mountpoint, proplists:get_value(mountpoint, Opts, "")}|MaybeSSLDefaults].

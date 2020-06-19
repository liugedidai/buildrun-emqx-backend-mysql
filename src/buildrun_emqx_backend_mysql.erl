%%--------------------------------------------------------------------
%% Copyright (c) 2020 Buildrun Technologies Co., Ltd. All Rights Reserved.
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
%%--------------------------------------------------------------------

-module(buildrun_emqx_backend_mysql).

-include_lib("buildrun_emqx_backend_mysql.hrl").
-include_lib("emqx/include/emqx.hrl").

-define(CLIENT_CONNECTED_SQL,
    <<"insert into mqtt_client(clientid, state, "
                   "node, online_at, offline_at) values(?, "
                   "?, ?, now(), null) on duplicate key "
                   "update state = null, node = ?, online_at "
                   "= now(), offline_at = null">>).
-define(CLIENT_DISCONNECTED_SQL,
                 <<"update mqtt_client set state = ?, offline_at "
                   "= now() where clientid = ?">>).

-define(MESSAGE_PUBLISH_SQL,
                 <<"insert into mqtt_msg(msgid, sender, "
                   "topic, qos, retain, payload, arrived) "
                   "values (?, ?, ?, ?, ?, ?, ? );">>).         


-export([pool_name/1]).

-export([ register_metrics/0, 
          load/1
        , unload/0
        ]).

%% Client Lifecircle Hooks
-export([ on_client_connected/3
        , on_client_disconnected/4
        ]).


%% Message Pubsub Hooks
-export([ on_message_publish/2
        ]).


pool_name(Pool) ->
    list_to_atom(lists:concat([buildrun_emqx_backend_mysql, '_',
                               Pool])).

register_metrics() ->
    [emqx_metrics:new(MetricName)
     || MetricName
            <- ['buildrun.backend.mysql.client_connected',
                'buildrun.backend.mysql.client_disconnected',
                'buildrun.backend.mysql.message_publish']].

%% Called when the plugin application start
load(Env) ->
    emqx:hook('client.connected',    {?MODULE, on_client_connected, [Env]}),
    emqx:hook('client.disconnected', {?MODULE, on_client_disconnected, [Env]}),
    emqx:hook('message.publish',     {?MODULE, on_message_publish, [Env]}).

%%--------------------------------------------------------------------
%% Client Lifecircle Hooks
%%--------------------------------------------------------------------

on_client_connected(ClientInfo = #{clientid := ClientId, peerhost := Peerhost}, ConnInfo, _Env) ->
    buildrun_emqx_backend_mysql_cli:query(?CLIENT_CONNECTED_SQL, [binary_to_list(ClientId),null,tuple_to_list(Peerhost),null]),
    %%io:format("Client(~s) connected, ClientInfo:~n~p~n, ConnInfo:~n~p~n, Peerhost:~n~p~n", [ClientId, ClientInfo, ConnInfo, Peerhost]),
    ok.

on_client_disconnected(ClientInfo = #{clientid := ClientId}, ReasonCode, ConnInfo, _Env) ->
    buildrun_emqx_backend_mysql_cli:query(?CLIENT_DISCONNECTED_SQL, [null,binary_to_list(ClientId)]),
    %%io:format("Client(~s) disconnected due to ~p, ClientInfo:~n~p~n, ConnInfo:~n~p~n",[ClientId, ReasonCode, ClientInfo, ConnInfo]),
    ok.


%%--------------------------------------------------------------------
%% Message PubSub Hooks
%%--------------------------------------------------------------------

%% Transform message and return
on_message_publish(Message = #message{topic = <<"$SYS/", _/binary>>}, _Env) ->
    {ok, Message};

on_message_publish(#message{flags = #{}} = Message, _Env) ->
    #message{id = Id, from = From, topic = Topic, qos = Qos, flags = Retain, payload = Payload } = Message,
    buildrun_emqx_backend_mysql_cli:query(?MESSAGE_PUBLISH_SQL, [emqx_guid:to_hexstr(Id),binary_to_list(From),Topic,integer_to_list(Qos),null,binary_to_list(Payload),null]),
    %%io:format("on_message_publish ~s~n", [emqx_message:format(Message)]),
    {ok, Message};

on_message_publish(Message, _Env) ->
  {ok, Message}.


%% Called when the plugin application stop
unload() ->
    emqx:unhook('client.connected',    {?MODULE, on_client_connected}),
    emqx:unhook('client.disconnected', {?MODULE, on_client_disconnected}),
    emqx:unhook('message.publish',     {?MODULE, on_message_publish}).



timestamp() ->
  {A,B,_C} = os:timestamp(),
  A*1000000+B.


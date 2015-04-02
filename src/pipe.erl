%% ------------------------------------------------
%% @author Marco Franceschetti <marco.franceschetti@gmail.com>
%% @copyright Marco Franceschetti, 2014
%% @end
%% ------------------------------------------------

-module(pipe).

-include("include/strings.hrl").

-import(misc, [is_in_list/2, add_to_list/2, delete_from_list/2, secs/1]).
-export([start/3, start_parent/2, parent_loop/1, start_local/2, local_loop/1]).

%% ------------------------------------------------
%% @doc Esegue le operazioni preliminari all'avvio di un processo Pipe:
%% apre una connessione a un broker genitore e una connessione al broker locale per pubblicare su di essi,
%% avvia un processo client MQTT in ascolto del broker genitore e uno in ascolto del broker locale,
%% quindi entra nel pipe loop.
%% @end
%% ------------------------------------------------
start(Controller_PID, Parent, Local) ->
	{ok, P} = erlmqtt:open_clean(Parent, []),
	{ok, L} = erlmqtt:open_clean(Local, []),
	Parent_listener = spawn(pipe, start_parent, [self(), Parent]),
	link(Parent_listener),
	Local_listener = spawn(pipe, start_local, [self(), Local]),
	link(Local_listener),
	pipe_loop(Controller_PID, P, L, [], secs(erlang:now())).

%% ------------------------------------------------
%% @doc Riceve i messaggi a loro volta ricevuti dal broker genitore o dal broker locale,
%% pubblicandoli quindi presso l'altro broker. Viene mantenuta una lista dei messaggi ricevuti per evitare che
%% uno stesso messaggio venga ritrasmesso all'infinito.
%% I messaggi ricevuti sui topic di controllo relativi agli utenti e ai broker non vengono inoltrati.
%% @end
%% ------------------------------------------------
pipe_loop(Controller_PID, P, L, MsgList, Last_parent_activity) ->
	Now = secs(erlang:now()),
	if
		(Now - Last_parent_activity) > 3 ->
			Controller_PID ! {?A_FROMPIPE, ?A_ORPHAN},
			exit(self());
		true ->
			true
	end,
	receive
		{_, <<?T_CONNECTEDUSERS>>, _} ->
			NewMsgList = MsgList;
		{_, <<?T_DISCONNECTEDUSERS>>, _} ->
			NewMsgList = MsgList;
		{?A_FROMPARENT, <<?T_LIVEBROKER>>, _} ->
			NewMsgList = MsgList,
			pipe_loop(Controller_PID, P, L, NewMsgList, secs(erlang:now()));
		{?A_FROMLOCAL, <<?T_LIVEBROKER>>, _} ->
			NewMsgList = MsgList;
		{_, <<?T_CHANGEBROKER>>, _} ->
			NewMsgList = MsgList;
		{_, <<?T_NEWBROKER>>, _} ->
			NewMsgList = MsgList;
		{?A_FROMPARENT, Topic, Msg} ->
			NewMsgList = publish_if_new(L, Topic, Msg, MsgList);
		{?A_FROMLOCAL, Topic, Msg} ->
			NewMsgList = publish_if_new(P, Topic, Msg, MsgList)
	end,
	pipe_loop(Controller_PID, P, L, NewMsgList, Last_parent_activity).

%% ------------------------------------------------
%% @doc Funzione di supporto che determina se un messaggio ricevuto da un broker non sia lo stesso messaggio
%% precedentemente inoltrato a quello stesso broker in quanto proveniente dall'altro.
%% Se un messaggio non era mai stato visto in precedenza questo viene inoltrato, altrimenti si tratta di un messaggio
%% che era stato già inoltrato e viene quindi ignorato, oltre che rimosso dalla lista dei messaggi recenti.
%% @end
%% ------------------------------------------------
publish_if_new(Broker, Topic, Msg, MsgList) ->
	case is_in_list(Msg, MsgList) of
		true ->
			delete_from_list(Msg, MsgList);
		false ->
			erlmqtt:publish(Broker, Topic, Msg),
			add_to_list(Msg, MsgList)
	end.

%% ------------------------------------------------
%% @doc Esegue le operazioni preliminari all'avvio di un processo client in ascolto del broker genitore:
%% apre una connessione con suddetto broker, effettua la subscribe a tutti i topic,
%% quindi avvia il parent loop.
%% @end
%% ------------------------------------------------
start_parent(Pipe_PID, Parent) ->
	{ok, C} = erlmqtt:open_clean(Parent, []),
	{ok, _} = erlmqtt:subscribe(C, [{"#", at_most_once}]),
	parent_loop(Pipe_PID).

%% ------------------------------------------------
%% @doc Cicla ricevendo i messaggi che vengono pubblicati sul broker genitore, per poi passarli via messaggio al processo Pipe.
%% @end
%% ------------------------------------------------
parent_loop(Pipe_PID) ->
	{Topic, Msg} = erlmqtt:recv_message(),
	Pipe_PID ! {?A_FROMPARENT, Topic, Msg},
	parent_loop(Pipe_PID).

%% ------------------------------------------------
%% @doc Esegue le operazioni preliminari all'avvio di un processo client in ascolto del broker locale:
%% apre una connessione con suddetto broker, effettua la subscribe a tutti i topic,
%% quindi avvia il local loop.
%% @end
%% ------------------------------------------------
start_local(Pipe_PID, Local) ->
	{ok, C} = erlmqtt:open_clean(Local, []),
	{ok, _} = erlmqtt:subscribe(C, [{"#", at_most_once}]),
	local_loop(Pipe_PID).

%% ------------------------------------------------
%% @doc Cicla ricevendo i messaggi che vengono pubblicati sul broker locale, per poi passarli via messaggio al processo Pipe.
%% @end
%% ------------------------------------------------
local_loop(Pipe_PID) ->
	{Topic, Msg} = erlmqtt:recv_message(),
	Pipe_PID ! {?A_FROMLOCAL, Topic, Msg},
	local_loop(Pipe_PID).
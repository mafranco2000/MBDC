%% ------------------------------------------------
%% @author Marco Franceschetti <marco.franceschetti@gmail.com>
%% @copyright Marco Franceschetti, 2014
%% @end
%% ------------------------------------------------

-module(client).

-include("include/strings.hrl").

-export([start/2, keepalive/2]).

%% ------------------------------------------------
%% @doc Esegue le operazioni preliminari all'avvio di un processo Client:
%% inizializza la connessione al broker presente all'indirizzo specificato, avvia un processo di keepalive,
%% quindi avvia il client loop per la gestione dei messaggi.
%% @end
%% ------------------------------------------------
start(Controller_PID, Broker_address) ->
	{ok, [{Own_IP, _, _}|_]} = inet:getif(),
	Connection = initialize_connection(Broker_address),
	Keepalive_PID = spawn(client, keepalive, [self(), Own_IP]),
	link(Keepalive_PID),
	loop_listener(Controller_PID, Connection).

%% ------------------------------------------------
%% @doc Cicla in attesa di ricevere messaggi, alternativamente dal broker e dal processo Controller.
%% Alla ricezione di un messaggio della forma (Topic, Message) dal broker, questo viene passato al Controller.
%% Alla ricezione di un messaggio di tipo {Publish, Subscribe, Unsubscribe, Disconnect} dal Controller, viene effettuata la relativa azione.
%% @end
%% ------------------------------------------------
loop_listener(Controller_PID, C) ->
	Received = erlmqtt:recv_message(500),
	case Received of
		{Topic, Msg} ->
			Controller_PID ! {?A_FROMLISTENER, Topic, Msg};
		_ ->
			true
	end,
	receive
		{?A_SUBSCRIBE, New_topic} ->
			erlmqtt:subscribe(C, [{New_topic, at_most_once}]);
		{?A_UNSUBSCRIBE, Former_topic} ->
			erlmqtt:unsubscribe(C, [Former_topic]);
		{?A_PUBLISH, In_topic, The_msg} ->
			erlmqtt:publish(C, In_topic, The_msg);
		{?A_DISCONNECT} ->
			erlmqtt:close(C)
	after
		500 ->
			loop_listener(Controller_PID, C)
	end,
	loop_listener(Controller_PID, C).

%% ------------------------------------------------
%% @doc Invia, a intervalli regolari, un messaggio al Client loop affinché questo pubblichi un messaggio MQTT sul broker,
%% al fine di segnalare il proprio status di "Alive".
%% @end
%% ------------------------------------------------
keepalive(Client_PID, Own_IP) ->
	Client_PID ! {publish, ?T_CONNECTEDUSERS, inet_parse:ntoa(Own_IP)},
	timer:sleep(4000),
	keepalive(Client_PID, Own_IP).

%% ------------------------------------------------
%% @doc Apre una connessione con il broker all'indirizzo specificato,
%% esegue le sottoscrizioni ai topic di controllo utilizzati per la gestione della chat,
%% quindi restituisce al chiamante il riferimento alla connessione affinchè questa venga utilizzata per le operazioni nel Client loop.
%% @end
%% ------------------------------------------------
initialize_connection(Broker_address) ->
	{ok, C} = erlmqtt:open_clean(Broker_address, []),
	erlmqtt:subscribe(C, [{?T_DEFAULT, at_most_once}]),
	erlmqtt:subscribe(C, [{?T_CONNECTEDUSERS, at_most_once}]),
	erlmqtt:subscribe(C, [{?T_DISCONNECTEDUSERS, at_most_once}]),
	erlmqtt:subscribe(C, [{?T_NEWTOPIC, at_most_once}]),
	erlmqtt:subscribe(C, [{?T_EXISTINGTOPICS, at_most_once}]),
	erlmqtt:subscribe(C, [{?T_LIVEBROKER, at_most_once}]),
	erlmqtt:subscribe(C, [{?T_CHANGEBROKER, at_most_once}]),
	erlmqtt:subscribe(C, [{?T_NEWBROKER, at_most_once}]),
	C.
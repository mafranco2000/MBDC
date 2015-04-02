%% ------------------------------------------------
%% @author Marco Franceschetti <marco.franceschetti@gmail.com>
%% @copyright Marco Franceschetti, 2014
%% @end
%% ------------------------------------------------

-module(controller).

-include("include/strings.hrl").

-import(misc, [add_if_new/2, remove_if_exists/2, is_in_list/2, add_to_list/2, delete_from_list/2, reformat_string/1, secs/1]).
-export([start/0, timer/1, subtimer/2]).

%% ------------------------------------------------
%% @doc Esegue le operazioni preliminari all'avvio dell'applicazione:
%% avvia un processo Frontend per l'interfaccia grafica,
%% avvia un processo Network per la rilevazione della presenza di broker nella rete locale,
%% quindi attende una risposta dal processo Network.
%% @end
%% ------------------------------------------------
start() ->
	Frontend_PID = spawn(frontend, start, [self()]),
	link(Frontend_PID),
	Network_PID = spawn(network, start, [self()]),
	assess_network_status(Frontend_PID, Network_PID).

%% ------------------------------------------------
%% @doc Riceve un messaggio dal processo Network per determinare se nella rete locale sono presenti dei broker
%% o se è necessario avviare un proprio processo broker. Nel secondo caso, viene avviato anche un processo Clients handler
%% per tenere traccia delle connessioni dei client al proprio broker, e un processo Timer per la segnalazione di eventi periodici.
%% In ogni caso viene avviato poi un processo Client a cui viene passato l'indirizzo del broker, sia esso esterno o locale.
%% Infine, viene avviato il controller loop per la gestione delle attività "di routine" del sistema.
%% @end
%% ------------------------------------------------
assess_network_status(Frontend_PID, Network_PID) ->
	receive
		{?A_FROMNETWORK, ?A_FOUNDBROKER, Broker_IP} ->
			Client_PID = spawn(client, start, [self(), Broker_IP]),
			Frontend_PID ! {?A_FROMCONTROLLER, ?A_ENABLEINPUT},
			Frontend_PID ! {?A_FROMCONTROLLER, ?A_CHANGESTATUS, ?S_CONNECTED_EXT},
			controller_loop(Frontend_PID, Network_PID, Client_PID, undefined, undefined, undefined, Broker_IP, false, [?T_DEFAULT], [?T_DEFAULT], [], secs(erlang:now()));
		{?A_FROMNETWORK, ?A_NOBROKER} ->
			start_local_broker(),
			timer:sleep(1000),	% diamo al broker il tempo di avviarsi per mettersi in ascolto di nuove richieste
			Client_PID = spawn(client, start, [self(), "localhost"]),
			Clients_handler_PID = spawn(clients_handler, start, [self()]),
			Timer_PID = spawn(controller, timer, [self()]),
			Frontend_PID ! {?A_FROMCONTROLLER, ?A_ENABLEINPUT},
			Frontend_PID ! {?A_FROMCONTROLLER, ?A_CHANGESTATUS, ?S_CONNECTED_SELF},
			controller_loop(Frontend_PID, Network_PID, Client_PID, Clients_handler_PID, Timer_PID, undefined, "localhost", true, [?T_DEFAULT], [?T_DEFAULT], [], secs(erlang:now()))
	end.

%% ------------------------------------------------
%% @doc Cicla gestendo i messaggi ricevuti dai vari processi componenti il sistema.
%% Ad ogni iterazione viene verificata l'attività del broker a cui il client è collegato: in caso di apparente inattività,
%% viene terminato il processo Client e viene riavviato il processo Network
%% per determinare la presenza di broker attivi nella rete locale.
%% @end
%% ------------------------------------------------
controller_loop(Frontend_PID, Network_PID, Client_PID, Clients_handler_PID, Timer_PID, Pipe_PID, Broker_IP, Am_i_broker, Alltopics, Mytopics, Clients, Last_broker_activity) ->
	{ok, [{Own_IP, _, _}|_]} = inet:getif(),
	Now = secs(erlang:now()),
	if
		(Now - Last_broker_activity) > 2 ->
			Frontend_PID ! {?A_FROMCONTROLLER, ?A_DISABLEINPUT},
			Frontend_PID ! {?A_FROMCONTROLLER, ?A_CHANGESTATUS, ?S_DISCONNECTED},
			exit(Network_PID, kill),
			exit(Client_PID, kill),
			New_network_PID = spawn(network, start, [self()]),
			assess_network_status(Frontend_PID, New_network_PID);
		true ->
			true
	end,
	receive
		%% Ricezione sul topic relativo ai client connessi dell'indirizzo IP di un client:
		%% se è stato avviato un processo broker, si comunica al Clients handler di tenere traccia del client,
		%% altrimenti il messaggio viene ignorato.
		{?A_FROMLISTENER, <<?T_CONNECTEDUSERS>>, Client_IP} ->
			case Am_i_broker of
				true ->
					Clients_handler_PID ! {?A_FROMCONTROLLER, ?A_TRACECLIENT, reformat_string(Client_IP), secs(erlang:now())};
				_ ->
					true
			end;
		%% Ricezione sul topic relativo ai client in disconnessione dell'indirizzo IP di un client:
		%% se è stato avviato un processo broker, si comunica al Clients handler di registrare l'uscita del client,
		%% altrimenti il messaggio viene ignorato.
		{?A_FROMLISTENER, <<?T_DISCONNECTEDUSERS>>, Client_IP} ->
			case Am_i_broker of
				true ->
					Clients_handler_PID ! {?A_FROMCONTROLLER, ?A_DELETECLIENT, reformat_string(Client_IP)};
				_ ->
					true
			end;
		%% Ricezione sul topic relativo alla salute dei broker di un messaggio dummy:
		%% si registra l'istante di ricezione come ultimo istante certo di attività del broker.
		{?A_FROMLISTENER, <<?T_LIVEBROKER>>, <<".">>} ->
			controller_loop(Frontend_PID, Network_PID, Client_PID, Clients_handler_PID, Timer_PID, Pipe_PID, Broker_IP, Am_i_broker, Alltopics, Mytopics, Clients, secs(erlang:now()));
		%% Ricezione sul topic relativo all'avvio di un nuovo broker di un indirizzo IP:
		%% se è lo stesso indirizzo della macchina locale e non è già attivo un processo broker,
		%% si procede all'avvio di quest'ultimo. In questo caso è necessario riavviare il processo Client,
		%% avviare un processo Pipe che permetta la propagazione dei messaggi da e verso il broker precedente,
		%% un processo Clients handler e un Timer. Inoltre viene comunicato al processo Network che è ora attivo un broker.
		{?A_FROMLISTENER, <<?T_NEWBROKER>>, String} ->
			case ((inet_parse:ntoa(Own_IP) == reformat_string(String)) and (not Am_i_broker)) of
				true->
					Frontend_PID ! {?A_FROMCONTROLLER, ?A_DISABLEINPUT},
					Client_PID ! {?A_PUBLISH, ?T_DISCONNECTEDUSERS, inet_parse:ntoa(Own_IP)},
					exit(Client_PID, kill),
					start_local_broker(),
					timer:sleep(500),
					New_pipe_PID = spawn(pipe, start, [self(), Broker_IP, "localhost"]),
					New_clients_handler_PID = spawn(clients_handler, start, [self()]),
					New_timer_PID = spawn(controller, timer, [self()]),
					New_client_PID = spawn(client, start, [self(), "localhost"]),
					remake_subscriptions(New_client_PID, Mytopics),
					Network_PID ! {?A_BEABROKER},
					Frontend_PID ! {?A_FROMCONTROLLER, ?A_ENABLEINPUT},
					Frontend_PID ! {?A_FROMCONTROLLER, ?A_CHANGESTATUS, ?S_CONNECTED_SELF},
					controller_loop(Frontend_PID, Network_PID, New_client_PID, New_clients_handler_PID, New_timer_PID, New_pipe_PID, "localhost", true, Alltopics, Mytopics, [], secs(erlang:now()));
				_ ->
					true
			end;
		%% Ricezione sul topic relativo al cambio di broker di un indirizzo IP:
		%% se è quello della macchina corrente, viene parsato dal messaggio l'indirizzo IP del broker a cui collegarsi,
		%% il client comunica al vecchio broker la propria disconnessione e viene riavviato per collegarsi a quello nuovo.
		{?A_FROMLISTENER, <<?T_CHANGEBROKER>>, String} ->
			case lists:prefix(inet_parse:ntoa(Own_IP)++":", reformat_string(String)) of
				true->
					{ok, New_broker_address} = inet_parse:address(lists:sublist(reformat_string(String), length(inet_parse:ntoa(Own_IP))+2, length(reformat_string(String)))),
					Frontend_PID ! {?A_FROMCONTROLLER, ?A_DISABLEINPUT},
					Client_PID ! {?A_PUBLISH, ?T_DISCONNECTEDUSERS, inet_parse:ntoa(Own_IP)},
					exit(Client_PID, kill),
					timer:sleep(2000),
					New_client_PID = spawn(client, start, [self(), New_broker_address]),
					remake_subscriptions(New_client_PID, Mytopics),
					Frontend_PID ! {?A_FROMCONTROLLER, ?A_ENABLEINPUT},
					controller_loop(Frontend_PID, Network_PID, New_client_PID, Clients_handler_PID, Timer_PID, Pipe_PID, Broker_IP, Am_i_broker, Alltopics, Mytopics, Clients, secs(erlang:now()));
				_ -> true
			end;
		%% Ricezione della comunicazione da parte del processo Pipe dell'inattività del broker parent:
		%% il sottoalbero con radice nel nodo corrente è disconnesso dal sistema, quindi è necessario effettuare una riconnessione.
		{?A_FROMPIPE, ?A_ORPHAN} ->
			Frontend_PID ! {?A_FROMCONTROLLER, ?A_DISABLEINPUT},
			Frontend_PID ! {?A_FROMCONTROLLER, ?A_CHANGESTATUS, ?S_DISCONNECTED},
			stop_local_broker,
			exit(Client_PID, kill),
			exit(Network_PID, kill),
			exit(Clients_handler_PID, kill),
			exit(Timer_PID, kill),
			Respawned_network_PID = spawn(network, start, [self()]),
			assess_network_status(Frontend_PID, Respawned_network_PID);
		%% Ricezione sul topic relativo ai nuovi topic disponibili del nome di un nuovo topic:
		%% quest'ultimo viene comunicato all'interfaccia grafica per la notifica all'utente.
		{?A_FROMLISTENER, <<?T_NEWTOPIC>>, Topic} ->
			Frontend_PID ! {?A_FROMCONTROLLER, ?A_NEWMESSAGE, ?S_NEWTOPIC, reformat_string(Topic)},
			controller_loop(Frontend_PID, Network_PID, Client_PID, Clients_handler_PID, Timer_PID, Pipe_PID, Broker_IP, Am_i_broker, add_if_new(reformat_string(Topic), Alltopics), Mytopics, Clients, Last_broker_activity);
		%% Ricezione sul topic relativo ai topic correntemente disponibili dei nomi degli stessi:
		%% se vengono comunicati topic di cui non si aveva traccia, questi vengono aggiunti alla lista dei topic disponibili.
		{?A_FROMLISTENER, <<?T_EXISTINGTOPICS>>, Existing_topic} ->
			controller_loop(Frontend_PID, Network_PID, Client_PID, Clients_handler_PID, Timer_PID, Pipe_PID, Broker_IP, Am_i_broker, add_if_new(reformat_string(Existing_topic), Alltopics), Mytopics, Clients, Last_broker_activity);
		%% Ricezione su un generico topic di un generico messaggio:
		%% questi vengono passati al Frontend per essere visualizzati.
		{?A_FROMLISTENER, Topic, Msg} ->
			Frontend_PID ! {?A_FROMCONTROLLER, ?A_NEWMESSAGE, reformat_string(Topic), reformat_string(Msg)};
		%% Ricezione della richiesta da parte del Frontend di fornire la lista dei topic cui è stata fatta la sottoscrizione.
		{?A_FROMFRONTEND, ?A_MYTOPICS} ->
			Frontend_PID ! {?A_FROMCONTROLLER, ?A_MYTOPICS, Mytopics};
		%% Ricezione della richiesta da parte del Frontend di fornire la lista dei topic correntemente disponibili.
		{?A_FROMFRONTEND, ?A_ALLTOPICS} ->
			Frontend_PID ! {?A_FROMCONTROLLER, ?A_ALLTOPICS, Alltopics};
		%% Ricezione della richiesta da parte del Frontend di pubblicare un messaggio di chat.
		{?A_FROMFRONTEND, ?A_PUBLISH, Topic, Msg} ->
			Client_PID ! {?A_PUBLISH, Topic, Msg};
		%% Ricezione della richiesta da parte del Frontend di effettuare la sottoscrizione a un topic.
		{?A_FROMFRONTEND, ?A_SUBSCRIBE, Topic} ->
			Client_PID ! {?A_SUBSCRIBE, Topic},
			controller_loop(Frontend_PID, Network_PID, Client_PID, Clients_handler_PID, Timer_PID, Pipe_PID, Broker_IP, Am_i_broker, Alltopics, add_if_new(Topic, Mytopics), Clients, Last_broker_activity);
		%% Ricezione della richiesta da parte del Frontend di annullare la sottoscrizione a un topic.
		{?A_FROMFRONTEND, ?A_UNSUBSCRIBE, Topic} ->
			Client_PID ! {?A_UNSUBSCRIBE, Topic},
			controller_loop(Frontend_PID, Network_PID, Client_PID, Clients_handler_PID, Timer_PID, Pipe_PID, Broker_IP, Am_i_broker, Alltopics, remove_if_exists(Topic, Mytopics), Clients, Last_broker_activity);
		%% Ricezione della richiesta da parte del Frontend di creare un nuovo topic.
		%% La creazione di un topic implica la contestuale sottoscrizione allo stesso.
		{?A_FROMFRONTEND, ?A_NEWTOPIC, Topic} ->
			Client_PID ! {?A_PUBLISH, ?T_NEWTOPIC, Topic},
			Client_PID ! {?A_SUBSCRIBE, Topic},
			controller_loop(Frontend_PID, Network_PID, Client_PID, Clients_handler_PID, Timer_PID, Pipe_PID, Broker_IP, Am_i_broker, add_if_new(Topic, Alltopics), add_if_new(Topic, Mytopics), Clients, Last_broker_activity);
		%% Ricezione della lista dei client connessi da parte del Clients handler.
		%% Se viene rilevato un numero eccessivo di client connessi, viene scelto uno tra essi che avvii un processo broker;
		%% viene inoltre scelto un numero pari alla metà dei client connessi rimanenti da cedere al nuovo processo broker.
		%% NOTA BENE: al fine di permettere una simulazione in VMWare Player, il numero massimo di client connessi è stato impostato pari a 2,
		%% mentre al nuovo broker vengono trasferiti tutti i client connessi ad eccezione di quello locale
		%% (il secondo argomento di choose_half_children normalmente sarebbe length(Remaining_clients) div 2).
		{?A_FROMCLIENTSHANDLER, ?A_ALIVE, Updated_clients_list} ->
			Active_clients = length(Updated_clients_list),
			if
				(Active_clients > 2) ->
					Selected_broker = hd(delete_from_list(inet_parse:ntoa(Own_IP), Updated_clients_list)),
					Client_PID ! {?A_PUBLISH, ?T_NEWBROKER, Selected_broker},
					Clients_handler_PID ! {?A_FROMCONTROLLER, ?A_DELETECLIENT, Selected_broker},
					Remaining_clients = delete_from_list(inet_parse:ntoa(Own_IP), delete_from_list(Selected_broker, Updated_clients_list)),
					Selected_children = choose_half_children(Remaining_clients, [], length(Remaining_clients)),
					inform_of_change(Client_PID, Selected_children, ":" ++ Selected_broker),
					controller_loop(Frontend_PID, Network_PID, Client_PID, Clients_handler_PID, Timer_PID, Pipe_PID, Broker_IP, Am_i_broker, Alltopics, Mytopics, delete_from_list(Selected_broker, Updated_clients_list), Last_broker_activity);
				true ->
					true
			end,
			controller_loop(Frontend_PID, Network_PID, Client_PID, Clients_handler_PID, Timer_PID, Pipe_PID, Broker_IP, Am_i_broker, Alltopics, Mytopics, Updated_clients_list, Last_broker_activity);
		%% Ricezione del messaggio da parte del Timer che invita a comunicare ai client connessi la lista dei topic disponibili.
		{?A_FROMTIMER, ?A_TIMETOUPDATE} ->
			send_topics(Client_PID, Alltopics);
		%% Ricezione del messaggio da parte del Timer che invita a comunicare ai client la salute del broker.
		{?A_FROMTIMER, ?A_KEEPALIVE} ->
			Client_PID ! {?A_PUBLISH, ?T_LIVEBROKER, "."};
		%% Ricezione del messaggio da parte del Frontend che comunica la volontà dell'utente di uscire.
		{?A_FROMFRONTEND, ?A_DISCONNECT, Client} ->
			Client_PID ! {?A_PUBLISH, ?T_DISCONNECTEDUSERS, inet_parse:ntoa(Client)},
			timer:sleep(500),
			Client_PID ! {?A_DISCONNECT},
			terminate([Network_PID, Client_PID, Clients_handler_PID, Timer_PID, Pipe_PID])
	end,
	controller_loop(Frontend_PID, Network_PID, Client_PID, Clients_handler_PID, Timer_PID, Pipe_PID, Broker_IP, Am_i_broker, Alltopics, Mytopics, Clients, Last_broker_activity).

%% ------------------------------------------------
%% @doc Avvia l'esecuzione del broker Mosquitto in accordo con il sistema operativo in uso.
%% @end
%% ------------------------------------------------
start_local_broker() ->
	case os:type() of
		{win32, _} ->
			open_port({spawn, "../../mosquitto-win/src/mosquitto.exe"}, []);
		{unix, _} ->
			open_port({spawn, "../mosquitto-1.3.1/src/mosquitto -d"}, [])
	end.

%% ------------------------------------------------
%% @doc Ferma l'esecuzione del broker Mosquitto in accordo con il sistema operativo in uso.
%% @end
%% ------------------------------------------------
stop_local_broker() ->
	case os:type() of
		{win32, _} ->
			os:cmd(io_lib:format("taskkill /f /im mosquitto.exe", []));
		{unix, _} ->
			os:cmd(io_lib:format("pkill mosquitto", []))
	end.

%% ------------------------------------------------
%% @doc Ogni 5 secondi comunica al processo Controller di pubblicare la lista dei topic sul relativo topic di controllo,
%% in modo che i nuovi client possano avere la lista aggiornata.
%% @end
%% ------------------------------------------------
timer(Controller_PID) ->
	subtimer(Controller_PID, 5),
	Controller_PID ! {?A_FROMTIMER, ?A_TIMETOUPDATE},
	timer(Controller_PID).

%% ------------------------------------------------
%% @doc Ogni secondo comunica al processo Controller di pubblicare sul relativo topic di controllo un messaggio dummy per far sì
%% che i client connessi siano certi che il broker è ancora vivo. Questa funzione è chiamata dalla funzione timer, a sua volta chiamata
%% solamente se esiste un processo broker che è stato avviato.
%% @end
%% ------------------------------------------------
subtimer(_, 0) ->
	true;
subtimer(Controller_PID, N) ->
	timer:sleep(1000),
	Controller_PID ! {?A_FROMTIMER, ?A_KEEPALIVE},
	subtimer(Controller_PID, N-1).

%% ------------------------------------------------
%% @doc Funzione di supporto che, data una lista di topic, comunica al processo Client
%% di effettuare la sottoscrizione ad ognuno di essi.
%% @end
%% ------------------------------------------------
remake_subscriptions(Client_PID, [Topic|Tail]) ->
	Client_PID ! {?A_SUBSCRIBE, Topic},
	remake_subscriptions(Client_PID, Tail);
remake_subscriptions(_, []) ->
	true.

%% ------------------------------------------------
%% @doc Funzione di supporto che, data una lista di topic, comunica al processo Client
%% di pubblicarne il nome di ognuno di essi nel relativo topic di controllo.
%% @end
%% ------------------------------------------------
send_topics(Client_PID, [Topic|Tail]) ->
	Client_PID ! {?A_PUBLISH, ?T_EXISTINGTOPICS, Topic},
	send_topics(Client_PID, Tail);
send_topics(_, []) ->
	true.

%% ------------------------------------------------
%% @doc Funzione di supporto che, data una lista di client connessi,
%% ne restituisce i primi N.
%% @end
%% ------------------------------------------------
choose_half_children(_, Chosen, 0) ->
	Chosen;
choose_half_children([Client|Tail], Chosen, N) ->
	choose_half_children(Tail, [Client|Chosen], N-1).

%% ------------------------------------------------
%% @doc Funzione di supporto che, data una lista di client connessi e un nuovo broker,
%% comunica ad ognuno dei client di connettersi al nuovo broker per mezzo di un messaggio su un topic di controllo.
%% @end
%% ------------------------------------------------
inform_of_change(_, [], _) ->
	true;
inform_of_change(Client_PID, [Child|Tail], Broker) ->
	Client_PID ! {?A_PUBLISH, ?T_CHANGEBROKER, Child ++ Broker},
	inform_of_change(Client_PID, Tail, Broker).

%% ------------------------------------------------
%% @doc Termina il processo corrente e tutti quelli correlati.
%% @end
%% ------------------------------------------------
terminate([Process|Tail]) ->
	if
		Process /= undefined ->
			exit(Process, kill);
		true ->
			true
	end,
	terminate(Tail);
terminate([]) ->
	stop_local_broker(),
	exit(self()).
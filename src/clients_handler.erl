%% ------------------------------------------------
%% @author Marco Franceschetti <marco.franceschetti@gmail.com>
%% @copyright Marco Franceschetti, 2014
%% @end
%% ------------------------------------------------

-module(clients_handler).

-include("include/strings.hrl").

-import(misc, [secs/1]).
-export([start/1, timer/1, liveness_checker/4]).

%% ------------------------------------------------
%% @doc Esegue le operazioni preliminari all'avvio di un processo Clients_handler:
%% avvia un processo con la funzione di timer per ricevere un messaggio periodico,
%% quindi avvia il client handler loop per la gestione dei messaggi.
%% @end
%% ------------------------------------------------
start(Controller_PID) ->
	Timer_PID = spawn(clients_handler, timer, [self()]),
	link(Timer_PID),
	clients_handler_loop(Controller_PID, []).

%% ------------------------------------------------
%% @doc Cicla in attesa di ricevere messaggi dal processo Controller o dai processi figli.
%% Il Controller può richiedere di aggiungere un nuovo client alla lista dei client connessi,
%% o di rimuovere un client disconnesso dalla chat da suddetta lista.
%% Il processo figlio Liveness checker può inviare un messaggio con la lista dei client che risultano inattivi,
%% e che quindi devono essere rimossi dalla lista dei client connessi.
%% Il processo figlio Timer avvisa quando è il momento di avviare un processo figlio Liveness checker.
%% @end
%% ------------------------------------------------
clients_handler_loop(Controller_PID, Clients) ->
	receive
		{?A_FROMCONTROLLER, ?A_TRACECLIENT, Client, Timestamp} ->
			clients_handler_loop(Controller_PID, [{Client, Timestamp}|remove_client(Client, Clients)]);
		{?A_FROMCONTROLLER, ?A_DELETECLIENT, Client} ->
			clients_handler_loop(Controller_PID, remove_client(Client, Clients));
		{?A_FROMLIVENESSCHECKER, Dead} ->
			Alive_clients = remove_deads(Dead, Clients),
			Controller_PID ! {?A_FROMCLIENTSHANDLER, ?A_ALIVE, remove_timestamps(Alive_clients, [])},
			clients_handler_loop(Controller_PID, Alive_clients);
		{?A_FROMTIMER, ?A_TIMETOCHECK} ->
			spawn(clients_handler, liveness_checker, [self(), secs(erlang:now()), Clients, []])
		after 5000 ->
			clients_handler_loop(Controller_PID, Clients)
	end,
	clients_handler_loop(Controller_PID, Clients).

%% ------------------------------------------------
%% @doc A intervalli regolari avvisa il Clients handler loop di verificare l'eventuale inattività dei client connessi.
%% @end
%% ------------------------------------------------
timer(Clients_handler_PID) ->
	timer:sleep(5000),
	Clients_handler_PID ! {?A_FROMTIMER, ?A_TIMETOCHECK},
	timer(Clients_handler_PID).

%% ------------------------------------------------
%% @doc Verifica, per ogni client contenuto nella lista dei client connessi,
%% che l'ultimo istante di attività sia non più lontano nel tempo di 10 secondi dal momento in cui
%% il processo Liveness checker è stato avviato. In caso contrario, il client è ritenuto inattivo (dead)
%% e viene aggiunto alla lista dei client da rimuovere. Terminata la verifica, la lista dei Dead client viene inviata
%% al processo Clients handler loop e il processo Liveness checker termina.
%% @end
%% ------------------------------------------------
liveness_checker(Clients_handler_PID, Timestamp, [{Client, Last_active}|Tail], Dead) ->
	if
		(Timestamp - Last_active) < 10 ->
			liveness_checker(Clients_handler_PID, Timestamp, Tail, Dead);
		true ->
			liveness_checker(Clients_handler_PID, Timestamp, Tail, [Client|Dead])
	end;
liveness_checker(Clients_handler_PID, _, [], Dead) ->
	Clients_handler_PID ! {?A_FROMLIVENESSCHECKER, Dead}.


%% ------------------------------------------------
%% @doc Rimuove dalla lista dei client quelli segnalati come non più attivi dal Liveness checker.
%% @end
%% ------------------------------------------------
remove_deads([Dead|Tail], Clients) ->
	remove_deads(Tail, remove_client(Dead, Clients));
remove_deads([], Clients) ->
	Clients.

%% ------------------------------------------------
%% @doc Funzione ausiliaria che rimuove un elemento della forma (Client, Timestamp) dalla lista dei client connessi.
%% @end
%% ------------------------------------------------
remove_client(Client, [{Client, _}|Tail]) ->
	Tail;
remove_client(_, []) ->
	[];
remove_client(Client, [{C, T}|Tail]) ->
	[{C, T}|remove_client(Client, Tail)].

%% ------------------------------------------------
%% @doc Funzione ausiliaria che rimuove i timestamp dagli elementi della forma (Client, Timestamp) di una lista.
%% @end
%% ------------------------------------------------
remove_timestamps([{Client, _}|Tail], Clients) ->
	remove_timestamps(Tail, [Client|Clients]);
remove_timestamps([], Clients) ->
	Clients.
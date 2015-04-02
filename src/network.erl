%% ------------------------------------------------
%% @author Marco Franceschetti <marco.franceschetti@gmail.com>
%% @copyright Marco Franceschetti, 2014
%% @end
%% ------------------------------------------------

-module(network).

-include("include/strings.hrl").

-export([start/1]).

%% ------------------------------------------------
%% @doc Invia un messaggio broadcast per determinare se sono già presenti broker sulla rete locale:
%% in caso affermativo, viene ricevuto un pacchetto UDP di risposta da cui si ricava l'indirizzo del broker;
%% se non sono presenti broker (non si riceve risposta dopo 3 secondi dalla richiesta), è necessario avviare
%% un processo broker in locale e connettersi ad esso all'indirizzo 127.0.0.1.
%% Infine, viene avviato lo status loop.
%% NOTA BENE: VMWare Player non permette l'uso del broadcast, quindi esso è stato simulato con più messaggi in unicast.
%% @end
%% ------------------------------------------------
start(Controller_PID) ->
	{ok, Socket} = gen_udp:open(15432, [list, {active, false}]),
	gen_udp:send(Socket, {192,168,208,145}, 15433, ?S_ANYBROKER),
	gen_udp:send(Socket, {192,168,208,146}, 15433, ?S_ANYBROKER),
	gen_udp:send(Socket, {192,168,208,147}, 15433, ?S_ANYBROKER),
	gen_udp:send(Socket, {192,168,208,148}, 15433, ?S_ANYBROKER),
	gen_udp:send(Socket, {192,168,208,149}, 15433, ?S_ANYBROKER),
	Received = gen_udp:recv(Socket, 0, 3000),
	gen_udp:close(Socket),
	case Received of
		{ok, {Broker_IP, _, _}} ->
			Am_i_broker = false,
			Controller_PID ! {?A_FROMNETWORK, ?A_FOUNDBROKER, Broker_IP};
		_ ->
			Am_i_broker = true,
			Broker_IP = {127,0,0,1},
			Controller_PID ! {?A_FROMNETWORK, ?A_NOBROKER}
	end,
	{ok, Loop_socket} = gen_udp:open(15433, [list, {active, false}]),
	status_loop(Controller_PID, Broker_IP, Loop_socket, Am_i_broker).

%% ------------------------------------------------
%% @doc Cicla in attesa di ricevere messaggi di richiesta di presenza di broker sulla rete locale:
%% se chi riceve la richiesta ha un broker avviato allora risponde al messaggio, altrimenti lo ignora.
%% Inoltre, è possibile che il processo Controller comunichi di avere avviato il broker, in modo da rispondere
%% ad eventuali richieste future.
%% @end
%% ------------------------------------------------
status_loop(Controller_PID, Broker_IP, Socket, Am_i_broker)  ->
	Received = gen_udp:recv(Socket, 0, 500),
	case Received of
		{ok, {Requester_IP, Requester_port, ?S_ANYBROKER}} when Am_i_broker ->
			gen_udp:send(Socket, Requester_IP, Requester_port, ?S_IAMBROKER);
		_ ->
			true
	end,
	receive
		{?A_FROMCONTROLLER, ?A_BEABROKER} ->
			status_loop(Controller_PID, "localhost", Socket, true)
	after 500 ->
		status_loop(Controller_PID, Broker_IP, Socket, Am_i_broker)
	end.
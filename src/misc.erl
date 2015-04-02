%% ------------------------------------------------
%% @author Marco Franceschetti <marco.franceschetti@gmail.com>
%% @copyright Marco Franceschetti, 2014
%% @end
%% ------------------------------------------------

-module(misc).

-export([add_if_new/2, remove_if_exists/2, is_in_list/2, add_to_list/2, delete_from_list/2, reformat_string/1, secs/1]).

%% ------------------------------------------------
%% @doc Funzione di supporto per l'aggiunta di un elemento ad una lista qualora esso non sia già presente in essa.
%% @end
%% ------------------------------------------------
add_if_new(Element, List) ->
	case is_in_list(Element, List) of
		true ->
			List;
		false ->
			add_to_list(Element, List)
	end.

%% ------------------------------------------------
%% @doc Funzione di supporto per la rimozione di un elemento da una lista qualora esso sia già presente in essa.
%% @end
%% ------------------------------------------------
remove_if_exists(Element, List) ->
	case is_in_list(Element, List) of
		true ->
			delete_from_list(Element, List);
		false ->
			List
	end.

%% ------------------------------------------------
%% @doc Funzione di supporto che determina se un elemento appartiene ad una lista.
%% @end
%% ------------------------------------------------
is_in_list(_, []) -> false;
is_in_list(Element, [Element|_]) -> true;
is_in_list(Element, [_|Tail]) -> is_in_list(Element, Tail).

%% ------------------------------------------------
%% @doc Funzione di supporto per l'aggiunta di un elemento ad una lista.
%% @end
%% ------------------------------------------------
add_to_list(Element, List) -> [Element|List].

%% ------------------------------------------------
%% @doc Funzione di supporto per la rimozione di un elemento da una lista.
%% @end
%% ------------------------------------------------
delete_from_list(Element, [Element|Tail]) -> Tail;
delete_from_list(Element, [Head|Tail]) -> [Head|delete_from_list(Element, Tail)].

%% ------------------------------------------------
%% @doc Funzione di supporto che trasforma una bitstring (racchiusa tra angle brackets) in una stringa (racchiusa tra doppi apici).
%% @end
%% ------------------------------------------------
reformat_string(Bitstring) ->
	erlang:bitstring_to_list(Bitstring).

%% ------------------------------------------------
%% @doc Funzione di supporto che trasforma il timestamp di Erlang in secondi.
%% @end
%% ------------------------------------------------
secs({Megasecs, Secs, _}) ->
	(Megasecs*1000000 + Secs).
%% ------------------------------------------------
%% @author Marco Franceschetti <marco.franceschetti@gmail.com>
%% @copyright Marco Franceschetti, 2014
%% @end
%% ------------------------------------------------

-module(frontend).

-include("include/strings.hrl").
-include_lib("wx/include/wx.hrl").

-export([start/1]).

%% ------------------------------------------------
%% @doc Esegue le operazioni preliminari all'avvio di un processo Frontend:
%% genera gli elementi della User interface,
%% quindi avvia il frontend loop per la gestione degli eventi e dei messaggi.
%% @end
%% ------------------------------------------------
start(Controller_PID) ->
	State = generate_UI(),
	loop(Controller_PID, State).

%% ------------------------------------------------
%% @doc Genera gli elementi dell'interfaccia utente.
%% @end
%% ------------------------------------------------
generate_UI() ->
	Wx = wx:new(),
	Window = wxFrame:new(Wx, -1, ?S_NAME, [{size, {400, 510}}]),
	Panel = wxPanel:new(Window),
	wxFrame:createStatusBar(Window),
	wxFrame:setStatusText(Window, ?S_CONNECTING),
	Menu_bar = wxMenuBar:new(),
	wxFrame:setMenuBar(Window, Menu_bar),
	Topics_menu = wxMenu:new(),
	wxMenuBar:append(Menu_bar, Topics_menu, ?S_TOPICS),
	New_topic_button = wxMenuItem:new([{id, 400}, {text, ?S_CREATETOPIC}]),
	wxMenu:append(Topics_menu, New_topic_button),
	My_topics_button = wxMenuItem:new([{id, 401}, {text, ?S_LISTMYTOPICS}]),
	wxMenu:append(Topics_menu, My_topics_button),
	Available_topics_button = wxMenuItem:new([{id, 402}, {text, ?S_LISTALLTOPICS}]),
	wxMenu:append(Topics_menu, Available_topics_button),
	Subscribe_button = wxMenuItem:new([{id, 403}, {text, ?S_SUBSCRIBE}]),
	wxMenu:append(Topics_menu, Subscribe_button),
	Unsubscribe_button = wxMenuItem:new([{id, 404}, {text, ?S_UNSUBSCRIBE}]),
	wxMenu:append(Topics_menu, Unsubscribe_button),
	Setcurrent_button = wxMenuItem:new([{id, 405}, {text, ?S_SETCURRENTTOPIC}]),
	wxMenu:append(Topics_menu, Setcurrent_button),
	MainSizer = wxBoxSizer:new(?wxVERTICAL),
	InputSizer = wxBoxSizer:new(?wxHORIZONTAL),
	OutputSizer = wxBoxSizer:new(?wxVERTICAL),
	User_input = wxTextCtrl:new(Panel, 500, [{size, {300, 60}},{value, ?S_DEFAULTINPUT},  {style, ?wxDEFAULT bor ?wxTE_MULTILINE},  {style, ?wxDEFAULT bor ?wxTE_PROCESS_ENTER}]),
	Submit_button = wxButton:new(Panel, 501, [{label, ?S_SEND}, {size, {100, 60}}]),
	wxButton:disable(Submit_button),
	wxSizer:add(InputSizer, User_input, []),
	wxSizer:add(InputSizer, Submit_button, []),
	Chat_history = wxHtmlWindow:new(Panel, [{id, 600}, {size, {400, 400}}]),
	wxSizer:add(OutputSizer, Chat_history, []),
	wxSizer:add(MainSizer, OutputSizer, []),
	wxSizer:add(MainSizer, InputSizer, []),
	wxPanel:setSizer(Panel, MainSizer),
	wxFrame:show(Window),
	wxFrame:connect(Window, command_menu_selected),
	wxFrame:connect(Window, close_window),
	wxPanel:connect(Panel, command_button_clicked),
	{Window, User_input, Submit_button, Chat_history, ?T_DEFAULT}.

%% ------------------------------------------------
%% @doc Cicla in attesa di ricevere messaggi relativi ad eventi di interazione con gli elementi della UI
%% o di messaggi inviati dal processo Controller.
%% @end
%% ------------------------------------------------
loop(Controller_PID, State) ->
	{Window, User_input, Submit_button, Chat_history, Current_topic} = State,
	receive
		#wx{event=#wxClose{}} ->
			wxWindow:destroy(Window),
			{ok, [{Own_IP, _, _}|_]} = inet:getif(),
			Controller_PID ! {?A_FROMFRONTEND, ?A_DISCONNECT, Own_IP};
		#wx{obj=_, userData=_, event=#wxCommand{type=command_menu_selected}} = Wx ->
			{wx, Id, _, _, _} = Wx,
			case Id of
				400 ->
					Text = wxTextCtrl:getValue(User_input),
					Controller_PID ! {?A_FROMFRONTEND, ?A_NEWTOPIC, Text},
					wxTextCtrl:setValue(User_input, "");
				401 ->
					Controller_PID ! {?A_FROMFRONTEND, ?A_MYTOPICS};
				402 ->
					Controller_PID ! {?A_FROMFRONTEND, ?A_ALLTOPICS};
				403 ->
					Text = wxTextCtrl:getValue(User_input),
					Controller_PID ! {?A_FROMFRONTEND, ?A_SUBSCRIBE, Text},
					wxTextCtrl:setValue(User_input, "");
				404 ->
					Text = wxTextCtrl:getValue(User_input),
					Controller_PID ! {?A_FROMFRONTEND, ?A_UNSUBSCRIBE, Text},
					wxTextCtrl:setValue(User_input, "");
				405 ->
					Text = wxTextCtrl:getValue(User_input),
					wxTextCtrl:setValue(User_input, ""),
					loop(Controller_PID, {Window, User_input, Submit_button, Chat_history, Text});
				_ ->
					loop(Controller_PID, State)
			end,
			loop(Controller_PID, State);
		#wx{obj=_, userData=_, event=#wxCommand{type=command_button_clicked}} = Wx ->
			{wx, Id, _, _, _} = Wx,
			case Id of
				501 ->
					Msg = wxTextCtrl:getValue(User_input),
					Controller_PID ! {?A_FROMFRONTEND, ?A_PUBLISH, Current_topic, Msg},
					wxTextCtrl:setValue(User_input, ""),
					loop(Controller_PID, State);
				_ ->
					loop(Controller_PID, State)
			end,
			loop(Controller_PID, State);
		{?A_FROMCONTROLLER, ?A_NEWMESSAGE, Topic, Msg} ->
			print_message(Chat_history, Topic, Msg),
			loop(Controller_PID, State);
		{?A_FROMCONTROLLER, ?A_MYTOPICS, Mytopics} ->
			print_my_topics(Chat_history, Mytopics),
			loop(Controller_PID, State);
		{?A_FROMCONTROLLER, ?A_ALLTOPICS, Alltopics} ->
			print_all_topics(Chat_history, Alltopics),
			loop(Controller_PID, State);
		{?A_FROMCONTROLLER, ?A_DISABLEINPUT} ->
			wxButton:disable(Submit_button),
			loop(Controller_PID, State);
		{?A_FROMCONTROLLER, ?A_ENABLEINPUT} ->
			wxButton:enable(Submit_button),
			loop(Controller_PID, State);
		{?A_FROMCONTROLLER, ?A_CHANGESTATUS, New_status} ->
			wxFrame:setStatusText(Window, New_status),
			loop(Controller_PID, State)
	after 5000 ->
			loop(Controller_PID, State)
	end.

%% ------------------------------------------------
%% @doc Funzione di supporto alla generazione della chat history per visualizzare un nuovo messaggio.
%% @end
%% ------------------------------------------------
print_message(Chat_history, Topic, Msg) ->
	wxHtmlWindow:appendToPage(Chat_history, "<p style=\"text-align:right;\"><hr noshade><b>"),
	wxHtmlWindow:appendToPage(Chat_history, Topic),
	wxHtmlWindow:appendToPage(Chat_history, "</b><br>"),
	wxHtmlWindow:appendToPage(Chat_history, Msg),
	wxHtmlWindow:appendToPage(Chat_history, "</p>").

%% ------------------------------------------------
%% @doc Funzione di supporto alla generazione della chat history per visualizzare la lista dei topic di interesse.
%% @end
%% ------------------------------------------------
print_my_topics(Chat_history, Mytopics) ->
	wxHtmlWindow:appendToPage(Chat_history, "<p style=\"text-align:right;\"><hr noshade><b>"),
	wxHtmlWindow:appendToPage(Chat_history, "List of current subscriptions"),
	wxHtmlWindow:appendToPage(Chat_history, "</b><br>"),
	wxHtmlWindow:appendToPage(Chat_history, lists:sort(lists:map(fun append_br/1, Mytopics))),
	wxHtmlWindow:appendToPage(Chat_history, "</p>").

%% ------------------------------------------------
%% @doc Funzione di supporto alla generazione della chat history per visualizzare la lista dei topic disponibili.
%% @end
%% ------------------------------------------------
print_all_topics(Chat_history, Alltopics) ->
	wxHtmlWindow:appendToPage(Chat_history, "<p style=\"text-align:right;\"><hr noshade><b>"),
	wxHtmlWindow:appendToPage(Chat_history, "List of available topics"),
	wxHtmlWindow:appendToPage(Chat_history, "</b><br>"),
	wxHtmlWindow:appendToPage(Chat_history, lists:sort(lists:map(fun append_br/1, Alltopics))),
	wxHtmlWindow:appendToPage(Chat_history, "</p>").

%% ------------------------------------------------
%% @doc Funzione di supporto alla generazione della chat history all'arrivo di ogni nuovo messaggio di chat.
%% @end
%% ------------------------------------------------
append_br(Element) ->
	lists:append(Element, "<br>").
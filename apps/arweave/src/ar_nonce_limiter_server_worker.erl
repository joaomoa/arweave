-module(ar_nonce_limiter_server_worker).

-behaviour(gen_server).

-export([start_link/2]).

-export([init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2]).

-include_lib("arweave/include/ar.hrl").

-record(state, {
	peer,
	raw_peer,
	pause_until = 0,
	format = 1
}).

%% The frequency of re-resolving the domain names of the VDF client peers (who are
%% configured via the domain names as opposed to IP addresses).
-define(RESOLVE_DOMAIN_NAME_FREQUENCY_MS, 30000).

-define(NONCE_LIMITER_UPDATE_VERSION, 67).

%%%===================================================================
%%% Public interface.
%%%===================================================================

%% @doc Start the server.
start_link(Name, RawPeer) ->
	gen_server:start_link({local, Name}, ?MODULE, RawPeer, []).

%%%===================================================================
%%% Generic server callbacks.
%%%===================================================================

init(RawPeer) ->
	process_flag(trap_exit, true),
	ok = ar_events:subscribe(nonce_limiter),
	gen_server:cast(self(), resolve_raw_peer),
	{ok, #state{ raw_peer = RawPeer }}.

handle_call(Request, _From, State) ->
	?LOG_WARNING([{event, unhandled_call}, {module, ?MODULE}, {request, Request}]),
	{reply, ok, State}.

handle_cast(resolve_raw_peer, #state{ raw_peer = RawPeer } = State) ->
	case ar_peers:resolve_and_cache_peer(RawPeer, vdf_client_peer) of
		{ok, Peer} ->
			ar_util:cast_after(?RESOLVE_DOMAIN_NAME_FREQUENCY_MS, self(), resolve_raw_peer),
			{noreply, State#state{ peer = Peer }};
		{error, Reason} ->
			?LOG_WARNING([{event, failed_to_resolve_vdf_client_peer},
					{reason, io_lib:format("~p", [Reason])}]),
			ar_util:cast_after(10000, self(), resolve_raw_peer),
			{noreply, State}
	end;

handle_cast(Cast, State) ->
	?LOG_WARNING([{event, unhandled_cast}, {module, ?MODULE}, {cast, Cast}]),
	{noreply, State}.

handle_info({event, nonce_limiter, _Event}, #state{ peer = undefined } = State) ->
	{noreply, State};
handle_info({event, nonce_limiter, {computed_output, Args}}, State) ->
	#state{ peer = Peer, pause_until = Timestamp, format = Format } = State,
	{SessionKey, StepNumber, Output, _PartitionUpperBound} = Args,
	CurrentStepNumber = ar_nonce_limiter:get_current_step_number(),
	case os:system_time(second) < Timestamp of
		true ->
			{noreply, State};
		false ->
			case StepNumber < CurrentStepNumber of
				true ->
					{noreply, State};
				false ->
					{noreply, push_update(SessionKey, StepNumber, Output, Peer, Format, State)}
			end
	end;

handle_info({event, nonce_limiter, _Args}, State) ->
	{noreply, State};

handle_info(Message, State) ->
	?LOG_WARNING([{event, unhandled_info}, {module, ?MODULE}, {message, Message}]),
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

%%%===================================================================
%%% Private functions.
%%%===================================================================

push_update(SessionKey, StepNumber, Output, Peer, Format, State) ->
	Session = ar_nonce_limiter:get_session(SessionKey),
	Update = ar_nonce_limiter_server:make_partial_nonce_limiter_update(
		SessionKey, Session, StepNumber, Output),
	case Update of
		not_found -> State;
		_ ->
			case ar_http_iface_client:push_nonce_limiter_update(Peer, Update, Format) of
				ok ->
					State;
				{ok, Response} ->
					RequestedFormat = Response#nonce_limiter_update_response.format,
					Postpone = Response#nonce_limiter_update_response.postpone,
					SessionFound = Response#nonce_limiter_update_response.session_found,
					RequestedStepNumber = Response#nonce_limiter_update_response.step_number,

					case { 
							RequestedFormat == Format,
							Postpone == 0,
							SessionFound,
							RequestedStepNumber >= StepNumber - 1
					} of
						{false, _, _, _} ->
							%% Client requested a different payload format
							?LOG_DEBUG([{event, vdf_client_requested_different_format},
								{peer, ar_util:format_peer(Peer)},
								{format, Format}, {requested_format, RequestedFormat}]),
							push_update(SessionKey, StepNumber, Output, Peer, RequestedFormat,
									State#state{ format = RequestedFormat });
						{true, false, _, _} ->
							%% Client requested we pause updates
							Now = os:system_time(second),
							State#state{ pause_until = Now + Postpone };
						{true, true, false, _} ->
							%% Client requested the full session
							PrevSessionKey = Session#vdf_session.prev_session_key,
							PrevSession = ar_nonce_limiter:get_session(PrevSessionKey),
							push_session(PrevSessionKey, PrevSession, Peer, Format),
							push_session(SessionKey, Session, Peer, Format),
							State;
						{true, true, true, false} ->
							%% Client requested missing steps
							push_session(SessionKey, Session, Peer, Format),
							State;
						_ ->
							%% Client is ahead of the server
							State
					end;
				{error, Error} ->
					log_failure(Peer, SessionKey, Update, [{reason, io_lib:format("~p", [Error])}]),
					State
			end
	end.

push_session(SessionKey, Session, Peer, Format) ->
	Update = ar_nonce_limiter_server:make_full_nonce_limiter_update(SessionKey, Session),
	case Update of
		not_found -> ok;
		_ ->
			case ar_http_iface_client:push_nonce_limiter_update(Peer, Update, Format) of
				ok ->
					ok;
				{ok, #nonce_limiter_update_response{ step_number = ClientStepNumber,
						session_found = ReportedSessionFound }} ->
					log_failure(Peer, SessionKey, Update,
						[{client_step_number, ClientStepNumber},
						{session_found, ReportedSessionFound}]);
				{error, Error} ->
					log_failure(Peer, SessionKey, Update, [{reason, io_lib:format("~p", [Error])}])
			end
	end.

log_failure(Peer, SessionKey, Update, Extra) ->
	{SessionSeed, SessionInterval, NextVDFDifficulty} = SessionKey,
	StepNumber = Update#nonce_limiter_update.session#vdf_session.step_number,
	?LOG_WARNING([{event, failed_to_push_nonce_limiter_update_to_peer},
			{peer, ar_util:format_peer(Peer)},
			{session_seed, ar_util:encode(SessionSeed)},
			{session_interval, SessionInterval},
			{session_difficulty, NextVDFDifficulty},
			{server_step_number, StepNumber}] ++ Extra).
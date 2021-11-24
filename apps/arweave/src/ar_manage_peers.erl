-module(ar_manage_peers).

-export([update/1, stats/0, reset/0, get_more_peers/1, is_public_peer/1]).

-include_lib("arweave/include/ar.hrl").

%%% Manage and update peer lists.

%% @doc Return true if the given peer has a public IPv4 address.
%% https://en.wikipedia.org/wiki/Reserved_IP_addresses.
is_public_peer({Oct1, Oct2, Oct3, Oct4, _Port}) ->
	is_public_peer({Oct1, Oct2, Oct3, Oct4});
is_public_peer({0, _, _, _}) ->
	false;
is_public_peer({10, _, _, _}) ->
	false;
is_public_peer({127, _, _, _}) ->
	false;
is_public_peer({100, Oct2, _, _}) when Oct2 >= 64 andalso Oct2 =< 127 ->
	false;
is_public_peer({169, 254, _, _}) ->
	false;
is_public_peer({172, Oct2, _, _}) when Oct2 >= 16 andalso Oct2 =< 31 ->
	false;
is_public_peer({192, 0, 0, _}) ->
	false;
is_public_peer({192, 0, 2, _}) ->
	false;
is_public_peer({192, 88, 99, _}) ->
	false;
is_public_peer({192, 168, _, _}) ->
	false;
is_public_peer({198, 18, _, _}) ->
	false;
is_public_peer({198, 19, _, _}) ->
	false;
is_public_peer({198, 51, 100, _}) ->
	false;
is_public_peer({203, 0, 113, _}) ->
	false;
is_public_peer({Oct1, _, _, _}) when Oct1 >= 224 ->
	false;
is_public_peer(_) ->
	true.

%% @doc Print statistics about the current peers.
stats() ->
	Connected = ar_bridge:get_remote_peers(),
	io:format("Connected peers, in preference order:~n"),
	stats(Connected),
	io:format("Other known peers:~n"),
	stats(all_peers() -- Connected).
stats(Peers) ->
	lists:foreach(
		fun(Peer) -> format_stats(Peer, ar_util:get_performance(Peer)) end,
		Peers
	).

%% @doc Reset all performance counters and connections.
reset() ->
	lists:map(fun ar_util:reset_peer/1, All = all_peers()),
	ar_bridge:set_remote_peers(All).

%% @doc Return all known peers.
all_peers() ->
	[ Peer || {peer, Peer} <- ar_meta_db:keys() ].

%% @doc Pretty print stats about a node.
format_stats(Peer, Perf) ->
	io:format("\t~s ~.2f kB/s (~p transfers)~n",
		[
			string:pad(ar_util:format_peer(Peer), 20, trailing, $ ),
			(Perf#performance.bytes / 1024) / ((Perf#performance.time + 1) / 1000000),
			Perf#performance.transfers
		]
	).

%% @doc Take an existing peer list and create a new peer list. Gets all current peers
%% peerlist and ranks each peer by its connection speed to this node in the past.
%% Peers who have behaved well in the past are favoured in ranking.
%% New, unknown peers are given 100 blocks of grace.
update(Peers) ->
	Height = ar_node:get_height(),
	ar_meta_db:purge_peer_performance(),
	{Rankable, Newbies} =
		partition_newbies(
			score(
				filter_peers(get_more_peers(Peers), Height)
			)
		),
	NewPeers = (lists:sublist(maybe_drop_peers([ Peer || {Peer, _} <- rank_peers(Rankable) ]),
			?MAXIMUM_PEERS) ++ [ Peer || {Peer, newbie} <- Newbies ]),
	lists:foreach(
		fun(P) ->
			case lists:member(P, NewPeers) of
				false ->
					ar_util:update_timer(P);
				_ ->
					ok
			end
		end,
		Peers
	),
	NewPeers.

%% @doc Return a new list, with the peers and their peers.
get_more_peers(Peers) ->
	ar_util:unique(lists:flatten([
			[Peer || Peer <- ar_util:pmap(fun get_peers/1, lists:sublist(Peers, 10)),
					is_public_peer(Peer)], Peers])).

get_peers(Peer) ->
	case ar_http_iface_client:get_peers(Peer) of
		unavailable -> [];
		Peers -> Peers
	end.

filter_peers(Peers, Height) when length(Peers) < 10 ->
	ar_util:pfilter(fun(Peer) -> is_good_peer(Peer, Height) end, Peers);
filter_peers(Peers, Height) ->
	{Chunk, Rest} = lists:split(10, Peers),
	Filtered2 = ar_util:pfilter(fun(Peer) -> is_good_peer(Peer, Height) end, Chunk),
	Filtered2 ++ filter_peers(Rest, Height).

is_good_peer(Peer, Height) ->
	not lists:member(Peer, ?PEER_PERMANENT_BLACKLIST) andalso responds_not_stuck(Peer, Height).

responds_not_stuck(Peer, Height) ->
	case ar_http_iface_client:get_info(Peer, height) of
		info_unavailable -> false;
		H when H < (Height - ?STORE_BLOCKS_BEHIND_CURRENT) -> false;
		_ -> true
	end.

%% @doc Calculate a rank order for any given peer or list of peers.
score(Peers) when is_list(Peers) ->
	lists:map(fun(Peer) -> {Peer, score(Peer)} end, Peers);
score(Peer) ->
	case ar_util:get_performance(Peer) of
		P when P#performance.transfers < ?PEER_GRACE_PERIOD ->
			newbie;
		P ->
			P#performance.bytes / (P#performance.time + 1)
	end.

%% @doc Given a set of peers, returns a tuple containing peers that
%% are "rankable" and elidgible to be pruned, and new peers who are
%% within their grace period who are not
partition_newbies(ScoredPeers) ->
	Newbies = [ P || P = {_, newbie} <- ScoredPeers ],
	{ScoredPeers -- Newbies, Newbies}.

%% @doc Return a ranked list of peers.
rank_peers(ScoredPeers) ->
	lists:sort(fun({_, S1}, {_, S2}) -> S1 >= S2 end, ScoredPeers).

%% @doc Probabalistically drop peers based on their rank. Highly ranked peers are
%% less likely to be dropped than lower ranked ones.
maybe_drop_peers(Peers) ->
	maybe_drop_peers(1, length(Peers), Peers).
maybe_drop_peers(_, _, []) -> [];
maybe_drop_peers(Rank, NumPeers, [Peer|Peers]) when Rank =< ?MINIMUM_PEERS ->
	[Peer | maybe_drop_peers(Rank + 1, NumPeers, Peers)];
maybe_drop_peers(Rank, NumPeers, [Peer|Peers]) ->
	case roll(Rank, NumPeers) of
		true -> [Peer | maybe_drop_peers(Rank + 1, NumPeers, Peers)];
		false -> maybe_drop_peers(Rank + 1, NumPeers, Peers)
	end.

%% @doc Generate a boolean 'drop or not' value from a rank and the number of peers.
roll(Rank, NumPeers) ->
	case Rank =< ?MINIMUM_PEERS of
		true -> true;
		false ->
			(2 * rand:uniform(NumPeers - ?MINIMUM_PEERS)) >=
				(Rank - ?MINIMUM_PEERS)
	end.

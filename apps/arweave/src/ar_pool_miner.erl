
-module(ar_pool_miner).


-export([start_link/0]).
-export([init/1, handle_cast/2, terminate/2]).
-export([start/1]).

-include_lib("arweave/include/ar_config.hrl").

-record(mine_arg, {
	nonce_filter,
	share_diff,
	bds,
	bds_base,
	swap_height,
	search_space_upper_bound,
	prev_block,
	candidate_block
}).

%%%===================================================================
%%% Public interface.
%%%===================================================================

start_link() ->
	io:format("ar_pool_miner:start_link~n"), % TODO remove after debug finished, before commit
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%%===================================================================
%%% Generic server callbacks.
%%%===================================================================

init([]) ->
	io:format("ar_pool_miner:init~n"), % TODO remove after debug finished, before commit
	{ok, Config} = application:get_env(arweave, config),
	IOThreads =
		case Config#config.pool_mine of
			true ->
				ar_node_worker:start_io_threads();
			_ ->
				[]
		end,
	io:format("ar_pool_miner:init 2~n"), % TODO remove after debug finished, before commit
	{ok, #{
		io_threads => IOThreads,
		miner => undefined
	}}.

handle_cast({mine, MineArg}, State) ->
	io:format("mine MineArg ~p ~n", [MineArg]),
	NewState = start_mining(State#{
		current_block             => MineArg#mine_arg.prev_block,
		candidate_block           => MineArg#mine_arg.candidate_block,
		search_space_upper_bound  => MineArg#mine_arg.search_space_upper_bound,
		bds_base                  => MineArg#mine_arg.bds_base
	}),
	io:format("mine MineArg 2 ~n", []),
	{noreply, NewState};

handle_cast(_, State) ->
	io:format("ar_pool_miner handle_cast~n"), % TODO remove after debug finished, before commit
	{noreply, State}.

handle_info(wallets_ready, State) ->
	io:format("ar_pool_miner wallets_ready~n"),
	{noreply, State}.

terminate(_Reason, #{ miner := Miner }) ->
	case Miner of
		undefined -> do_nothing;
		PID -> ar_mine:stop(PID)
	end.




start_mining(StateIn) ->
	io:format("start_mining 1~n"),
	case ets:lookup(node_state, is_joined) of
		[{_, true}] ->
			io:format("start_mining 2~n"),
			
			#{
				io_threads := IOThreads,
				current_block := CurrentB,
				candidate_block := CandidateB,
				search_space_upper_bound := SearchSpaceUpperBound,
				bds_base := BDSBase,
				miner := Miner
			} = StateIn,
			io:format("start_mining 3~n"), % TODO remove after debug finished, before commit
			case Miner of
				undefined ->
					do_nothing;
				Pid ->
					ar_mine:stop(Pid)
			end,
			io:format("start_mining 4~n"), % TODO remove after debug finished, before commit
			[{block_index, BI}] = ets:lookup(node_state, block_index),
			[{block_anchors, BlockAnchors}] = ets:lookup(node_state, block_anchors),
			[{recent_txs_map, RecentTXMap}] = ets:lookup(node_state, recent_txs_map),
			io:format("start_mining 5~n"), % TODO remove after debug finished, before commit
			ar_watchdog:started_hashing(),
			Miner = ar_mine:start_server_ext({
				ar_pool_miner,
				CurrentB,
				<<"skip">>, % RewardAddr, should be unused
				CandidateB#block.tags, % Tags, should be unused
				BlockAnchors, % should be unused
				RecentTXMap, % should be unused
				CandidateB,
				CandidateB#block.txs, % TXs, should be unused
				SearchSpaceUpperBound,
				IOThreads,
				BI,
				BDSBase
			}),
			io:format("start_mining 6~n"), % TODO remove after debug finished, before commit
			?LOG_INFO([{event, started_mining}]),
			StateIn#{ miner => Miner };
		_ ->
			StateIn
	end,
	io:format("start_mining end~n").

start(MineJSON) ->
	% io:format("MineJSON ~p ~n", [MineJSON]),
	% io:format("WTF share_diff ~p ~n", [maps:get(<<"share_diff">>, MineJSON, <<>>)]),
	State = maps:get(<<"state">>, MineJSON, #{}),
	Block = maps:get(<<"block">>, State, #{}),
	% io:format("State ~p ~n", [State]),
	% io:format("Block ~p ~n", [Block]),
	MineArg = #mine_arg{
		nonce_filter  = ar_util:decode(maps:get(<<"nonce_filter">>, MineJSON, <<>>)),
		share_diff    = ar_util:decode(maps:get(<<"share_diff">>, MineJSON, <<>>)),
		bds           = ar_util:decode(maps:get(<<"bds">>, State, <<>>)),
		bds_base      = ar_util:decode(maps:get(<<"bds_base">>, State, <<>>)),
		swap_height   = maps:get(<<"swap_height">>, State, <<>>),
		search_space_upper_bound = binary_to_integer(maps:get(<<"search_space_upper_bound">>, State, <<>>)),
		prev_block = #block{
			height          = maps:get(<<"height">>, Block, <<>>) - 1,
			weave_size      = binary_to_integer(maps:get(<<"weave_size">>, Block, <<>>)) - binary_to_integer(maps:get(<<"block_size">>, Block, <<>>)),
			cumulative_diff = binary_to_integer(maps:get(<<"old_cumulative_diff">>, State, <<>>)),
			diff            = binary_to_integer(maps:get(<<"old_diff">>, State, <<>>)),
			last_retarget   = maps:get(<<"old_last_retarget">>, State, <<>>),
			indep_hash      = ar_util:decode(maps:get(<<"previous_block">>, Block, <<>>))
		},
		candidate_block = #block{
			height          = maps:get(<<"height">>, Block, <<>>),
			cumulative_diff = binary_to_integer(maps:get(<<"cumulative_diff">>, Block, <<>>)),
			diff            = binary_to_integer(maps:get(<<"diff">>, Block, <<>>)),
			block_size      = binary_to_integer(maps:get(<<"block_size">>, Block, <<>>)),
			weave_size      = binary_to_integer(maps:get(<<"weave_size">>, Block, <<>>)),
			reward_pool     = binary_to_integer(maps:get(<<"reward_pool">>, Block, <<>>)),
			last_retarget   = maps:get(<<"last_retarget">>, Block, <<>>),
			previous_block  = ar_util:decode(maps:get(<<"previous_block">>, Block, <<>>)),
			hash_list       = ar_util:decode(maps:get(<<"hash_list">>, Block, <<>>)),
			hash_list_merkle= ar_util:decode(maps:get(<<"hash_list_merkle">>, Block, <<>>)),
			reward_addr     = ar_util:decode(maps:get(<<"reward_addr">>, Block, <<>>)),
			timestamp       = maps:get(<<"timestamp">>, Block, <<>>),
			tx_root         = ar_util:decode(maps:get(<<"tx_root">>, Block, <<>>)),
			wallet_list     = ar_util:decode(maps:get(<<"wallet_list">>, Block, <<>>)),
			tags            = maps:get(<<"tags">>, Block, []), % NOT sure that it will work correctly
			txs             = maps:get(<<"txs">>, Block, [])
		}
	},
	io:format("gen_server:cast 1 ~n"),
	gen_server:cast(?MODULE, {mine, MineArg}),
	io:format("gen_server:cast 2 ~n"),
	[].

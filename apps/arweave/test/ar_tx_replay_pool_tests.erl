-module(ar_tx_replay_pool_tests).

-include_lib("arweave/include/ar.hrl").
-include_lib("arweave/include/ar_pricing.hrl").
-include_lib("eunit/include/eunit.hrl").

verify_block_txs_test() ->
	Key1 = ar_wallet:new(),
	Key2 = ar_wallet:new(),
	RandomBlockAnchors =
		[crypto:strong_rand_bytes(32) || _ <- lists:seq(1, ?MAX_TX_ANCHOR_DEPTH)],
	Timestamp = os:system_time(seconds),
	Diff = random_diff(),
	BlockAnchorTXAtForkHeight = tx(Key1, fee(Diff, ar_fork:height_2_0(), Timestamp), <<"hash">>),
	BlockAnchorTXAfterForkHeight =
		tx(Key1, fee(Diff, ar_fork:height_2_0() + 1, Timestamp), <<"hash">>),
	TestCases = [
		#{
			title => "Fork height 2.0 accepts block anchors",
			txs => [tx(Key1, fee(Diff, ar_fork:height_2_0(), Timestamp), <<"hash">>)],
			height => ar_fork:height_2_0(),
			wallet_list => [wallet(Key1, fee(Diff, ar_fork:height_2_0(), Timestamp))],
			block_anchors => [<<"hash">>],
			recent_txs_map => #{},
			expected_result => valid
		},
		#{
			title => "After fork height 2.0 accepts block anchors",
			txs => [tx(Key1, fee(Diff, ar_fork:height_2_0() + 1, Timestamp), <<"hash">>)],
			height => ar_fork:height_2_0() + 1,
			wallet_list => [wallet(Key1, fee(Diff, ar_fork:height_2_0() + 1, Timestamp))],
			block_anchors => [<<"hash">>],
			recent_txs_map => #{},
			expected_result => valid
		},
		#{
			title => "Fork height 2.0 rejects outdated block anchors",
			txs => [
				tx(
					Key1,
					fee(Diff, ar_fork:height_2_0(), Timestamp),
					crypto:strong_rand_bytes(32)
				)
			],
			height => ar_fork:height_2_0(),
			wallet_list => [wallet(Key1, fee(Diff, ar_fork:height_2_0(), Timestamp))],
			block_anchors => RandomBlockAnchors,
			recent_txs_map => #{},
			expected_result => invalid
		},
		#{
			title => "Fork height 2.0 accepts wallet list anchors",
			txs => [
				tx(Key1, fee(Diff, ar_fork:height_2_0(), Timestamp), <<>>),
				tx(Key2, fee(Diff, ar_fork:height_2_0(), Timestamp), <<>>)
			],
			height => ar_fork:height_2_0(),
			wallet_list => [
				wallet(Key1, fee(Diff, ar_fork:height_2_0(), Timestamp)),
				wallet(Key2, fee(Diff, ar_fork:height_2_0(), Timestamp))
			],
			block_anchors => [],
			recent_txs_map => #{},
			expected_result => valid
		},
		#{
			title => "After fork height 2.0 accepts wallet list anchors",
			txs => [
				tx(Key1, fee(Diff, ar_fork:height_2_0() + 1, Timestamp), <<>>),
				tx(Key2, fee(Diff, ar_fork:height_2_0() + 1, Timestamp), <<>>)
			],
			height => ar_fork:height_2_0() + 1,
			wallet_list => [
				wallet(Key1, fee(Diff, ar_fork:height_2_0() + 1, Timestamp)),
				wallet(Key2, fee(Diff, ar_fork:height_2_0() + 1, Timestamp))
			],
			block_anchors => [],
			recent_txs_map => #{},
			expected_result => valid
		},
		#{
			title => "Fork height 2.0 rejects conflicting wallet list anchors",
			txs => [
				tx(Key1, fee(Diff, ar_fork:height_2_0(), Timestamp), <<>>),
				tx(Key1, fee(Diff, ar_fork:height_2_0(), Timestamp), <<>>)
			],
			height => ar_fork:height_2_0(),
			wallet_list => [wallet(Key1, 2 * fee(Diff, ar_fork:height_2_0(), Timestamp))],
			block_anchors => [],
			recent_txs_map => #{},
			expected_result => invalid
		},
		#{
			title => "Fork height 2.0 rejects chained wallet list anchors",
			txs => make_tx_chain(Key1, Diff, ar_fork:height_2_0(), Timestamp),
			height => ar_fork:height_2_0(),
			wallet_list => [wallet(Key1, 2 * fee(Diff, ar_fork:height_2_0(), Timestamp))],
			block_anchors => [],
			recent_txs_map => #{},
			expected_result => invalid
		},
		#{
			title => "Fork height 2.0 rejects conflicting balances",
			txs => [
				tx(Key1, fee(Diff, ar_fork:height_2_0(), Timestamp), <<>>),
				tx(Key1, fee(Diff, ar_fork:height_2_0(), Timestamp), <<>>)
			],
			height => ar_fork:height_2_0(),
			wallet_list =>
				[wallet(Key1, erlang:trunc(1.5 * fee(Diff, ar_fork:height_2_0(), Timestamp)))],
			block_anchors => [],
			recent_txs_map => #{},
			expected_result => invalid
		},
		#{
			title => "Fork height 2.0 rejects duplicates",
			txs => [BlockAnchorTXAtForkHeight, BlockAnchorTXAtForkHeight],
			height => ar_fork:height_2_0(),
			wallet_list => [wallet(Key1, 2 * fee(Diff, ar_fork:height_2_0(), Timestamp))],
			block_anchors => [],
			recent_txs_map => #{},
			expected_result => invalid
		},
		#{
			title => "After fork height 2.0 rejects duplicates",
			txs => [BlockAnchorTXAfterForkHeight, BlockAnchorTXAfterForkHeight],
			height => ar_fork:height_2_0() + 1,
			wallet_list => [wallet(Key1, 2 * fee(Diff, ar_fork:height_2_0() + 1, Timestamp))],
			block_anchors => [],
			recent_txs_map => #{},
			expected_result => invalid
		},
		#{
			title => "Fork height 2.0 rejects txs from the weave",
			txs => [BlockAnchorTXAtForkHeight],
			height => ar_fork:height_2_0(),
			wallet_list => [wallet(Key1, fee(Diff, ar_fork:height_2_0(), Timestamp))],
			block_anchors => [<<"hash">>, <<"otherhash">>],
			recent_txs_map => #{
				<<"txid">> => ok,
				<<"txid2">> => ok,
				BlockAnchorTXAtForkHeight#tx.id => ok
			},
			expected_result => invalid
		},
		#{
			title => "After fork height 2.0 rejects txs from the weave",
			txs => [BlockAnchorTXAfterForkHeight],
			height => ar_fork:height_2_0() + 1,
			wallet_list => [wallet(Key1, fee(Diff, ar_fork:height_2_0() + 1, Timestamp))],
			block_anchors => [<<"hash">>, <<"otherhash">>],
			recent_txs_map => #{
				<<"txid">> => ok,
				<<"txid2">> => ok,
				BlockAnchorTXAfterForkHeight#tx.id => ok
			},
			expected_result => invalid
		}
	],
	lists:foreach(
		fun(#{
			title := Title,
			txs := TXs,
			height := Height,
			wallet_list := WL,
			block_anchors := BlockAnchors,
			recent_txs_map := RecentTXMap,
			expected_result := ExpectedResult
		}) ->
			Wallets = maps:from_list([{A, {B, LTX}} || {A, B, LTX} <- WL]),
			?assertEqual(
				ExpectedResult,
				ar_tx_replay_pool:verify_block_txs({
					TXs,
					Diff,
					Height,
					Timestamp,
					Wallets,
					BlockAnchors,
					RecentTXMap
				}),
				Title
			),
			PickedTXs = ar_tx_replay_pool:pick_txs_to_mine({
				BlockAnchors,
				RecentTXMap,
				Height,
				Diff,
				Timestamp,
				Wallets,
				TXs
			}),
			?assertEqual(
				valid,
				ar_tx_replay_pool:verify_block_txs({
					PickedTXs,
					Diff,
					Height,
					Timestamp,
					Wallets,
					BlockAnchors,
					RecentTXMap
				}),
				lists:flatten(
					io_lib:format("Verifyng after picking_txs_to_mine: ~s:", [Title])
				)
			)
		end,
		TestCases
	).

make_tx_chain(Key, Diff, Height, Timestamp) ->
	TX1 = tx(Key, fee(Diff, Height, Timestamp), <<>>),
	TX2 = tx(Key, fee(Diff, Height, Timestamp), TX1#tx.id),
	[TX1, TX2].

tx(Key = {_, Pub}, Reward, Anchor) ->
	ar_tx:sign(
		#tx {
			format = 2,
			owner = Pub,
			reward = Reward,
			last_tx = Anchor
		},
		Key
	).

wallet({_, Pub}, Balance) ->
	{ar_wallet:to_address(Pub), Balance, <<>>}.

fee(Diff, Height, Timestamp) ->
	ar_tx:get_tx_fee(?TX_SIZE_BASE, Diff, Height, Timestamp).

random_diff() ->
	MinDiff = ar_mine:min_difficulty(ar_fork:height_2_0()),
	MaxDiff = ar_mine:max_difficulty(),
	MinDiff + rand:uniform(MaxDiff - MinDiff).

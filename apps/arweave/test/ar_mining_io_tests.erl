-module(ar_mining_io_tests).

-include_lib("arweave/include/ar.hrl").
-include_lib("arweave/include/ar_config.hrl").
-include_lib("arweave/include/ar_consensus.hrl").
-include_lib("arweave/include/ar_mining.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(WEAVE_SIZE, trunc(2.5 * ?PARTITION_SIZE)).

recall_chunk(WhichChunk, Chunk, Nonce, Candidate) ->
	ets:insert(?MODULE, {WhichChunk, Nonce, Chunk, Candidate}).

setup_all() ->
	[B0] = ar_weave:init([], 1, ?WEAVE_SIZE),
	RewardAddr = ar_wallet:to_address(ar_wallet:new_keyfile()),
	{ok, Config} = application:get_env(arweave, config),
	StorageModules = lists:flatten(
		[[{?PARTITION_SIZE, N, {spora_2_6, RewardAddr}}] || N <- lists:seq(0, 8)]),
	ar_test_node:start(B0, RewardAddr, Config, StorageModules),
	{Setup, Cleanup} = ar_test_node:mock_functions([
		{ar_mining_server, recall_chunk, fun recall_chunk/4}
	]),
	Functions = Setup(),
	{Cleanup, Functions}.

cleanup_all({Cleanup, Functions}) ->
	Cleanup(Functions).

setup_one() ->
	ets:new(?MODULE, [named_table, duplicate_bag, public]).

cleanup_one(_) ->
	ets:delete(?MODULE).

read_recall_range_test_() ->
	{setup, fun setup_all/0, fun cleanup_all/1,
		{foreach, fun setup_one/0, fun cleanup_one/1,
		[
			{timeout, 180, fun test_read_recall_range/0},
			{timeout, 180, fun test_io_threads/0},
			{timeout, 30, fun test_partitions/0},
			{timeout, 180, fun test_mining_session/0}
		]}
    }.

test_read_recall_range() ->
	Candidate = default_candidate(),
	?assertEqual(true, ar_mining_io:read_recall_range(chunk1, Candidate, 0)),
	wait_for_io(2),
	[Chunk1, Chunk2] = get_recall_chunks(),
	assert_recall_chunks([{chunk1, 0, Chunk1, Candidate}, {chunk1, 1, Chunk2, Candidate}]),

	?assertEqual(true, ar_mining_io:read_recall_range(chunk1, Candidate, ?DATA_CHUNK_SIZE div 2)),
	wait_for_io(2),
	assert_recall_chunks([{chunk1, 0, Chunk1, Candidate}, {chunk1, 1, Chunk2, Candidate}]),

	?assertEqual(true, ar_mining_io:read_recall_range(chunk1, Candidate, ?DATA_CHUNK_SIZE)),
	wait_for_io(2),
	[Chunk2, Chunk3] = get_recall_chunks(),
	assert_recall_chunks([{chunk1, 0, Chunk2, Candidate}, {chunk1, 1, Chunk3, Candidate}]),

	?assertEqual(true, ar_mining_io:read_recall_range(chunk2, Candidate,
		?PARTITION_SIZE - ?DATA_CHUNK_SIZE)),
	wait_for_io(2),
	[Chunk4, Chunk5] = get_recall_chunks(),
	assert_recall_chunks([{chunk2, 0, Chunk4, Candidate}, {chunk2, 1, Chunk5, Candidate}]),

	?assertEqual(true, ar_mining_io:read_recall_range(chunk2, Candidate, ?PARTITION_SIZE)),
	wait_for_io(2),
	[Chunk5, Chunk6] = get_recall_chunks(),
	assert_recall_chunks([{chunk2, 0, Chunk5, Candidate}, {chunk2, 1, Chunk6, Candidate}]),

	?assertEqual(true, ar_mining_io:read_recall_range(chunk1, Candidate,
		?WEAVE_SIZE - ?DATA_CHUNK_SIZE)),
	wait_for_io(2),
	[Chunk7, _Chunk8] = get_recall_chunks(),
	assert_recall_chunks([{chunk1, 0, Chunk7, Candidate}, {skipped, 1, undefined, Candidate}]),

	?assertEqual(false, ar_mining_io:read_recall_range(chunk1, Candidate, ?WEAVE_SIZE)).

test_io_threads() ->
	Candidate = default_candidate(),

	%% default configuration has 9 storage modules, even though the weave size only covers the
	%% first 3.
	?assertEqual(9, ar_mining_io:get_thread_count()),

	%% Assert that ar_mining_io uses multiple threads when reading from different partitions.
	%% We do this indirectly by comparing the time to read repeatedly from one partition vs.
	%% the time to read from multiple partitions.
	Iterations = 3000,

    SingleThreadStart = os:system_time(microsecond),
    lists:foreach(
		fun(_) ->
			?assertEqual(true, ar_mining_io:read_recall_range(chunk1, Candidate, 0))
		end,
		lists:seq(1, Iterations)),
	wait_for_io(2*Iterations),
    SingleThreadTime = os:system_time(microsecond) - SingleThreadStart,
	ets:delete_all_objects(?MODULE),

	MultiThreadStart = os:system_time(microsecond),
    lists:foreach(
		fun(I) ->
			Offset = (I * 2 * ?DATA_CHUNK_SIZE) rem ?WEAVE_SIZE,
			?assertEqual(true, ar_mining_io:read_recall_range(chunk1, Candidate, Offset))
		end,
		lists:seq(1, Iterations)),
	wait_for_io(2*Iterations),
    MultiThreadTime = os:system_time(microsecond) - MultiThreadStart,
	ets:delete_all_objects(?MODULE),
	?assert(SingleThreadTime > 1.5 * MultiThreadTime,
		lists:flatten(io_lib:format(
			"Multi-thread time (~p) not twice as fast as single-thread time (~p)",
			[MultiThreadTime, SingleThreadTime]))).	

test_partitions() ->
	Candidate = default_candidate(),
	MiningAddress = Candidate#mining_candidate.mining_address,
	Packing = {spora_2_6, MiningAddress},

	ar_mining_io:reset(make_ref(), 0),
	?assertEqual([
			{0, MiningAddress, ar_storage_module:id({?PARTITION_SIZE, 0, Packing})}],
		ar_mining_io:get_partitions()),

	ar_mining_io:reset(make_ref(), ?PARTITION_SIZE),
	?assertEqual([
			{0, MiningAddress, ar_storage_module:id({?PARTITION_SIZE, 0, Packing})}],
		ar_mining_io:get_partitions()),

	ar_mining_io:reset(make_ref(), trunc(2.5 * ?PARTITION_SIZE)),
	?assertEqual([
			{0, MiningAddress, ar_storage_module:id({?PARTITION_SIZE, 0, Packing})},
			{1, MiningAddress, ar_storage_module:id({?PARTITION_SIZE, 1, Packing})}],
		ar_mining_io:get_partitions()),

	ar_mining_io:reset(make_ref(), trunc(5 * ?PARTITION_SIZE)),
	?assertEqual([
			{0, MiningAddress, ar_storage_module:id({?PARTITION_SIZE, 0, Packing})},
			{1, MiningAddress, ar_storage_module:id({?PARTITION_SIZE, 1, Packing})},
			{2, MiningAddress, ar_storage_module:id({?PARTITION_SIZE, 2, Packing})},
			{3, MiningAddress, ar_storage_module:id({?PARTITION_SIZE, 3, Packing})},
			{4, MiningAddress, ar_storage_module:id({?PARTITION_SIZE, 4, Packing})}],
		ar_mining_io:get_partitions()).

test_mining_session() ->
	Candidate = default_candidate(),
	SessionKey = make_session_key(),

	%% mining session: not set, candidate session: not set
	?assertEqual(true, ar_mining_io:read_recall_range(chunk1, Candidate, 0)),
	wait_for_io(2),
	[Chunk1, Chunk2] = get_recall_chunks(),
	assert_recall_chunks([{chunk1, 0, Chunk1, Candidate}, {chunk1, 1, Chunk2, Candidate}]),

	%% mining session: not set, candidate session: set
	Candidate2 = Candidate#mining_candidate{ session_key = SessionKey },
	?assertEqual(true, ar_mining_io:read_recall_range(chunk1, Candidate2, 0)),
	assert_no_io(),

	ar_mining_io:reset(SessionKey, ?WEAVE_SIZE),

	%% mining session: set, candidate session: set
	?assertEqual(true, ar_mining_io:read_recall_range(chunk1, Candidate2, 0)),
	wait_for_io(2),
	[Chunk1, Chunk2] = get_recall_chunks(),
	assert_recall_chunks([{chunk1, 0, Chunk1, Candidate2}, {chunk1, 1, Chunk2, Candidate2}]),

	%% mining session: set, candidate session: not set
	?assertEqual(true, ar_mining_io:read_recall_range(chunk1, Candidate, 0)),
	wait_for_io(2),
	[Chunk1, Chunk2] = get_recall_chunks(),
	assert_recall_chunks([{chunk1, 0, Chunk1, Candidate}, {chunk1, 1, Chunk2, Candidate}]),

	%% mining session: set, candidate session: set different
	Candidate3 = Candidate#mining_candidate{ session_key = make_session_key() },
	?assertEqual(true, ar_mining_io:read_recall_range(chunk1, Candidate3, 0)),
	assert_no_io().

make_session_key() ->
	{crypto:strong_rand_bytes(32), rand:uniform(100), rand:uniform(10000)}.

default_candidate() ->
	{ok, Config} = application:get_env(arweave, config),
	MiningAddr = Config#config.mining_addr,
	#mining_candidate{
		mining_address = MiningAddr
	}.

wait_for_io(NumChunks) ->
	Result = ar_util:do_until(
		fun() ->
			NumChunks == length(ets:tab2list(?MODULE))
		end,
		100,
		60000),
	?assertEqual(true, Result, "Timeout while waiting to read chunks").

assert_no_io() ->
	Result = ar_util:do_until(
		fun() ->
			length(ets:tab2list(?MODULE)) > 0
		end,
		100,
		5000),
	?assertEqual({error, timeout}, Result, "Unexpectedly read chunks").

get_recall_chunks() ->
	lists:map(fun({_, _, Chunk, _}) -> Chunk end, lists:sort(ets:tab2list(?MODULE))).
	
assert_recall_chunks(ExpectedChunks) ->
	?assertEqual(lists:sort(ExpectedChunks), lists:sort(ets:tab2list(?MODULE))),
	ets:delete_all_objects(?MODULE).
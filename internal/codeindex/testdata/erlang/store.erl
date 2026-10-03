%%% A key-value store.
-module(store).
-behaviour(gen_server).

-export([new/0, add/3, size/1]).

-define(MAX_SIZE, 64).
-define(is_key(K), is_binary(K)).

%% A stored entry.
-record(entry, {key :: binary(), value = 0 :: integer()}).

-type id() :: binary().
-opaque store() :: #{id() => term()}.

-callback init(Args :: term()) -> ok.

%% @doc Builds an empty store.
-spec new() -> store().
new() ->
    #{}.

%% @doc Adds a value under a key.
add(Store, Key, Value) when ?is_key(Key) ->
    Local = Key,
    Store#{Local => Value};
add(Store, _Key, _Value) ->
    Store.

% Counts the entries.
size(Store) ->
    Fun = fun(X) -> X end,
    maps:size(Fun(Store)).

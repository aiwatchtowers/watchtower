# A tiny Elixir fixture for the full grammar set.
defmodule Acme.Store do
  @moduledoc """
  A key-value store.

  Keeps entries in a map.
  """

  @max_size 64

  defstruct entries: %{}, name: nil

  @doc "Builds an empty store."
  def new, do: %__MODULE__{}

  @doc """
  Adds a value under a key.
  """
  @spec add(map(), term(), term()) :: map()
  def add(store, key, value) when is_map(store) do
    helper = fn x -> x end
    put_in(store.entries[key], helper.(value))
  end

  # A plain comment is not a doc.
  defp size(store), do: map_size(store.entries)

  defmacro twice(expr) do
    quote do: unquote(expr) * 2
  end

  defmodule Inner do
    @moduledoc false
    def assist, do: :ok
  end
end

defprotocol Acme.Storable do
  @doc "The key this value is stored under."
  def key(value)
end

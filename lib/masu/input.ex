defmodule Masu.Input do
  @moduledoc false
  # What the browser may send, checked where it comes in, so that no
  # source, store or query needs to check it again. Any person can craft
  # an event: a text with a NUL character is refused (PostgreSQL cannot
  # store one), and a text or a list over its bound is refused, never cut
  # short. Bounds are in bytes: `byte_size/1` takes no time, and it is a
  # real bound on the memory the text takes.

  # Every text of a query: the search, the search of a column's values,
  # the text of a filter value.
  @text 1_000
  @counts %{filters: 100, sorts: 100, groups: 100, values: 10_000}
  # A view's name is a `varchar(255)` in the table `mix masu.gen.views`
  # writes. PostgreSQL counts characters in it, never bytes, so a limit
  # of 255 bytes is never over it.
  @name 255
  # A row's id: a key of text (a UUID is 36 bytes) or a number.
  @id 1_000

  @list_ops [:in, :all_of, :none_of]

  @doc "Whether the text has a NUL character, or any text of the list or map has."
  @spec nul?(term()) :: boolean()
  def nul?(text) when is_binary(text), do: :binary.match(text, <<0>>) != :nomatch
  def nul?(list) when is_list(list), do: Enum.any?(list, &nul?/1)
  def nul?(map) when is_map(map) and not is_struct(map), do: Enum.any?(map, &nul?/1)
  def nul?({key, value}), do: nul?(key) or nul?(value)
  def nul?(_other), do: false

  @doc """
  Whether a row's id from the browser may be one: a number, or a text
  within its bound and without a NUL. A grid sends its rows' ids as one
  or the other (`Masu.Value.to_wire/1`).
  """
  @spec id?(term()) :: boolean()
  def id?(id) when is_number(id), do: true
  def id?(id) when is_binary(id), do: byte_size(id) <= @id and not nul?(id)
  def id?(_other), do: false

  @doc "Checks a text. What is not a text is not checked."
  @spec text(term(), String.t(), pos_integer()) :: :ok | {:error, String.t()}
  def text(text, what, limit \\ @text)

  def text(text, what, limit) when is_binary(text) do
    cond do
      byte_size(text) > limit -> {:error, "#{what} is longer than #{number(limit)} bytes"}
      nul?(text) -> {:error, nul_message(what)}
      true -> :ok
    end
  end

  def text(_other, _what, _limit), do: :ok

  @doc "The message of a text with a NUL character."
  @spec nul_message(String.t()) :: String.t()
  def nul_message(what), do: "#{what} has a NUL character"

  @doc "Checks the search of a grid, or of a column's values."
  @spec search(term()) :: :ok | {:error, String.t()}
  def search(text), do: text(text, "the search")

  @doc "Checks a view's name."
  @spec name(term()) :: :ok | {:error, String.t()}
  def name(name), do: text(name, "A view's name", @name)

  @doc """
  Checks the value of a filter: its text, or each text of a list, and the
  number of values of a list filter.
  """
  @spec filter_value(atom(), term()) :: :ok | {:error, String.t()}
  def filter_value(op, values) when is_list(values) do
    with :ok <- if(op in @list_ops, do: count(values, :values), else: :ok) do
      values |> Enum.map(&text(&1, "a filter value")) |> Enum.find(:ok, &(&1 != :ok))
    end
  end

  def filter_value(_op, value), do: text(value, "a filter value")

  @doc """
  Checks how many filters, sorts, groups or values a list (or the map of
  indexes a URL makes of one) has, as it was sent.
  """
  @spec count(term(), :filters | :sorts | :groups | :values) :: :ok | {:error, String.t()}
  def count(items, kind) when is_list(items) or is_map(items) do
    limit = Map.fetch!(@counts, kind)
    size = if is_map(items), do: map_size(items), else: length(items)
    if size > limit, do: {:error, "more than #{number(limit)} #{kind}"}, else: :ok
  end

  def count(_other, _kind), do: :ok

  # 10000 as "10,000".
  defp number(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end

defmodule Masu.Source.List do
  @moduledoc """
  The source of a grid given its rows: `<.data_grid rows={@users}>`.

  The rows are maps or structs. The list filters, searches and sorts them
  in the LiveView's process when the query changes, once, and keeps the
  result as a tuple, so each block the browser asks for is read without
  walking the list. Sorting a hundred thousand rows takes a fraction of a
  second; past that, give the grid an Ecto source and let the database do
  it.

  Text sorts without case, `nil` after every value, and rows that compare
  equal keep their order in the list.
  """

  @behaviour Masu.Source

  alias Masu.{Column, Filter, Query, Value}

  @impl true
  def init(rows, _opts) when is_list(rows) do
    %{all: rows, view: List.to_tuple(rows)}
  end

  @impl true
  def prepare(%{all: rows} = state, %Query{} = query, columns) do
    view =
      rows
      |> filter(query.filters, columns)
      |> search(query.search, columns)
      |> sort(query.sorts, columns)
      |> List.to_tuple()

    %{state | view: view}
  end

  @impl true
  def count(%{view: view}), do: tuple_size(view)

  @impl true
  def rows(%{view: view}, offset, limit) do
    last = min(offset + limit, tuple_size(view)) - 1
    if offset > last, do: [], else: for(i <- offset..last//1, do: elem(view, i))
  end

  @impl true
  def supports?(_state, _column), do: true

  defp filter(rows, [], _columns), do: rows

  defp filter(rows, filters, columns) do
    checks =
      for %Filter{key: key} = filter <- filters,
          column = Column.find(columns, key),
          do: {column, filter}

    Enum.filter(rows, fn row ->
      Enum.all?(checks, fn {column, filter} -> Filter.match?(filter, Column.get(column, row)) end)
    end)
  end

  defp search(rows, nil, _columns), do: rows

  defp search(rows, text, columns) do
    text = String.downcase(text)
    searchable = Enum.filter(columns, & &1.searchable)

    Enum.filter(rows, fn row -> Enum.any?(searchable, &has_text?(&1, row, text)) end)
  end

  defp has_text?(column, row, text) do
    case Column.get(column, row) do
      nil ->
        false

      value ->
        value |> Value.to_wire() |> to_string() |> String.downcase() |> String.contains?(text)
    end
  end

  defp sort(rows, [], _columns), do: rows

  # One key per row and sort, made once: terms that Erlang compares in
  # the order of `Masu.Value.compare/2`, so that sorting is a stable
  # `Enum.sort_by/3` for each sort, from the last to the first.
  defp sort(rows, sorts, columns) do
    keyed =
      for sort <- sorts, column = Column.find(columns, sort.key) do
        values = Enum.map(rows, &Column.get(column, &1))
        {Enum.map(values, Value.sort_key_fun(values)), sort.direction}
      end

    pairs = Enum.zip([rows | Enum.map(keyed, &elem(&1, 0))]) |> Enum.map(&Tuple.to_list/1)
    directions = Enum.map(keyed, &elem(&1, 1))

    directions
    |> Enum.with_index(1)
    |> Enum.reverse()
    |> Enum.reduce(pairs, fn {direction, i}, pairs ->
      Enum.sort_by(pairs, &nil_last(Enum.at(&1, i), direction), direction)
    end)
    |> Enum.map(&hd/1)
  end

  # nil after every value, in both directions. The tuples have one size:
  # Erlang compares tuples by their size first.
  defp nil_last(nil, :asc), do: {1, nil}
  defp nil_last(key, :asc), do: {0, key}
  defp nil_last(nil, :desc), do: {0, nil}
  defp nil_last(key, :desc), do: {1, key}
end

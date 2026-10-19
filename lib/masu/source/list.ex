defmodule Masu.Source.List do
  @moduledoc """
  The source of a grid given its rows: `<.data_grid rows={@users}>`.

  The rows are maps or structs. The list filters, searches and sorts them
  in the LiveView's process when the query changes, once, and keeps the
  result as a tuple, so each block the browser asks for is read without
  walking the list. A search makes a text of each row at the first
  search, and keeps it until the rows change.

  A list is for up to about 10,000 rows, which it sorts and searches in
  tens of milliseconds. Each LiveView holds its rows, and at 100,000 a
  sort takes about 0.4 seconds; past 10,000, give the grid an Ecto source
  and let the database do it (see the Known limits guide).

  Text sorts without case, `nil` after every value, and rows that compare
  equal keep their order in the list.

  ## A tree

  With the grid's `tree` (a field of the row that holds its parent's id,
  or a function of the row), the rows are a tree (`Masu.Tree`): the list
  holds every row, and the grid shows the roots and the children of the
  rows that are open.
  """

  @behaviour Masu.Source

  alias Masu.{Column, Filter, Group, Query, Tree, Value}

  @impl true
  def init(rows, opts) when is_list(rows) do
    %{
      all: rows,
      view: List.to_tuple(rows),
      tree: Keyword.get(opts, :tree),
      row_id: Keyword.get(opts, :row_id) || (&Map.get(&1, :id)),
      nodes: nil,
      flat: [],
      segments: nil,
      leaves: %{},
      groups: [],
      totals: %{},
      search_texts: nil
    }
  end

  @impl true
  def prepare(%{tree: parent} = state, %Query{} = query, columns) when parent != nil do
    id = fn row -> Value.to_wire(state.row_id.(row)) end
    parent_id = fn row -> Value.to_wire(parent_of(parent, row)) end
    sorted = sort(state.all, query.sorts, columns)

    # A filter or a search keeps the rows that match and their
    # ancestors, open unless the person closed them.
    {{rows, open?}, state} =
      if query.filters == [] and query.search == nil do
        {{sorted, &MapSet.member?(query.expanded, &1)}, state}
      else
        parents = Map.new(state.all, &{id.(&1), parent_id.(&1)})
        {found, state} = found(state, query, columns)

        kept =
          found
          |> Enum.map(id)
          |> Tree.with_ancestors(&Map.get(parents, &1))

        {{Enum.filter(sorted, &MapSet.member?(kept, id.(&1))),
          &(not MapSet.member?(query.collapsed, &1))}, state}
      end

    by_id = Map.new(rows, &{id.(&1), &1})
    flat = rows |> Enum.map(&{id.(&1), parent_id.(&1)}) |> Tree.flatten(open?)

    %{
      state
      | view: flat |> Enum.map(&Map.fetch!(by_id, elem(&1, 0))) |> List.to_tuple(),
        nodes: flat |> Enum.map(&elem(&1, 2)) |> List.to_tuple(),
        flat: flat,
        totals: Group.aggregates(rows, columns)
    }
  end

  # Grouped (Masu.Group): the groups of each level that shows, and the
  # rows of each open group, in the LiveView.
  def prepare(state, %Query{groups: [_ | _] = keys} = query, columns) do
    {found, state} = found(state, query, columns)
    sorted = sort(found, query.sorts, columns)

    groups = fn path, key ->
      sorted
      |> Enum.filter(&in_path?(&1, path, columns))
      |> Group.of_rows(Column.find(columns, key), path, columns, query.sorts)
    end

    segments = Group.segments(keys, &Group.open?(query, &1), groups)

    leaves =
      for {:rows, path, _count, _level} <- segments, into: %{} do
        {path, sorted |> Enum.filter(&in_path?(&1, path, columns)) |> List.to_tuple()}
      end

    %{
      state
      | segments: segments,
        leaves: leaves,
        groups: Enum.map(keys, &Column.find(columns, &1)),
        totals: Group.aggregates(found, columns)
    }
  end

  def prepare(state, %Query{} = query, columns) do
    {found, state} = found(state, query, columns)
    view = found |> sort(query.sorts, columns) |> List.to_tuple()
    %{state | view: view, segments: nil, totals: Group.aggregates(found, columns)}
  end

  defp in_path?(row, path, columns),
    do:
      Enum.all?(path, fn {key, value} -> Column.get(Column.find(columns, key), row) == value end)

  @impl true
  def totals(%{totals: totals}), do: totals

  @impl true
  def select_all(state, query, columns, except, row_id) do
    except = MapSet.new(except)
    {found, _state} = found(state, query, columns)

    ids =
      for row <- found,
          id = Value.to_wire(row_id.(row)),
          not MapSet.member?(except, id),
          do: id

    {:ids, ids}
  end

  @impl true
  def count(%{segments: [_ | _] = segments}), do: Group.count(segments)
  def count(%{segments: []}), do: 0
  def count(%{view: view}), do: tuple_size(view)

  @impl true
  def rows(%{segments: segments} = state, offset, limit) when is_list(segments),
    do: state |> nodes(offset, limit) |> Enum.map(&elem(&1, 0))

  def rows(%{view: view}, offset, limit), do: slice(view, offset, limit)

  defp slice(tuple, offset, limit) do
    last = min(offset + limit, tuple_size(tuple)) - 1
    if offset > last, do: [], else: for(i <- offset..last//1, do: elem(tuple, i))
  end

  @impl true
  def nodes(%{segments: segments, leaves: leaves}, offset, limit) when is_list(segments) do
    Group.slice(segments, offset, limit, &slice(Map.fetch!(leaves, &1), &2, &3))
  end

  def nodes(%{nodes: nil}, _offset, _limit), do: nil

  def nodes(%{nodes: nodes} = state, offset, limit) do
    last = min(offset + limit, tuple_size(nodes)) - 1
    rows = rows(state, offset, limit)
    if offset > last, do: [], else: Enum.zip(rows, for(i <- offset..last//1, do: elem(nodes, i)))
  end

  @impl true
  def siblings(%{segments: segments}, id) when is_list(segments), do: Group.siblings(segments, id)
  def siblings(%{flat: flat}, id), do: Tree.siblings(flat, id)

  defp parent_of(field, row) when is_atom(field), do: Map.get(row, field)
  defp parent_of(fun, row) when is_function(fun, 1), do: fun.(row)

  @impl true
  def supports?(_state, _column), do: true

  # A path is of many values when it reads a list in a row: it goes
  # through several related rows.
  @impl true
  def many?(%{all: rows}, column), do: Enum.any?(rows, &is_list(Column.get(column, &1)))

  @impl true
  def values(state, column, query, columns, opts) do
    search = opts |> Keyword.get(:search) |> then(&(&1 && String.downcase(&1)))
    {found, _state} = found(state, query, columns)

    found
    |> frequencies(column)
    |> Enum.filter(fn {value, _count} -> search == nil or value_has?(value, search) end)
    |> Enum.sort_by(fn {value, count} -> {-count, Value.sort_key_fun([value]).(value)} end)
    |> Enum.take(Keyword.get(opts, :limit, 50))
  end

  # Of many values: the rows that have each value.
  defp frequencies(rows, %Column{many: true} = column),
    do: rows |> Enum.flat_map(&Enum.uniq(List.wrap(Column.get(column, &1)))) |> Enum.frequencies()

  defp frequencies(rows, column), do: Enum.frequencies_by(rows, &Column.get(column, &1))

  defp value_has?(nil, _search), do: false

  defp value_has?(value, search),
    do: value |> Value.to_wire() |> to_string() |> String.downcase() |> String.contains?(search)

  @impl true
  def fetch(%{all: rows}, ids, row_id) do
    wanted = MapSet.new(ids)
    Enum.filter(rows, &MapSet.member?(wanted, Value.to_wire(row_id.(&1))))
  end

  @impl true
  def locate(%{segments: segments} = state, id, row_id) when is_list(segments) do
    # The row's place among the rows of its group, if its group is open.
    Enum.find_value(state.leaves, fn {path, rows} ->
      local =
        Enum.find(0..(tuple_size(rows) - 1)//1, &(Value.to_wire(row_id.(elem(rows, &1))) == id))

      local && Group.index(segments, path, local)
    end)
  end

  def locate(%{view: view}, id, row_id) do
    Enum.find(0..(tuple_size(view) - 1)//1, &(Value.to_wire(row_id.(elem(view, &1))) == id))
  end

  # A changed row takes the place of the row with its id, a new one goes
  # at the end, and a deleted one leaves.
  @impl true
  def change(%{all: rows} = state, changes, row_id) do
    rows = Enum.reduce(changes, rows, &apply_change(&1, &2, row_id))
    %{state | all: rows, search_texts: nil}
  end

  defp apply_change({:upsert, row}, rows, row_id) do
    id = row_id.(row)

    case Enum.find_index(rows, &(row_id.(&1) == id)) do
      nil -> rows ++ [row]
      index -> List.replace_at(rows, index, row)
    end
  end

  defp apply_change({:delete, row_or_id}, rows, row_id) do
    id = if is_map(row_or_id), do: row_id.(row_or_id), else: row_or_id
    Enum.reject(rows, &(row_id.(&1) == id))
  end

  @doc false
  # Deleted rows back in their places (an undo): `{index, row}`, by the
  # places they had, first to last.
  @spec reinsert(map(), [{non_neg_integer(), term()}]) :: map()
  def reinsert(%{all: rows} = state, placed) do
    rows =
      placed
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce(rows, fn {index, row}, rows -> List.insert_at(rows, index, row) end)

    %{state | all: rows, search_texts: nil}
  end

  @doc false
  # The places of rows in the list, by their ids, before they leave it.
  @spec places(map(), [term()], (term() -> term())) :: %{term() => non_neg_integer()}
  def places(%{all: rows}, ids, row_id) do
    wanted = MapSet.new(ids)

    for {row, index} <- Enum.with_index(rows),
        id = Masu.Value.to_wire(row_id.(row)),
        MapSet.member?(wanted, id),
        into: %{},
        do: {id, index}
  end

  # The rows of the query's filters and search, in their order, and the
  # state with the rows' search texts.
  defp found(state, %Query{search: nil, filters: []}, _columns), do: {state.all, state}

  defp found(state, %Query{search: nil} = query, columns),
    do: {Enum.filter(state.all, filter(query.filters, columns)), state}

  defp found(state, query, columns) do
    if String.contains?(query.search, <<0>>), do: {[], state}, else: search(state, query, columns)
  end

  defp search(state, query, columns) do
    state = with_search_texts(state, columns)
    {_key, texts} = state.search_texts
    text = String.downcase(query.search)
    {matching(state.all, texts, text, filter(query.filters, columns), []), state}
  end

  defp matching([row | rows], [row_text | texts], text, keep?, acc) do
    acc =
      if :binary.match(row_text, text) != :nomatch and keep?.(row), do: [row | acc], else: acc

    matching(rows, texts, text, keep?, acc)
  end

  defp matching([], [], _text, _keep?, acc), do: Enum.reverse(acc)

  # The search text of each row: its searchable values without case,
  # apart (a NUL between two), made at the first search and kept until
  # the rows or the searchable columns change. A search is then a match
  # in a binary a row, not a conversion of each value: of a decimal, a
  # date. A search for text with a NUL finds no row, as no value has one
  # that a person types.
  defp with_search_texts(state, columns) do
    searchable = Enum.filter(columns, & &1.searchable)
    key = Enum.map(searchable, &{&1.key, &1.field, &1.value})

    case state.search_texts do
      {^key, _texts} ->
        state

      _other ->
        texts =
          Enum.map(state.all, fn row -> Enum.map_join(searchable, <<0>>, &text(&1, row)) end)

        %{state | search_texts: {key, texts}}
    end
  end

  defp text(%Column{many: true} = column, row),
    do: column |> Column.get(row) |> List.wrap() |> Enum.map_join(" ", &text_of/1)

  defp text(column, row), do: text_of(Column.get(column, row))

  defp text_of(nil), do: ""
  defp text_of(value), do: value |> Value.to_wire() |> to_string() |> String.downcase()

  # Whether a row passes the filters.
  defp filter([], _columns), do: fn _row -> true end

  defp filter(filters, columns) do
    checks =
      for %Filter{key: key} = filter <- filters,
          column = Column.find(columns, key),
          do: {column, filter}

    fn row -> Enum.all?(checks, fn {column, filter} -> passes?(filter, column, row) end) end
  end

  defp passes?(filter, %Column{many: true} = column, row),
    do: Filter.match_many?(filter, Column.get(column, row))

  defp passes?(filter, column, row), do: Filter.match?(filter, Column.get(column, row))

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

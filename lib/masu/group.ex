defmodule Masu.Group do
  @moduledoc """
  Rows grouped by the values of columns, with totals.

      <.data_grid id="orders" source={Order} repo={Repo} group_by={[:status]}>
        <:col field={:status} type={:enum} />
        <:col field={:customer} />
        <:col field={:total} type={:decimal} aggregate={:sum} />
      </.data_grid>

  `group_by` names the columns the rows are grouped by, the first the
  outermost. Each group is a row of its own, with its value, how many
  rows it has, and the totals of the columns that have an `aggregate`
  (see `Masu.Column`); it opens on its groups of the next column, or on
  its rows. A person groups by a column from its header menu, and the
  grouping is part of their view (`Masu.View`).

  A row of totals of the whole query shows at the bottom of a grid with a
  column that has an `aggregate`, grouped or not.

  The groups are counted and totalled by the source: an Ecto source with
  one `GROUP BY` for each level that shows, and reads the rows of an open
  group a block at a time, as it reads any rows; a list in the LiveView.
  So a million rows in forty groups are forty rows until one opens.

  Groups sort by their value; sorting by the grouped column turns their
  order, and sorting by a column with an aggregate sorts them by it. The
  rows of a group sort as the grid's rows do.

  A group row's id is `["masu-group", key, value, ...]`, its path: it is
  what `Masu.Test.expand/3` takes to open it.
  """

  alias Masu.{Column, Sort, Value}

  @type t :: %__MODULE__{
          key: String.t(),
          value: term(),
          count: non_neg_integer(),
          aggregates: %{String.t() => term()},
          path: [{String.t(), term()}]
        }

  defstruct [:key, :value, :count, aggregates: %{}, path: []]

  @typedoc false
  # What a grouped grid shows, in order: a group's row, or the rows of an
  # open group (`count` of them, read when they show).
  @type segment ::
          {:group, t(), map()}
          | {:rows, [{String.t(), term()}], non_neg_integer(), non_neg_integer()}

  @doc false
  # A group row's id, as the browser has it: its path.
  @spec id(t()) :: list()
  def id(%__MODULE__{path: path}),
    do: ["masu-group" | Enum.flat_map(path, fn {key, value} -> [key, Value.to_wire(value)] end)]

  @doc false
  @spec id?(term()) :: boolean()
  def id?(["masu-group" | _]), do: true
  def id?(_id), do: false

  @doc false
  # The segments of the groups by `levels` (keys), the open ones (by
  # `open?` of their id) on their next level or their rows. `groups`
  # gives the groups of a key under a path, in order.
  @spec segments([String.t()], (list() -> boolean()), (list(), String.t() -> [t()])) :: [
          segment()
        ]
  def segments(levels, open?, groups), do: build([], levels, 0, open?, groups)

  defp build(_path, [], _level, _open?, _groups), do: []

  defp build(path, [key | rest], level, open?, groups) do
    found = groups.(path, key)
    size = length(found)

    found
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {group, position} ->
      expanded = open?.(id(group))
      info = %{level: level, children: true, expanded: expanded, position: position, size: size}
      row = {:group, group, info}

      cond do
        not expanded -> [row]
        rest == [] -> [row, {:rows, group.path, group.count, level + 1}]
        true -> [row | build(group.path, rest, level + 1, open?, groups)]
      end
    end)
  end

  @doc false
  @spec count([segment()]) :: non_neg_integer()
  def count(segments), do: Enum.reduce(segments, 0, &(&2 + length_of(&1)))

  defp length_of({:group, _group, _info}), do: 1
  defp length_of({:rows, _path, count, _level}), do: count

  @doc false
  # The rows from `offset` (group rows and rows of open groups), each with
  # its place (`Masu.Tree.node_info()`). `leaves` reads the rows of a
  # group's path from an offset.
  @spec slice([segment()], non_neg_integer(), pos_integer(), (list(),
                                                              non_neg_integer(),
                                                              pos_integer() ->
                                                                [term()])) ::
          [{term(), map()}]
  def slice(segments, offset, limit, leaves) do
    {_pos, _taken, acc} =
      Enum.reduce_while(segments, {0, 0, []}, fn segment, {pos, taken, acc} ->
        len = length_of(segment)

        cond do
          taken >= limit -> {:halt, {pos, taken, acc}}
          pos + len <= offset -> {:cont, {pos + len, taken, acc}}
          true -> {:cont, take(segment, pos, offset, limit - taken, leaves, acc, taken)}
        end
      end)

    Enum.reverse(acc)
  end

  defp take({:group, group, info}, pos, _offset, _want, _leaves, acc, taken),
    do: {pos + 1, taken + 1, [{group, info} | acc]}

  defp take({:rows, path, count, level}, pos, offset, want, leaves, acc, taken) do
    from = max(offset - pos, 0)
    rows = leaves.(path, from, min(want, count - from))

    items =
      rows
      |> Enum.with_index(from + 1)
      |> Enum.map(fn {row, position} ->
        {row, %{level: level, children: false, expanded: false, position: position, size: count}}
      end)

    {pos + count, taken + length(items), Enum.reverse(items, acc)}
  end

  @doc false
  # The ids of the groups beside the group `id` (`*`).
  @spec siblings([segment()], list()) :: [list()]
  def siblings(segments, id) do
    groups = for {:group, group, _info} <- segments, do: group

    case Enum.find(groups, &(id(&1) == id)) do
      nil -> []
      group -> for g <- groups, Enum.drop(g.path, -1) == Enum.drop(group.path, -1), do: id(g)
    end
  end

  @doc false
  # The place of a row among the segments (its index), given the path of
  # its groups and its index among the rows of its group.
  @spec index([segment()], [{String.t(), term()}], non_neg_integer()) :: non_neg_integer() | nil
  def index(segments, path, local) do
    Enum.reduce_while(segments, 0, fn
      {:rows, ^path, count, _level}, pos when local < count -> {:halt, {:found, pos + local}}
      segment, pos -> {:cont, pos + length_of(segment)}
    end)
    |> case do
      {:found, index} -> index
      _pos -> nil
    end
  end

  @doc false
  # The groups of rows by a column, with their counts and totals, in the
  # order of `order/4`: what a list groups in the LiveView.
  @spec of_rows([term()], Column.t(), [{String.t(), term()}], [Column.t()], [Sort.t()]) :: [t()]
  def of_rows(rows, %Column{key: key} = column, path, columns, sorts) do
    rows
    |> Enum.group_by(&Column.get(column, &1))
    |> Enum.map(fn {value, members} ->
      %__MODULE__{
        key: key,
        value: value,
        count: length(members),
        aggregates: aggregates(members, columns),
        path: path ++ [{key, value}]
      }
    end)
    |> order(key, sorts, columns)
  end

  @doc false
  # Groups in their order: by their value, turned by a sort on their
  # column; by an aggregate when the first sort is on a column with one.
  @spec order([t()], String.t(), [Sort.t()], [Column.t()]) :: [t()]
  def order(groups, key, sorts, columns) do
    {by, direction} =
      case sorts do
        [%Sort{key: ^key, direction: direction} | _] ->
          {& &1.value, direction}

        [%Sort{key: sort_key, direction: direction} | _] ->
          case Column.find(columns, sort_key) do
            %Column{aggregate: aggregate} when aggregate != nil ->
              {&Map.get(&1.aggregates, sort_key), direction}

            _other ->
              by_value(sorts, key)
          end

        [] ->
          {& &1.value, :asc}
      end

    values = Enum.map(groups, by)
    key_of = Value.sort_key_fun(values)

    groups
    |> Enum.zip(values)
    |> Enum.sort_by(fn {_group, value} -> nil_last(key_of.(value), direction) end, direction)
    |> Enum.map(&elem(&1, 0))
  end

  defp by_value(sorts, key) do
    case Enum.find(sorts, &(&1.key == key)) do
      %Sort{direction: direction} -> {& &1.value, direction}
      nil -> {& &1.value, :asc}
    end
  end

  defp nil_last(nil, :asc), do: {1, nil}
  defp nil_last(key, :asc), do: {0, key}
  defp nil_last(nil, :desc), do: {0, nil}
  defp nil_last(key, :desc), do: {1, key}

  @doc false
  # The totals of the columns with an aggregate, over rows in the LiveView.
  @spec aggregates([term()], [Column.t()]) :: %{String.t() => term()}
  def aggregates(rows, columns) do
    for %Column{aggregate: aggregate, key: key} = column <- columns,
        aggregate != nil,
        into: %{} do
      {key, aggregate(aggregate, rows, column)}
    end
  end

  defp aggregate(fun, rows, _column) when is_function(fun, 1), do: fun.(rows)

  defp aggregate(kind, rows, column) do
    values = rows |> Enum.map(&Column.get(column, &1)) |> Enum.reject(&is_nil/1)
    compute(kind, values)
  end

  defp compute(:count, values), do: length(values)
  defp compute(:count_distinct, values), do: values |> Enum.uniq() |> length()
  defp compute(_kind, []), do: nil
  defp compute(:sum, values), do: sum(values)
  defp compute(:avg, values), do: divide(sum(values), length(values))
  defp compute(:min, values), do: Enum.min(values, &(Value.compare(&1, &2) != :gt))
  defp compute(:max, values), do: Enum.max(values, &(Value.compare(&1, &2) != :lt))

  # Decimals add up exactly.
  defp sum(values) do
    if Enum.any?(values, &decimal?/1),
      do: Enum.reduce(values, Decimal.new(0), &Decimal.add(&2, to_decimal(&1))),
      else: Enum.sum(values)
  end

  defp divide(%{__struct__: Decimal} = sum, count), do: sum |> Decimal.div(count) |> average()
  defp divide(sum, count), do: sum / count

  @doc false
  # An average of decimals, to six places at most (a division by 9,412
  # has 28 digits).
  @spec average(term()) :: term()
  def average(%{__struct__: Decimal} = average),
    do: average |> Decimal.round(6) |> Decimal.normalize()

  def average(other), do: other

  defp decimal?(%{__struct__: Decimal}), do: true
  defp decimal?(_value), do: false

  defp to_decimal(%{__struct__: Decimal} = decimal), do: decimal
  defp to_decimal(int) when is_integer(int), do: Decimal.new(int)
  defp to_decimal(float) when is_float(float), do: Decimal.from_float(float)
end

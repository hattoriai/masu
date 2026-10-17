defmodule Masu.View do
  @moduledoc """
  A person's view of a grid: its query (`Masu.Query`: order, filters and
  search) and its layout (`Masu.Layout`: the order, visibility, pins and
  widths of its columns).

  A view goes into the URL and into a store (`Masu.Views`) as params: a
  map of strings, with only what differs from the grid's own view (the
  one of its attributes), so that a link stays short and a saved view
  takes the grid's later defaults for what it does not change.

      %{
        "sort" => "-revenue,name",
        "q" => "acme",
        "group" => "plan",
        "filter" => %{"0" => %{"key" => "plan", "op" => "in", "value" => ["team"]}},
        "cols" => "id,name,plan,city,revenue",
        "hide" => "seats",
        "pin" => "id:start,revenue:end",
        "w" => "name:220",
        "page" => "3"
      }

  `"page"` is the page of a grid with `paging={:pages}`, from 1.

  Each part that is given replaces the grid's: `"sort" => ""` is no order,
  `"hide" => ""` hides no column, `"filter" => ""` has no filter.
  """

  alias Masu.{Column, Filter, Layout, Query, Sort}

  @type t :: %__MODULE__{query: Query.t(), layout: Layout.t(), page: non_neg_integer()}

  defstruct query: %Query{}, layout: %Layout{}, page: 0

  @doc """
  The params of a view: what differs from the grid's own view
  (`default`).
  """
  @spec to_params(t(), t()) :: %{String.t() => term()}
  def to_params(%__MODULE__{query: query, layout: layout} = view, %__MODULE__{} = default) do
    %{query: dq, layout: dl} = default

    []
    |> put_if(view.page != default.page, "page", fn -> Integer.to_string(view.page + 1) end)
    |> put_if(query.sorts != dq.sorts, "sort", fn -> Enum.map_join(query.sorts, ",", &sort/1) end)
    |> put_if(query.search != dq.search, "q", fn -> query.search || "" end)
    |> put_if(query.filters != dq.filters, "filter", fn -> filters(query.filters) end)
    |> put_if(query.groups != dq.groups, "group", fn -> Enum.join(query.groups, ",") end)
    |> put_if(layout.order != dl.order, "cols", fn -> Enum.join(layout.order, ",") end)
    |> put_if(Enum.sort(layout.hidden) != Enum.sort(dl.hidden), "hide", fn ->
      layout.hidden |> Enum.sort() |> Enum.join(",")
    end)
    |> put_if(layout.pinned != dl.pinned, "pin", fn -> pairs(layout.pinned) end)
    |> put_if(layout.widths != dl.widths, "w", fn -> pairs(layout.widths) end)
    |> Map.new()
  end

  defp put_if(params, false, _key, _fun), do: params
  defp put_if(params, true, key, fun), do: [{key, fun.()} | params]

  defp sort(%Sort{key: key, direction: :asc}), do: key
  defp sort(%Sort{key: key, direction: :desc}), do: "-" <> key

  defp filters([]), do: ""

  defp filters(filters) do
    filters
    |> Enum.with_index()
    |> Map.new(fn {filter, i} ->
      wire = Filter.to_wire(filter)
      {Integer.to_string(i), if(is_nil(wire["value"]), do: Map.delete(wire, "value"), else: wire)}
    end)
  end

  defp pairs(map) do
    map
    |> Enum.sort()
    |> Enum.map_join(",", fn {key, value} -> "#{key}:#{value}" end)
  end

  @doc """
  The view of params, over the grid's own view (`default`), checked
  against the grid's columns (all of them, hidden ones too).

  A part that no longer applies (a column that was removed or no longer
  sorts or filters, a filter value that no longer reads) is left out, and
  its column's key is in the list it gives, so that the grid can say so:
  a link or a saved view never fails a grid.
  """
  @spec from_params(map(), [Column.t()], t()) :: {t(), [String.t()]}
  def from_params(params, columns, %__MODULE__{} = default) when is_map(params) do
    {sorts, dropped_sorts} = read_sorts(params["sort"], columns, default.query.sorts)
    {filters, dropped_filters} = read_filters(params["filter"], columns, default.query.filters)

    search = read_search(params["q"], default.query.search)
    keys = MapSet.new(columns, & &1.key)

    layout =
      default.layout
      |> Layout.change(
        %{
          "order" => split(params["cols"]),
          "hidden" => split(params["hide"])
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new(),
        columns
      )
      |> then(fn layout ->
        case read_pairs(params["pin"]) do
          nil -> layout
          pins -> %{layout | pinned: Layout.pins(pins, keys)}
        end
      end)
      |> then(fn layout ->
        case read_pairs(params["w"]) do
          nil -> layout
          widths -> %{layout | widths: Layout.widths(integers(widths), keys)}
        end
      end)
      |> Layout.fit(columns)

    groups = read_groups(params["group"], columns, default.query.groups)

    view = %__MODULE__{
      query: %Query{sorts: sorts, filters: filters, search: search, groups: groups},
      layout: layout,
      page: read_page(params["page"], default.page)
    }

    {view, Enum.uniq(dropped_sorts ++ dropped_filters)}
  end

  def from_params(_params, _columns, default), do: {default, []}

  defp read_page(page, default) when is_binary(page) do
    case Integer.parse(page) do
      {n, ""} when n >= 1 -> n - 1
      _other -> default
    end
  end

  defp read_page(_page, default), do: default

  defp read_search(q, _default) when is_binary(q),
    do: q |> String.trim() |> then(&if(&1 == "", do: nil, else: &1))

  defp read_search(_q, default), do: default

  defp read_groups(text, columns, _default) when is_binary(text),
    do: text |> String.split(",", trim: true) |> Query.groups(columns)

  defp read_groups(_text, _columns, default), do: default

  defp read_sorts(nil, _columns, default), do: {default, []}

  defp read_sorts(text, columns, _default) when is_binary(text) do
    text
    |> String.split(",", trim: true)
    |> Enum.map(fn
      "-" <> key -> Sort.new(key, :desc)
      key -> Sort.new(key, :asc)
    end)
    |> Enum.uniq_by(& &1.key)
    |> Enum.split_with(&match?(%Column{sortable: true}, Column.find(columns, &1.key)))
    |> then(fn {sorts, dropped} -> {sorts, Enum.map(dropped, & &1.key)} end)
  end

  defp read_sorts(_other, _columns, default), do: {default, []}

  defp read_filters(nil, _columns, default), do: {default, []}
  defp read_filters("", _columns, _default), do: {[], []}

  defp read_filters(filters, columns, default) when is_map(filters) do
    filters
    |> Enum.sort_by(fn {index, _filter} -> index |> Integer.parse() |> elem_or(0) end)
    |> Enum.map(fn {_index, filter} -> filter end)
    |> read_filters(columns, default)
  end

  defp read_filters(filters, columns, _default) when is_list(filters) do
    Enum.reduce(filters, {[], []}, fn filter, {ok, dropped} ->
      case read_filter(filter, columns) do
        {:ok, filter} -> {[filter | ok], dropped}
        {:error, key} -> {ok, [key | dropped]}
      end
    end)
    |> then(fn {ok, dropped} -> {Enum.reverse(ok), Enum.reverse(dropped)} end)
  end

  defp read_filters(_other, _columns, default), do: {default, []}

  defp read_filter(%{"key" => key, "op" => op} = filter, columns)
       when is_binary(key) and is_binary(op) do
    with op when op != nil <- Enum.find(Filter.ops(), &(Atom.to_string(&1) == op)),
         {:ok, filter} <- key |> Filter.new(op, filter["value"]) |> Filter.cast(columns) do
      {:ok, filter}
    else
      _error -> {:error, key}
    end
  end

  defp read_filter(_filter, _columns), do: {:error, "?"}

  defp elem_or({int, _rest}, _default), do: int
  defp elem_or(:error, default), do: default

  defp split(nil), do: nil
  defp split(text) when is_binary(text), do: String.split(text, ",", trim: true)
  defp split(_other), do: nil

  defp read_pairs(nil), do: nil

  defp read_pairs(text) when is_binary(text) do
    text
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn pair ->
      case String.split(pair, ":", parts: 2) do
        [key, value] -> [{key, value}]
        _other -> []
      end
    end)
    |> Map.new()
  end

  defp read_pairs(_other), do: nil

  defp integers(map) do
    for {key, value} <- map, {int, ""} <- [Integer.parse(value)], into: %{}, do: {key, int}
  end
end

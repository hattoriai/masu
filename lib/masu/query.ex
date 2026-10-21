defmodule Masu.Query do
  @moduledoc """
  What a person asked of a grid: its order, its filters and its search.

  A source (`Masu.Source`) gets the query with every key and value
  already checked against the grid's columns: each sort names a column
  that sorts, each filter a column that filters, with its value read for
  the column's type. `search` is text to find in the columns that are
  searchable, or `nil`.

  `groups` are the keys of the columns the rows are grouped by, the
  first the outermost (`Masu.Group`).

  In a tree (`Masu.Tree`), `expanded` holds the ids of the rows the
  person opened, and `collapsed` those they closed while a filter or a
  search shows every row it keeps open. Neither goes to the browser with
  the query, nor into a view's params.

  `open_groups` is what the grid's `expanded` gives a grouped grid: the
  keys of the columns whose groups start open, or `:all`. A group of
  such a column is open unless the person closed it (it is then in
  `collapsed`); any other group is closed unless they opened it (in
  `expanded`).

  A grid starts with the query of its `sort` and `filters` attributes,
  and changes it as the person sorts and searches. `Masu.Test` changes it
  the same way.
  """

  alias Masu.{Column, Filter, Input, Sort}

  @type t :: %__MODULE__{
          sorts: [Sort.t()],
          filters: [Filter.t()],
          search: String.t() | nil,
          groups: [String.t()],
          expanded: MapSet.t(),
          collapsed: MapSet.t(),
          open_groups: :all | [String.t()]
        }

  defstruct sorts: [],
            filters: [],
            search: nil,
            groups: [],
            expanded: MapSet.new(),
            collapsed: MapSet.new(),
            open_groups: []

  @doc """
  Makes a query from what the browser sends, and checks it against the
  columns: sorts `[%{"key" => key, "dir" => "asc" | "desc"}]`, filters
  `[%{"key" => key, "op" => op, "value" => value}]` and a `"search"`.

  The sorts on a column that does not sort, and the repeated ones, are
  left out. A filter that does not check is an error, so that a grid
  never shows rows the person did not ask for. So is a query with more
  than 100 sorts, filters or groups, a text over 1,000 bytes, a list
  filter of more than 10,000 values, and a text with a NUL character.
  """
  @spec from_wire(map(), [Column.t()]) :: {:ok, t()} | {:error, String.t()}
  def from_wire(params, columns) when is_map(params) do
    with :ok <- Input.count(params["sorts"], :sorts),
         :ok <- Input.count(params["filters"], :filters),
         :ok <- Input.count(params["groups"], :groups),
         :ok <- Input.search(params["search"]),
         {:ok, sorts} <- wire_sorts(Map.get(params, "sorts", []), columns),
         {:ok, filters} <- wire_filters(Map.get(params, "filters", []), columns) do
      {:ok,
       %__MODULE__{
         sorts: sorts,
         filters: filters,
         search: search(params["search"]),
         groups: groups(Map.get(params, "groups", []), columns)
       }}
    end
  end

  @doc false
  # The keys of the columns to group by: columns that sort, each once.
  @spec groups(term(), [Column.t()]) :: [String.t()]
  def groups(keys, columns) when is_list(keys) do
    keys
    |> Enum.map(&to_string/1)
    |> Enum.filter(&match?(%Column{sortable: true}, Column.find(columns, &1)))
    |> Enum.uniq()
  end

  def groups(_keys, _columns), do: []

  @doc """
  Makes a query from Elixir terms (the grid's attributes, or `Masu.Test`)
  and checks it the same way: `sort` is a list of keys, `{key, direction}`
  or `Masu.Sort` structs; `filters` a list of `Masu.Filter` structs or
  `{key, op, value}`.
  """
  @spec new(keyword(), [Column.t()]) :: {:ok, t()} | {:error, String.t()}
  def new(opts, columns) do
    sorts =
      opts
      |> Keyword.get(:sort, [])
      |> List.wrap()
      |> Enum.map(fn
        %Sort{} = sort -> sort
        {key, direction} -> Sort.new(key, direction)
        key -> Sort.new(key)
      end)

    filters =
      opts
      |> Keyword.get(:filters, [])
      |> Enum.map(fn
        %Filter{} = filter -> filter
        {key, op, value} -> Filter.new(key, op, value)
        {key, op} -> Filter.new(key, op)
      end)

    with {:ok, filters} <- cast_filters(filters, columns) do
      {:ok,
       %__MODULE__{
         sorts: check_sorts(sorts, columns),
         filters: filters,
         search: search(Keyword.get(opts, :search)),
         groups: opts |> Keyword.get(:group_by, []) |> List.wrap() |> groups(columns)
       }}
    end
  end

  @doc "The query as the browser gets it."
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = query) do
    %{
      "sorts" => Enum.map(query.sorts, &Sort.to_wire/1),
      "filters" => Enum.map(query.filters, &Filter.to_wire/1),
      "search" => query.search,
      "groups" => query.groups
    }
  end

  defp wire_sorts(sorts, columns) when is_list(sorts) do
    Enum.reduce_while(sorts, {:ok, []}, fn
      %{"key" => key, "dir" => dir}, {:ok, acc} when dir in ["asc", "desc"] and is_binary(key) ->
        {:cont, {:ok, [Sort.new(key, String.to_existing_atom(dir)) | acc]}}

      sort, _acc ->
        {:halt, {:error, Input.sentence("not a sort: #{inspect(sort)}")}}
    end)
    |> case do
      {:ok, sorts} -> {:ok, sorts |> Enum.reverse() |> check_sorts(columns)}
      error -> error
    end
  end

  defp wire_sorts(sorts, _columns),
    do: {:error, Input.sentence("not a list of sorts: #{inspect(sorts)}")}

  defp wire_filters(filters, columns) when is_list(filters) do
    filters
    |> Enum.reduce_while({:ok, []}, fn
      %{"key" => key, "op" => op} = filter, {:ok, acc} when is_binary(key) and is_binary(op) ->
        case op_from_wire(op) do
          {:ok, op} -> {:cont, {:ok, [Filter.new(key, op, filter["value"]) | acc]}}
          :error -> {:halt, {:error, Input.sentence("not a filter operator: #{inspect(op)}")}}
        end

      filter, _acc ->
        {:halt, {:error, Input.sentence("not a filter: #{inspect(filter)}")}}
    end)
    |> case do
      {:ok, filters} -> filters |> Enum.reverse() |> cast_filters(columns)
      error -> error
    end
  end

  defp wire_filters(filters, _columns),
    do: {:error, Input.sentence("not a list of filters: #{inspect(filters)}")}

  defp op_from_wire(op) do
    case Enum.find(Filter.ops(), &(Atom.to_string(&1) == op)) do
      nil -> :error
      op -> {:ok, op}
    end
  end

  defp cast_filters(filters, columns) do
    Enum.reduce_while(filters, {:ok, []}, fn filter, {:ok, acc} ->
      case Filter.cast(filter, columns) do
        {:ok, filter} -> {:cont, {:ok, [filter | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, filters} -> {:ok, Enum.reverse(filters)}
      error -> error
    end
  end

  @doc false
  # The query on other columns (the source's changed): the sorts, filters
  # and groups of the columns that are there still, and the keys of those
  # that are not.
  @spec fit(t(), [Column.t()]) :: {t(), [String.t()]}
  def fit(%__MODULE__{} = query, columns) do
    {filters, dropped} =
      Enum.reduce(query.filters, {[], []}, fn filter, {ok, dropped} ->
        case Filter.cast(filter, columns) do
          {:ok, filter} -> {[filter | ok], dropped}
          {:error, _reason} -> {ok, [filter.key | dropped]}
        end
      end)

    sorts = check_sorts(query.sorts, columns)
    groups = groups(query.groups, columns)

    dropped =
      Enum.reverse(dropped) ++
        Enum.map(query.sorts -- sorts, & &1.key) ++ (query.groups -- groups)

    {%{query | filters: Enum.reverse(filters), sorts: sorts, groups: groups}, Enum.uniq(dropped)}
  end

  defp check_sorts(sorts, columns) do
    sorts
    |> Enum.filter(fn %Sort{key: key} ->
      match?(%Column{sortable: true}, Column.find(columns, key))
    end)
    |> Enum.uniq_by(& &1.key)
  end

  defp search(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      text -> text
    end
  end

  defp search(_other), do: nil
end

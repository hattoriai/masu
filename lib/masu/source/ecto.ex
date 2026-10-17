if Code.ensure_loaded?(Ecto.Query) do
  defmodule Masu.Source.Ecto do
    @moduledoc """
    The source of a grid given an Ecto query or schema and a repo:
    `<.data_grid source={from(o in Order, where: o.shop_id == ^shop.id)} repo={Repo}>`.

    The database does the work. A sort is an `ORDER BY`, a filter and the
    search a `WHERE`, the count a `count(*)` of the query, and each block
    the browser asks for one `LIMIT` and `OFFSET`. The LiveView never holds
    more rows than the screen shows.

    The query may already have its own `where`, `join` and `preload`: the
    grid's filters are added to them. The grid's order replaces the
    query's while the person sorts, and the query's order is used when
    they do not. After the grid's order comes the schema's primary key, so
    that rows of equal values do not move from one block to the next.

    A column sorts and filters in the database when it names a field of
    the query's first source (`field={:total}`). A column with a `value`
    function is shown, but does not sort or filter.

    The text filters and the search compare without case with
    `lower(field) LIKE ...`, which PostgreSQL, MySQL and SQLite all run.
    An index on `lower(field)` makes them fast on a large table.

    ## Options

      * `:repo` (required) - the repo that runs the queries.
      * `:repo_opts` - options for each call to the repo, such as
        `prefix:` for a tenant's schema.
    """

    @behaviour Masu.Source

    import Ecto.Query

    alias Masu.{Column, Filter, Query, Sort}

    @doc false
    @spec queryable?(term()) :: boolean()
    def queryable?(%Ecto.Query{}), do: true

    def queryable?(module) when is_atom(module) do
      Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1)
    end

    def queryable?(_other), do: false

    @impl true
    def init(queryable, opts) do
      repo =
        Keyword.get(opts, :repo) ||
          raise ArgumentError, "a Masu grid with an Ecto source needs a :repo"

      base = Ecto.Queryable.to_query(queryable)

      %{
        repo: repo,
        repo_opts: Keyword.get(opts, :repo_opts, []),
        base: base,
        query: base,
        primary_key: primary_key(base),
        count: nil
      }
    end

    @impl true
    def prepare(state, %Query{} = query, columns) do
      ecto =
        state.base
        |> where_filters(query.filters, columns)
        |> where_search(query.search, columns)
        |> order(query.sorts, columns, state.primary_key)

      count =
        ecto
        |> exclude(:order_by)
        |> exclude(:preload)
        |> subquery()
        |> select(count())
        |> state.repo.one(state.repo_opts)

      %{state | query: ecto, count: count}
    end

    @impl true
    def count(%{count: nil} = state), do: state |> prepare(%Query{}, []) |> count()
    def count(%{count: count}), do: count

    @impl true
    def rows(state, offset, limit) do
      state.query
      |> offset(^offset)
      |> limit(^limit)
      |> state.repo.all(state.repo_opts)
    end

    @impl true
    def supports?(_state, column), do: Column.stored?(column)

    # One GROUP BY of the query (with the person's other filters and
    # search), the most frequent values first.
    @impl true
    def values(state, %Column{field: f} = column, query, columns, opts) do
      if Column.stored?(column) do
        state.base
        |> where_filters(query.filters, columns)
        |> where_search(query.search, columns)
        |> where_value_search(f, Keyword.get(opts, :search))
        |> exclude(:order_by)
        |> exclude(:preload)
        |> exclude(:select)
        |> group_by([r], field(r, ^f))
        |> select([r], {field(r, ^f), count()})
        |> order_by([r], desc: count(), asc: field(r, ^f))
        |> limit(^Keyword.get(opts, :limit, 50))
        |> state.repo.all(state.repo_opts)
      else
        []
      end
    end

    defp where_value_search(query, _f, nil), do: query
    defp where_value_search(query, _f, ""), do: query

    defp where_value_search(query, f, text),
      do: where(query, ^like(f, "%" <> escape(text) <> "%"))

    defp primary_key(%Ecto.Query{from: %{source: {_table, schema}}})
         when is_atom(schema) and schema != nil do
      if function_exported?(schema, :__schema__, 1), do: schema.__schema__(:primary_key), else: []
    end

    defp primary_key(_query), do: []

    defp where_filters(query, filters, columns) do
      Enum.reduce(filters, query, fn %Filter{key: key} = filter, query ->
        column = Column.find(columns, key)

        if column && Column.stored?(column),
          do: where(query, ^condition(column.field, filter)),
          else: query
      end)
    end

    defp condition(f, %Filter{op: :is_nil}), do: dynamic([r], is_nil(field(r, ^f)))
    defp condition(f, %Filter{op: :not_nil}), do: dynamic([r], not is_nil(field(r, ^f)))
    defp condition(f, %Filter{op: :eq, value: nil}), do: dynamic([r], is_nil(field(r, ^f)))
    defp condition(f, %Filter{op: :eq, value: v}), do: dynamic([r], field(r, ^f) == ^v)

    defp condition(f, %Filter{op: :neq, value: nil}),
      do: dynamic([r], not is_nil(field(r, ^f)))

    defp condition(f, %Filter{op: :neq, value: v}),
      do: dynamic([r], field(r, ^f) != ^v or is_nil(field(r, ^f)))

    defp condition(f, %Filter{op: :gt, value: v}), do: dynamic([r], field(r, ^f) > ^v)
    defp condition(f, %Filter{op: :gte, value: v}), do: dynamic([r], field(r, ^f) >= ^v)
    defp condition(f, %Filter{op: :lt, value: v}), do: dynamic([r], field(r, ^f) < ^v)
    defp condition(f, %Filter{op: :lte, value: v}), do: dynamic([r], field(r, ^f) <= ^v)

    defp condition(f, %Filter{op: :between, value: [from, to]}),
      do: dynamic([r], field(r, ^f) >= ^from and field(r, ^f) <= ^to)

    defp condition(f, %Filter{op: :in, value: values}), do: dynamic([r], field(r, ^f) in ^values)

    defp condition(f, %Filter{op: :contains, value: v}), do: like(f, "%" <> escape(v) <> "%")

    defp condition(f, %Filter{op: :not_contains, value: v}) do
      pattern = "%" <> escape(v) <> "%"

      dynamic(
        [r],
        is_nil(field(r, ^f)) or fragment("lower(?) NOT LIKE ? ESCAPE '!'", field(r, ^f), ^pattern)
      )
    end

    defp condition(f, %Filter{op: :starts_with, value: v}), do: like(f, escape(v) <> "%")
    defp condition(f, %Filter{op: :ends_with, value: v}), do: like(f, "%" <> escape(v))

    defp like(f, pattern),
      do: dynamic([r], fragment("lower(?) LIKE ? ESCAPE '!'", field(r, ^f), ^pattern))

    # `!` escapes the wildcards of LIKE: unlike a backslash, it means the
    # same in the string literals of PostgreSQL, MySQL and SQLite.
    defp escape(text) do
      text
      |> String.downcase()
      |> String.replace("!", "!!")
      |> String.replace("%", "!%")
      |> String.replace("_", "!_")
    end

    defp where_search(query, nil, _columns), do: query

    defp where_search(query, text, columns) do
      fields = for %Column{searchable: true} = c <- columns, Column.stored?(c), do: c.field

      case fields do
        [] ->
          query

        fields ->
          pattern = "%" <> escape(text) <> "%"

          condition =
            Enum.reduce(fields, dynamic(false), fn f, acc ->
              dynamic(
                [r],
                ^acc or fragment("lower(?) LIKE ? ESCAPE '!'", field(r, ^f), ^pattern)
              )
            end)

          where(query, ^condition)
      end
    end

    defp order(query, sorts, columns, primary_key) do
      fields =
        for %Sort{key: key, direction: direction} <- sorts,
            %Column{} = column <- [Column.find(columns, key)],
            Column.stored?(column),
            do: {direction, column.field}

      case fields do
        # Without an order of its own, a query reads its rows in the order
        # of its primary key: an offset means nothing in no order.
        [] when query.order_bys == [] and primary_key != [] ->
          order_by(query, ^Enum.map(primary_key, &{:asc, &1}))

        [] ->
          query

        fields ->
          tiebreak = for key <- primary_key, not List.keymember?(fields, key, 1), do: {:asc, key}
          query |> exclude(:order_by) |> order_by(^(fields ++ tiebreak))
      end
    end
  end
end

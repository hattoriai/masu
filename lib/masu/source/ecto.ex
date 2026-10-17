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

    ## A tree

    With the grid's `tree` (a field that holds the parent's id), the rows
    are a tree (`Masu.Tree`). The source keeps the ids of the rows that
    show, not the rows: the roots, in the grid's order, and the children
    of each row the person opens, read when it opens; each block of rows
    is then read by its ids. A filter or a search reads the ids of the
    rows that match and climbs to their ancestors, a level per query. The
    schema needs one primary key.

    ## Options

      * `:repo` (required) - the repo that runs the queries.
      * `:repo_opts` - options for each call to the repo, such as
        `prefix:` for a tenant's schema.
    """

    @behaviour Masu.Source

    import Ecto.Query

    alias Masu.{Column, Filter, Group, Query, Sort, Tree}

    # How many levels a filter climbs to find the ancestors of its rows.
    @max_depth 100

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
        count: nil,
        order: [],
        tree: tree!(Keyword.get(opts, :tree), base),
        flat: nil,
        filtered: false,
        segments: nil,
        group_columns: [],
        totals: %{}
      }
    end

    defp tree!(nil, _base), do: nil

    defp tree!(field, base) when is_atom(field) do
      if length(primary_key(base)) != 1 do
        raise ArgumentError, "a Masu tree of an Ecto source needs a schema with one primary key"
      end

      field
    end

    defp tree!(other, _base),
      do: raise(ArgumentError, "the tree of an Ecto source is a field, got: #{inspect(other)}")

    @impl true
    def prepare(%{tree: parent} = state, %Query{} = query, columns) when parent != nil do
      {ordered, order} = order(state.base, query.sorts, columns, state.primary_key)

      {entries, open?, filtered} =
        if query.filters == [] and query.search == nil do
          # The roots, and the children of the rows that are open, a level
          # at a time: an open row under a closed one is not read.
          roots = ordered |> where([r], is_nil(field(r, ^parent))) |> pairs(state)
          children = open_children(ordered, roots, query.expanded, state)
          {roots ++ children, &MapSet.member?(query.expanded, &1), false}
        else
          # The rows that match and their ancestors, in the grid's order.
          kept =
            state.base
            |> where_filters(query.filters, columns)
            |> where_search(query.search, columns)
            |> exclude(:order_by)
            |> pairs(state)
            |> Map.new()
            |> ancestors(state, 0)
            |> Map.keys()

          [key] = state.primary_key
          entries = ordered |> where([r], field(r, ^key) in ^kept) |> pairs(state)
          {entries, &(not MapSet.member?(query.collapsed, &1)), true}
        end

      flat = Tree.flatten(entries, open?)

      %{
        state
        | flat: flat,
          count: length(flat),
          order: order,
          filtered: filtered,
          totals: totals_of(state, query, columns)
      }
    end

    # Grouped (Masu.Group): one GROUP BY for each level that shows, and the
    # rows of an open group read a block at a time.
    def prepare(state, %Query{groups: [_ | _] = keys} = query, columns) do
      filtered =
        state.base
        |> where_filters(query.filters, columns)
        |> where_search(query.search, columns)

      {ordered, order} = order(filtered, query.sorts, columns, state.primary_key)

      groups = fn path, key ->
        groups_of(state, filtered, path, Column.find(columns, key), columns, query.sorts)
      end

      segments = Group.segments(keys, &MapSet.member?(query.expanded, &1), groups)

      %{
        state
        | query: ordered,
          order: order,
          segments: segments,
          count: Group.count(segments),
          group_columns: Enum.map(keys, &Column.find(columns, &1)),
          totals: totals_of(state, query, columns)
      }
    end

    def prepare(state, %Query{} = query, columns) do
      ecto =
        state.base
        |> where_filters(query.filters, columns)
        |> where_search(query.search, columns)

      {ecto, order} = order(ecto, query.sorts, columns, state.primary_key)

      count =
        ecto
        |> exclude(:order_by)
        |> exclude(:preload)
        |> subquery()
        |> select(count())
        |> state.repo.one(state.repo_opts)

      %{
        state
        | query: ecto,
          count: count,
          order: order,
          segments: nil,
          totals: totals_of(state, query, columns)
      }
    end

    @impl true
    def totals(%{totals: totals}), do: totals

    # The groups of a column under a path, with their counts and totals.
    defp groups_of(state, filtered, path, %Column{key: key, field: f} = column, columns, sorts) do
      aggregates = aggregate_selects(columns)

      select =
        Map.merge(aggregates, %{
          "masu:value" => dynamic([r], field(r, ^f)),
          "masu:count" => dynamic([r], count())
        })

      filtered
      |> where_path(path, columns)
      |> exclude(:order_by)
      |> exclude(:preload)
      |> exclude(:select)
      |> group_by([r], field(r, ^f))
      |> select(^select)
      |> order_by(^group_order(column, sorts, columns))
      |> state.repo.all(state.repo_opts)
      |> Enum.map(fn found ->
        value = found["masu:value"]

        %Group{
          key: key,
          value: value,
          count: found["masu:count"],
          aggregates: found |> Map.take(Map.keys(aggregates)) |> round_averages(columns),
          path: path ++ [{key, value}]
        }
      end)
    end

    # Groups by their value, turned by a sort on their column, or by an
    # aggregate when the first sort is on a column with one.
    defp group_order(%Column{key: key, field: f}, sorts, columns) do
      case sorts do
        [%Sort{key: ^key, direction: direction} | _] ->
          [{direction, dynamic([r], field(r, ^f))}]

        [%Sort{key: sort_key, direction: direction} | _] ->
          by_total(Column.find(columns, sort_key), direction, f)

        [] ->
          [asc: dynamic([r], field(r, ^f))]
      end
    end

    defp by_total(column, direction, f) do
      case column && aggregate_select(column) do
        nil -> [asc: dynamic([r], field(r, ^f))]
        expression -> [{direction, expression}]
      end
    end

    defp where_path(query, path, columns) do
      Enum.reduce(path, query, fn {key, value}, query ->
        f = Column.find(columns, key).field

        if is_nil(value),
          do: where(query, [r], is_nil(field(r, ^f))),
          else: where(query, [r], field(r, ^f) == ^value)
      end)
    end

    # The totals of the query (with the person's filters and search).
    defp totals_of(state, query, columns) do
      case aggregate_selects(columns) do
        selects when selects == %{} ->
          %{}

        selects ->
          state.base
          |> where_filters(query.filters, columns)
          |> where_search(query.search, columns)
          |> exclude(:order_by)
          |> exclude(:preload)
          |> exclude(:select)
          |> select(^selects)
          |> state.repo.one(state.repo_opts)
          |> round_averages(columns)
      end
    end

    defp round_averages(totals, columns) do
      Map.new(totals, fn {key, value} ->
        case Column.find(columns, key) do
          %Column{aggregate: :avg} -> {key, Group.average(value)}
          _other -> {key, value}
        end
      end)
    end

    defp aggregate_selects(columns) do
      for column <- columns, expression = aggregate_select(column), into: %{} do
        {column.key, expression}
      end
    end

    # A column's aggregate in SQL; a decimal stays a decimal. A function
    # of the rows is for lists only.
    defp aggregate_select(%Column{aggregate: aggregate} = column)
         when aggregate in [:sum, :avg, :min, :max, :count, :count_distinct] do
      if Column.stored?(column), do: aggregate_expression(aggregate, column.field, column.type)
    end

    defp aggregate_select(_column), do: nil

    defp aggregate_expression(:count, f, _type), do: dynamic([r], count(field(r, ^f)))

    defp aggregate_expression(:count_distinct, f, _type),
      do: dynamic([r], count(field(r, ^f), :distinct))

    defp aggregate_expression(:sum, f, :decimal),
      do: dynamic([r], type(sum(field(r, ^f)), :decimal))

    defp aggregate_expression(:sum, f, _type), do: dynamic([r], sum(field(r, ^f)))

    defp aggregate_expression(:avg, f, :decimal),
      do: dynamic([r], type(avg(field(r, ^f)), :decimal))

    defp aggregate_expression(:avg, f, _type), do: dynamic([r], avg(field(r, ^f)))
    defp aggregate_expression(:min, f, _type), do: dynamic([r], min(field(r, ^f)))
    defp aggregate_expression(:max, f, _type), do: dynamic([r], max(field(r, ^f)))

    defp open_children(ordered, level, expanded, %{tree: parent} = state) do
      open = for {id, _parent} <- level, MapSet.member?(expanded, id), do: id

      if open == [] do
        []
      else
        children = ordered |> where([r], field(r, ^parent) in ^open) |> pairs(state)
        # Each row once, whatever cycles the data has.
        expanded = Enum.reduce(open, expanded, &MapSet.delete(&2, &1))
        children ++ open_children(ordered, children, expanded, state)
      end
    end

    # `{id, parent id}` of the rows of a query.
    defp pairs(query, %{primary_key: [key], tree: parent} = state) do
      query
      |> exclude(:preload)
      |> exclude(:select)
      |> select([r], {field(r, ^key), field(r, ^parent)})
      |> state.repo.all(state.repo_opts)
    end

    # The parents the kept rows name, read until every one is there.
    defp ancestors(parents, state, depth) do
      missing =
        parents
        |> Map.values()
        |> Enum.reject(&(is_nil(&1) or Map.has_key?(parents, &1)))
        |> Enum.uniq()

      if missing == [] or depth >= @max_depth do
        parents
      else
        [key] = state.primary_key

        found =
          state.base
          |> exclude(:order_by)
          |> where([r], field(r, ^key) in ^missing)
          |> pairs(state)

        # A parent that is not in the grid's query ends the climb.
        found_parents = Map.new(found)
        lost = for id <- missing, not Map.has_key?(found_parents, id), into: %{}, do: {id, nil}

        parents |> Map.merge(found_parents) |> Map.merge(lost) |> ancestors(state, depth + 1)
      end
    end

    @impl true
    def count(%{count: nil} = state), do: state |> prepare(%Query{}, []) |> count()
    def count(%{count: count}), do: count

    @impl true
    def rows(%{segments: segments} = state, offset, limit) when is_list(segments),
      do: state |> nodes(offset, limit) |> Enum.map(&elem(&1, 0))

    def rows(%{flat: flat} = state, offset, limit) when is_list(flat) do
      state |> nodes(offset, limit) |> Enum.map(&elem(&1, 0))
    end

    def rows(state, offset, limit) do
      state.query
      |> offset(^offset)
      |> limit(^limit)
      |> state.repo.all(state.repo_opts)
    end

    # The rows of a block of the tree, by their ids, with their places. A
    # row the source has not opened may have children: one query tells.
    @impl true
    def nodes(%{segments: segments} = state, offset, limit) when is_list(segments) do
      Group.slice(segments, offset, limit, fn path, from, count ->
        state.query
        |> where_path(path, state.group_columns)
        |> offset(^from)
        |> limit(^count)
        |> state.repo.all(state.repo_opts)
      end)
    end

    def nodes(%{flat: nil}, _offset, _limit), do: nil

    def nodes(%{flat: flat} = state, offset, limit) do
      block = Enum.slice(flat, offset, limit)
      ids = Enum.map(block, &elem(&1, 0))
      [key] = state.primary_key
      rows = state |> fetch(ids, nil) |> Map.new(&{Map.get(&1, key), &1})
      parents = if state.filtered, do: MapSet.new(), else: with_children(state, ids)

      for {id, _parent, info} <- block, row = rows[id] do
        {row, %{info | children: info.children or MapSet.member?(parents, id)}}
      end
    end

    @impl true
    def siblings(%{segments: segments}, id) when is_list(segments),
      do: Group.siblings(segments, id)

    def siblings(%{flat: flat} = state, id) when is_list(flat) do
      candidates =
        case List.keyfind(flat, id, 0) do
          {_id, _parent, %{level: 0}} -> for {s, _p, %{level: 0}} <- flat, do: s
          {_id, parent, _info} -> for {s, ^parent, _info} <- flat, do: s
          nil -> []
        end

      if state.filtered do
        Tree.siblings(flat, id)
      else
        parents = with_children(state, candidates)
        Enum.filter(candidates, &MapSet.member?(parents, &1))
      end
    end

    def siblings(_state, _id), do: []

    defp with_children(_state, []), do: MapSet.new()

    defp with_children(%{tree: parent} = state, ids) do
      state.base
      |> exclude(:order_by)
      |> exclude(:preload)
      |> exclude(:select)
      |> where([r], field(r, ^parent) in ^ids)
      |> select([r], field(r, ^parent))
      |> distinct(true)
      |> state.repo.all(state.repo_opts)
      |> MapSet.new()
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

    # The rows by their primary key, through the grid's own query: a row
    # outside it is not found.
    @impl true
    def fetch(%{primary_key: [key]} = state, ids, _row_id) do
      state.base
      |> where([r], field(r, ^key) in ^ids)
      |> state.repo.all(state.repo_opts)
    end

    def fetch(_state, _ids, _row_id), do: []

    # The place of a row in the grid's order: its row_number() in a window
    # of the same order, which PostgreSQL, MySQL 8 and SQLite 3.25 have; in
    # a tree, its place among the rows that show.
    # In groups, a row is not found (the follower stays where they are).
    @impl true
    def locate(%{segments: segments}, _id, _row_id) when is_list(segments), do: nil

    def locate(%{flat: flat}, id, _row_id) when is_list(flat),
      do: Enum.find_index(flat, &(elem(&1, 0) == id))

    def locate(%{order: order, primary_key: [key]} = state, id, _row_id) when is_list(order) do
      ranked =
        state.query
        |> exclude(:order_by)
        |> exclude(:preload)
        |> exclude(:select)
        |> windows([r], w: [order_by: ^order])
        |> select([r], %{id: field(r, ^key), n: over(row_number(), :w)})

      from(s in subquery(ranked), where: s.id == ^id, select: s.n)
      |> state.repo.one(state.repo_opts)
      |> case do
        nil -> nil
        n -> n - 1
      end
    end

    def locate(_state, _id, _row_id), do: nil

    @doc false
    # Runs `fun` with the row of `id` (through the grid's query, or nil) in
    # a transaction that locks the row where the database can
    # (`SELECT ... FOR UPDATE` in PostgreSQL and MySQL; SQLite writes one
    # transaction at a time), and gives what `fun` gives.
    @spec locked(map(), term(), (term() -> result)) :: result when result: term()
    def locked(%{repo: repo} = state, id, fun) do
      {:ok, result} =
        repo.transaction(fn ->
          lock_row(state, id)
          fun.(state |> fetch([id], nil) |> List.first())
        end)

      result
    end

    @locking [Ecto.Adapters.Postgres, Ecto.Adapters.MyXQL]

    # The lock is taken on the schema's own row, not through the grid's
    # query: a lock on a query with outer joins is refused by PostgreSQL.
    defp lock_row(
           %{base: %Ecto.Query{from: %{source: {_table, schema}}}, primary_key: [key]} = state,
           id
         )
         when is_atom(schema) and schema != nil do
      if state.repo.__adapter__() in @locking do
        from(r in schema, where: field(r, ^key) == ^id, lock: "FOR UPDATE", select: 1)
        |> state.repo.all(state.repo_opts)
      end

      :ok
    end

    defp lock_row(_state, _id), do: :ok

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

    # The query in the grid's order, and that order as a keyword list, or
    # nil when it is the query's own order_by (which a window cannot copy).
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
          order = Enum.map(primary_key, &{:asc, &1})
          {order_by(query, ^order), order}

        [] ->
          {query, if(query.order_bys == [], do: [])}

        fields ->
          tiebreak = for key <- primary_key, not List.keymember?(fields, key, 1), do: {:asc, key}
          order = fields ++ tiebreak
          {query |> exclude(:order_by) |> order_by(^order), order}
      end
    end
  end
end

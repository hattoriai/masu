if Code.ensure_loaded?(Ecto.Query) do
  defmodule Masu.Source.Ecto do
    @moduledoc """
    The source of a grid given an Ecto query or schema and a repo:
    `<.data_grid source={from(o in Order, where: o.shop_id == ^shop.id)} repo={Repo}>`.

    The database does the work. A sort is an `ORDER BY`, a filter and the
    search a `WHERE`, the count a `count(*)` of the query, and each block
    the browser asks for one `LIMIT`: the block after a block it read by
    the sort values of that block's last row, not by `OFFSET` (see
    [Export, selection and large tables](export.md)). The LiveView never
    holds more rows than the screen shows.

    The query may already have its own `where`, `join` and `preload`: the
    grid's filters are added to them. The grid's order replaces the
    query's while the person sorts, and the query's order is used when
    they do not. After the grid's order comes the schema's primary key, so
    that rows of equal values do not move from one block to the next.

    A column sorts and filters in the database when it names a field of
    the query's first source (`field={:total}`), or a field of a related
    row through the schema's associations (`field={[:customer, :name]}`).
    A column with a `value` function is shown, but does not sort or
    filter.

    ## Related rows

    A path of `belongs_to` and `has_one` associations is one value. The
    source joins each step (`LEFT JOIN`, a named binding: `:customer`,
    then `:customer_company`) when a sort, a filter, the search or a group
    needs it, and uses a binding of that name that the query already has.
    A row with no related row has `NULL` there. The source preloads the
    associations of the paths, so that each row shows its values and the
    blocks are read by key.

    A path through a `has_many` or `many_to_many` is of many values. It
    filters and searches with a subquery of the related rows (`id IN
    (SELECT ...)`), never a join, so that the rows are not repeated and
    the count stays right; it does not sort or group. The schema needs one
    primary key.

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
      * `:count_limit` - the most rows the count counts: past it, the
        count is `{:at_least, limit}`.
      * `:read` - a read of a block of rows of the app's own: a function
        of the query and `%{offset:, limit:, order:, after:}` (see "A
        read of your own" in the [Sources](sources.md) guide).
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

    # Where NULL sorts in an adapter's ORDER BY: after every value in
    # PostgreSQL, before them in MySQL, SQLite and SQL Server. With
    # another adapter, a block is read by key only in the order of the
    # primary key, which has no NULL; in another order, by OFFSET.
    @nulls %{
      Ecto.Adapters.Postgres => :last,
      Ecto.Adapters.MyXQL => :first,
      Ecto.Adapters.SQLite3 => :first,
      Ecto.Adapters.Tds => :first
    }

    @impl true
    def init(queryable, opts) do
      repo =
        Keyword.get(opts, :repo) ||
          raise ArgumentError, "a Masu grid with an Ecto source needs a :repo"

      base = queryable |> Ecto.Queryable.to_query() |> named()

      %{
        repo: repo,
        repo_opts: Keyword.get(opts, :repo_opts, []),
        read: read!(Keyword.get(opts, :read)),
        count_limit: count_limit!(Keyword.get(opts, :count_limit)),
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
        totals: %{},
        nulls: Map.get(@nulls, repo.__adapter__()),
        cursors: %{},
        preloads: [],
        root: base.from.as
      }
    end

    # The query's first source as a named binding (its own name, or
    # `:masu`): each field is then `field(as(^name), ^f)`, of the first
    # source or of a join, and a value compared to it takes its type.
    defp named(%Ecto.Query{from: %{as: nil}} = query), do: from(r in query, as: :masu)
    defp named(query), do: query

    defp count_limit!(nil), do: nil
    defp count_limit!(limit) when is_integer(limit) and limit > 0, do: limit

    defp count_limit!(other),
      do:
        raise(
          ArgumentError,
          "a Masu grid's count_limit is a positive integer, got: #{inspect(other)}"
        )

    defp read!(nil), do: nil
    defp read!(read) when is_function(read, 2), do: read

    defp read!(other),
      do:
        raise(
          ArgumentError,
          "a Masu grid's read is a function of two arguments, got: #{inspect(other)}"
        )

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
      columns = known(state, columns)
      state = %{state | preloads: preloads(state, columns)}
      {ordered, order} = order(state.base, query.sorts, columns, state)

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
            |> where_filters(query.filters, columns, state)
            |> where_search(query.search, columns, state)
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
      columns = known(state, columns)
      state = %{state | preloads: preloads(state, columns)}

      filtered =
        state.base
        |> where_filters(query.filters, columns, state)
        |> where_search(query.search, columns, state)
        |> join_all(Enum.map(keys, &Column.find(columns, &1)))

      {ordered, order} = order(filtered, query.sorts, columns, state)

      groups = fn path, key ->
        groups_of(state, filtered, path, Column.find(columns, key), columns, query.sorts)
      end

      segments = Group.segments(keys, &Group.open?(query, &1), groups)

      %{
        state
        | query: with_preloads(ordered, state),
          order: order,
          segments: segments,
          count: Group.count(segments),
          group_columns: Enum.map(keys, &Column.find(columns, &1)),
          totals: totals_of(state, query, columns)
      }
    end

    def prepare(state, %Query{} = query, columns) do
      columns = known(state, columns)
      state = %{state | preloads: preloads(state, columns)}

      ecto =
        state.base
        |> where_filters(query.filters, columns, state)
        |> where_search(query.search, columns, state)

      {ecto, order} = order(ecto, query.sorts, columns, state)

      # The count is asked for when the grid wants it (it may not): a
      # count(*) can be the slowest query of all.
      %{
        state
        | query: with_preloads(ecto, state),
          count: :later,
          order: order,
          segments: nil,
          totals: totals_of(state, query, columns),
          cursors: %{}
      }
    end

    @impl true
    def totals(%{totals: totals}), do: totals

    # Every row of the query but some: a query of them (the person's
    # filters and search, without order), for an update_all or a job.
    @impl true
    def select_all(%{primary_key: [key]} = state, query, columns, except, _row_id) do
      columns = known(state, columns)

      ecto =
        state.base
        |> where_filters(query.filters, columns, state)
        |> where_search(query.search, columns, state)
        |> exclude(:order_by)
        |> exclude(:preload)
        |> without_joins(state)

      {:query, if(except == [], do: ecto, else: where(ecto, [r], field(r, ^key) not in ^except))}
    end

    # A query with the joins of related fields or the subqueries of many
    # values as a query of the schema's rows by their keys, from a derived
    # table: an update_all or a delete_all of it runs in each database
    # (SQLite has no UPDATE ... FROM a join; MySQL refuses a subquery of
    # the table it updates, but for a derived table it does not merge,
    # which DISTINCT keeps apart).
    defp without_joins(ecto, %{base: base, primary_key: [key]}) do
      if ecto.joins == base.joins and Enum.all?(ecto.wheres, &(&1.subqueries == [])) do
        ecto
      else
        %{from: %{source: {_table, schema}}} = base

        ids =
          ecto
          |> exclude(:select)
          |> exclude(:distinct)
          |> select([r], %{id: field(r, ^key)})
          |> distinct(true)

        from(r in schema,
          where: field(r, ^key) in subquery(from(i in subquery(ids), select: i.id))
        )
        |> Map.put(:prefix, base.prefix)
      end
    end

    @doc false
    # The ids of the first `limit` rows of a query of `select_all/5`.
    @spec ids_of(map(), Ecto.Query.t(), pos_integer()) :: [term()]
    def ids_of(%{primary_key: [key]} = state, query, limit) do
      query
      |> exclude(:select)
      |> select([r], field(r, ^key))
      |> limit(^limit)
      |> state.repo.all(state.repo_opts)
    end

    # The groups of a column under a path, with their counts and totals.
    defp groups_of(state, filtered, path, %Column{key: key, field: f} = column, columns, sorts) do
      aggregates = aggregate_selects(columns, state.root)
      {filtered, ref} = expression(filtered, state.root, f)
      value = value(ref)

      select =
        Map.merge(aggregates, %{
          "masu:value" => value,
          "masu:count" => dynamic([r], count())
        })

      filtered
      |> join_all(aggregate_columns(columns))
      |> where_path(path, columns, state.root)
      |> exclude(:order_by)
      |> exclude(:preload)
      |> exclude(:select)
      |> group_by(^[value])
      |> select(^select)
      |> order_by(^group_order(column, sorts, columns, state.root))
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
    defp group_order(%Column{key: key, field: f}, sorts, columns, root) do
      case sorts do
        [%Sort{key: ^key, direction: direction} | _] ->
          [{direction, value(ref(root, f))}]

        [%Sort{key: sort_key, direction: direction} | _] ->
          by_total(Column.find(columns, sort_key), direction, f, root)

        [] ->
          [asc: value(ref(root, f))]
      end
    end

    defp by_total(column, direction, f, root) do
      case column && aggregate_select(column, root) do
        nil -> [asc: value(ref(root, f))]
        expression -> [{direction, expression}]
      end
    end

    defp where_path(query, path, columns, root) do
      Enum.reduce(path, query, fn {key, value}, query ->
        {query, ref} = expression(query, root, Column.find(columns, key).field)
        where(query, ^condition(ref, %Filter{key: key, op: :eq, value: value}))
      end)
    end

    # The totals of the query (with the person's filters and search).
    defp totals_of(state, query, columns) do
      case aggregate_selects(columns, state.root) do
        selects when selects == %{} ->
          %{}

        selects ->
          state.base
          |> where_filters(query.filters, columns, state)
          |> where_search(query.search, columns, state)
          |> join_all(aggregate_columns(columns))
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

    defp aggregate_selects(columns, root) do
      for column <- columns, expression = aggregate_select(column, root), into: %{} do
        {column.key, expression}
      end
    end

    defp aggregate_columns(columns), do: Enum.filter(columns, &aggregate_select(&1, nil))

    # A column's aggregate in SQL; a decimal stays a decimal. A function
    # of the rows is for lists only, and many values have none.
    defp aggregate_select(%Column{aggregate: aggregate, many: many} = column, root)
         when aggregate in [:sum, :avg, :min, :max, :count, :count_distinct] and many != true do
      if Column.stored?(column),
        do: aggregate_expression(aggregate, value(ref(root, column.field)), column.type)
    end

    defp aggregate_select(_column, _root), do: nil

    defp aggregate_expression(:count, v, _type), do: dynamic(count(^v))
    defp aggregate_expression(:count_distinct, v, _type), do: dynamic(count(^v, :distinct))
    defp aggregate_expression(:sum, v, :decimal), do: dynamic(type(sum(^v), :decimal))
    defp aggregate_expression(:sum, v, _type), do: dynamic(sum(^v))
    defp aggregate_expression(:avg, v, :decimal), do: dynamic(type(avg(^v), :decimal))
    defp aggregate_expression(:avg, v, _type), do: dynamic(avg(^v))
    defp aggregate_expression(:min, v, _type), do: dynamic(min(^v))
    defp aggregate_expression(:max, v, _type), do: dynamic(max(^v))

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

    def count(%{count: :later, query: ecto, count_limit: nil} = state) do
      ecto
      |> exclude(:order_by)
      |> exclude(:preload)
      |> subquery()
      |> select(count())
      |> state.repo.one(state.repo_opts)
    end

    # Up to the limit: the database stops after the row past it, where a
    # count(*) of a large table reads every row.
    def count(%{count: :later, query: ecto, count_limit: max} = state) do
      n =
        ecto
        |> exclude(:order_by)
        |> exclude(:preload)
        |> limit(^(max + 1))
        |> subquery()
        |> select(count())
        |> state.repo.one(state.repo_opts)

      if n > max, do: {:at_least, max}, else: n
    end

    def count(%{count: count}), do: count

    @impl true
    def rows(%{segments: segments} = state, offset, limit) when is_list(segments),
      do: state |> nodes(offset, limit) |> Enum.map(&elem(&1, 0))

    def rows(%{flat: flat} = state, offset, limit) when is_list(flat) do
      state |> nodes(offset, limit) |> Enum.map(&elem(&1, 0))
    end

    # A read of the app's own: the query, and where the block is.
    def rows(%{read: read} = state, offset, limit) when is_function(read, 2) do
      read.(state.query, %{
        offset: offset,
        limit: limit,
        order: state.order,
        after: after_values(state, offset)
      })
    end

    # A block after a block the source read is read by the sort values of
    # that block's last row (`WHERE (a, b, id) > (...)`, as it were), not by
    # an OFFSET, which the database counts row by row: the last block of a
    # million rows is as fast as the first. A jump (the scrollbar dragged)
    # is an OFFSET, and the blocks after it are read by key again.
    def rows(state, offset, limit) do
      case Map.get(state.cursors, offset) do
        nil when offset > 0 -> state.query |> offset(^offset) |> limit(^limit) |> all(state)
        nil -> state.query |> limit(^limit) |> all(state)
        values -> rows_after(state, values, limit)
      end
    end

    defp all(query, state), do: state.repo.all(query, state.repo_opts)

    # The rows after a row, with a range on the first sort (`a >= ?`) that
    # an index reads from: the database reads none from the OR of
    # after_row/2, and goes through every row before the block. The range
    # leaves out the first sort's NULLs. Where they come after its values
    # (ascending in PostgreSQL, descending in MySQL and SQLite), the block
    # the range ends short goes on with them, in a second query.
    defp rows_after(%{order: [{direction, f} | _]} = state, [value | _] = values, limit) do
      query = where(state.query, ^after_row(state, values))

      if is_nil(value) do
        query |> limit(^limit) |> all(state)
      else
        ref = ref(state.root, f)
        rows = query |> where(^from_value(direction, ref, value)) |> limit(^limit) |> all(state)
        rest = limit - length(rows)

        if rest > 0 and nulls_after?(state.nulls, direction),
          do: rows ++ (query |> where(^null(ref)) |> limit(^rest) |> all(state)),
          else: rows
      end
    end

    defp from_value(:asc, {b, f}, value), do: dynamic(field(as(^b), ^f) >= ^value)
    defp from_value(:desc, {b, f}, value), do: dynamic(field(as(^b), ^f) <= ^value)

    defp nulls_after?(:last, :asc), do: true
    defp nulls_after?(:first, :desc), do: true
    defp nulls_after?(_nulls, _direction), do: false

    # The cursors of a prepared query: the sort values of the row before
    # each block, by the block's offset. They are in the state, which the
    # grid keeps, so that a block read in a task has them too.
    @max_cursors 512

    @doc false
    def seen(%{cursors: cursors, order: order} = state, offset, [_ | _] = rows)
        when is_list(order) do
      row = List.last(rows)
      values = Enum.map(order, fn {_direction, f} -> fetch_value(row, f) end)

      if (state.read != nil or keyset?(state)) and Enum.all?(values, &match?({:ok, _}, &1)) do
        cursors = if map_size(cursors) >= @max_cursors, do: %{}, else: cursors
        cursor = Enum.map(values, &elem(&1, 1))
        %{state | cursors: Map.put(cursors, offset + length(rows), cursor)}
      else
        state
      end
    end

    def seen(state, _offset, _rows), do: state

    # The value of a field of the row, or of a related row through its
    # path (nil when there is none); :error when it is not loaded.
    defp fetch_value(row, f) when is_atom(f), do: Map.fetch(row, f)

    defp fetch_value(row, [f]), do: fetch_value(row, f)

    defp fetch_value(row, [step | path]) do
      case Map.fetch(row, step) do
        {:ok, nil} -> {:ok, nil}
        {:ok, %Ecto.Association.NotLoaded{}} -> :error
        {:ok, %{} = related} -> fetch_value(related, path)
        _other -> :error
      end
    end

    # The sort values of the row before a block, by field, for a read of
    # the app's own: nil for the first block, and after a jump.
    defp after_values(%{cursors: cursors, order: order}, offset) do
      case Map.get(cursors, offset) do
        nil -> nil
        values -> Enum.zip_with(order, values, fn {_direction, f}, value -> {f, value} end)
      end
    end

    defp keyset?(%{nulls: nil, order: order, primary_key: key}),
      do: Enum.all?(order, fn {_direction, f} -> f in key end)

    defp keyset?(_state), do: true

    # The rows after a row in the order: for the sorts (a, b, id), those
    # with a beyond the row's, or a the same and b beyond, or a and b the
    # same and id beyond.
    defp after_row(%{order: order, nulls: nulls, root: root}, values) do
      nulls_last? = nulls == :last

      {condition, _same} =
        order
        |> Enum.zip(values)
        |> Enum.reduce({dynamic([r], false), dynamic([r], true)}, fn {{direction, f}, value},
                                                                     {acc, same} ->
          x = ref(root, f)
          beyond = beyond(direction, x, value, nulls_last?)

          {dynamic([r], ^acc or (^same and ^beyond)),
           dynamic([r], ^same and ^same_value(x, value))}
        end)

      condition
    end

    defp same_value(x, nil), do: null(x)
    defp same_value({b, f}, v), do: dynamic(field(as(^b), ^f) == ^v)

    defp beyond(:asc, _x, nil, true), do: dynamic(false)
    defp beyond(:asc, x, nil, false), do: dynamic(not (^null(x)))
    defp beyond(:asc, {b, f} = x, v, true), do: dynamic(field(as(^b), ^f) > ^v or ^null(x))
    defp beyond(:asc, {b, f}, v, false), do: dynamic(field(as(^b), ^f) > ^v)
    defp beyond(:desc, x, nil, true), do: dynamic(not (^null(x)))
    defp beyond(:desc, _x, nil, false), do: dynamic(false)
    defp beyond(:desc, {b, f}, v, true), do: dynamic(field(as(^b), ^f) < ^v)
    defp beyond(:desc, {b, f} = x, v, false), do: dynamic(field(as(^b), ^f) < ^v or ^null(x))

    defp null({b, f}), do: dynamic(is_nil(field(as(^b), ^f)))

    # The rows of a block of the tree, by their ids, with their places. A
    # row the source has not opened may have children: one query tells.
    @impl true
    def nodes(%{segments: segments} = state, offset, limit) when is_list(segments) do
      Group.slice(segments, offset, limit, fn path, from, count ->
        state.query
        |> where_path(path, state.group_columns, state.root)
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

    # A field of the first source, or a path of its schema's associations
    # to a field; one of many values needs one primary key.
    @impl true
    def supports?(state, column) do
      cond do
        not Column.stored?(column) -> false
        not Column.path?(column) -> true
        true -> match?({:ok, _many}, reflect(state, column.field))
      end
    end

    @impl true
    def many?(state, %Column{field: path} = column) do
      Column.path?(column) and match?({:ok, true}, reflect(state, path))
    end

    # One GROUP BY of the query (with the person's other filters and
    # search), the most frequent values first; of many values, the rows
    # that have each.
    @impl true
    def values(state, column, query, columns, opts) do
      columns = known(state, columns)

      case Column.find(columns, column.key) || known(state, [column]) do
        %Column{} = column -> stored_values(state, column, query, columns, opts)
        [%Column{} = column] -> stored_values(state, column, query, columns, opts)
        _unknown -> []
      end
    end

    defp stored_values(state, column, query, columns, opts) do
      if Column.stored?(column), do: group_values(state, column, query, columns, opts), else: []
    end

    defp group_values(state, %Column{field: f} = column, query, columns, opts) do
      {ecto, ref} =
        state.base
        |> where_filters(query.filters, columns, state)
        |> where_search(query.search, columns, state)
        |> expression(state.root, f)

      v = value(ref)

      count =
        if column.many do
          [key] = state.primary_key
          dynamic([r], count(field(r, ^key), :distinct))
        else
          dynamic(count())
        end

      ecto
      |> where_many_value(column, ref)
      |> where_value_search(text(state, ref, f), Keyword.get(opts, :search))
      |> exclude(:order_by)
      |> exclude(:preload)
      |> exclude(:select)
      |> group_by(^[v])
      |> select(^%{value: v, count: count})
      |> order_by(^[desc: count, asc: v])
      |> limit(^Keyword.get(opts, :limit, 50))
      |> state.repo.all(state.repo_opts)
      |> Enum.map(&{&1.value, &1.count})
    end

    # The rows of many values joined: one for each related row that has a
    # value.
    defp where_many_value(ecto, %Column{many: true}, ref),
      do: where(ecto, ^dynamic(not (^null(ref))))

    defp where_many_value(ecto, _column, _ref), do: ecto

    # The rows by their primary key, through the grid's own query: a row
    # outside it is not found.
    @impl true
    def fetch(%{primary_key: [key]} = state, ids, _row_id) do
      state.base
      |> where([r], field(r, ^key) in ^ids)
      |> with_preloads(state)
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
      window = sql_order(order, state.root)

      ranked =
        state.query
        |> exclude(:order_by)
        |> exclude(:preload)
        |> exclude(:select)
        |> windows([r], w: [order_by: ^window])
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

    @doc false
    # The values of an `Ecto.Enum` field of the source's schema, as the
    # wire has them; nil for any other field.
    @spec enum_values(map(), atom() | [atom()]) :: [String.t()] | nil
    def enum_values(%{base: %Ecto.Query{from: %{source: {_table, schema}}}}, field)
        when is_atom(schema) and schema != nil and is_atom(field) do
      schema |> Ecto.Enum.values(field) |> Enum.map(&Atom.to_string/1)
    rescue
      ArgumentError -> nil
    end

    # Of a related row's field: its schema's.
    def enum_values(%{base: %Ecto.Query{from: %{source: {_table, schema}}}}, [_ | _] = path)
        when is_atom(schema) and schema != nil do
      {steps, [field]} = Enum.split(path, -1)

      case related(schema, steps) do
        {:ok, related, _many} -> related |> Ecto.Enum.values(field) |> Enum.map(&Atom.to_string/1)
        :error -> nil
      end
    rescue
      ArgumentError -> nil
    end

    def enum_values(_state, _field), do: nil

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

    defp where_value_search(query, _field, nil), do: query
    defp where_value_search(query, _field, ""), do: query

    defp where_value_search(query, field, text),
      do: where(query, ^like(field, "%" <> escape(text) <> "%"))

    defp primary_key(%Ecto.Query{from: %{source: {_table, schema}}})
         when is_atom(schema) and schema != nil do
      if function_exported?(schema, :__schema__, 1), do: schema.__schema__(:primary_key), else: []
    end

    defp primary_key(_query), do: []

    defp where_filters(query, filters, columns, state) do
      Enum.reduce(filters, query, fn %Filter{key: key} = filter, query ->
        where_filter(query, Column.find(columns, key), filter, state)
      end)
    end

    defp where_filter(query, %Column{many: true, field: path}, filter, state),
      do: where(query, ^has(state, path, filter))

    defp where_filter(query, %Column{field: f} = column, filter, state) do
      if Column.stored?(column) do
        {query, ref} = expression(query, state.root, f)
        where(query, ^condition(ref, filter, text(state, ref, f)))
      else
        query
      end
    end

    defp where_filter(query, nil, _filter, _state), do: query

    # A filter on a field (`{binding, field}`): the field as
    # `field(as(^b), ^f)`, so that a value compared to it takes its type.
    defp condition(x, %Filter{op: :is_nil}), do: null(x)
    defp condition(x, %Filter{op: :not_nil}), do: dynamic(not (^null(x)))
    defp condition(x, %Filter{op: :eq, value: nil}), do: null(x)
    defp condition({b, f}, %Filter{op: :eq, value: v}), do: dynamic(field(as(^b), ^f) == ^v)
    defp condition(x, %Filter{op: :neq, value: nil}), do: dynamic(not (^null(x)))

    defp condition({b, f} = x, %Filter{op: :neq, value: v}),
      do: dynamic(field(as(^b), ^f) != ^v or ^null(x))

    defp condition({b, f}, %Filter{op: :gt, value: v}), do: dynamic(field(as(^b), ^f) > ^v)
    defp condition({b, f}, %Filter{op: :gte, value: v}), do: dynamic(field(as(^b), ^f) >= ^v)
    defp condition({b, f}, %Filter{op: :lt, value: v}), do: dynamic(field(as(^b), ^f) < ^v)
    defp condition({b, f}, %Filter{op: :lte, value: v}), do: dynamic(field(as(^b), ^f) <= ^v)

    defp condition({b, f}, %Filter{op: :between, value: [from, to]}),
      do: dynamic(field(as(^b), ^f) >= ^from and field(as(^b), ^f) <= ^to)

    defp condition({b, f}, %Filter{op: :in, value: values}),
      do: dynamic(field(as(^b), ^f) in ^values)

    # The filters of a text: of the field as a text (`text/3`).
    defp condition(_x, %Filter{op: :contains, value: v}, text),
      do: like(text, "%" <> escape(v) <> "%")

    defp condition(x, %Filter{op: :not_contains, value: v}, text) do
      pattern = "%" <> escape(v) <> "%"
      dynamic(^null(x) or fragment("lower(?) NOT LIKE ? ESCAPE '!'", ^text, ^pattern))
    end

    defp condition(_x, %Filter{op: :starts_with, value: v}, text),
      do: like(text, escape(v) <> "%")

    defp condition(_x, %Filter{op: :ends_with, value: v}, text),
      do: like(text, "%" <> escape(v))

    defp condition(x, filter, _text), do: condition(x, filter)

    defp like(text, pattern), do: dynamic(fragment("lower(?) LIKE ? ESCAPE '!'", ^text, ^pattern))

    # A field as a text, for `lower(?) LIKE`: a field of text as it is
    # (an index on `lower(field)` serves it), any other cast to a text by
    # Ecto, as each database casts (PostgreSQL has no `lower` of a
    # number, a date or a UUID; SQLite and MySQL take one).
    defp text(state, {b, f}, path) do
      if text_field?(state, path),
        do: dynamic(field(as(^b), ^f)),
        else: dynamic(type(field(as(^b), ^f), :string))
    end

    # Whether a field (or the field at the end of a path) is stored as a
    # text: its type is `:string`, or a type of its own over one. A query
    # of no schema is taken as text, as before.
    defp text_field?(%{base: %{from: %{source: {_table, schema}}}}, path)
         when is_atom(schema) and schema != nil do
      {steps, [field]} = path |> List.wrap() |> Enum.split(-1)

      case related(schema, steps) do
        {:ok, related, _many} ->
          type = related.__schema__(:type, field)
          type == nil or Ecto.Type.type(type) == :string

        :error ->
          true
      end
    end

    defp text_field?(_state, _path), do: true

    # A filter of many values: the rows whose keys are, or are not, among
    # those of a subquery of the related rows. "Has all of" counts the
    # values each row has of those.
    defp has(state, path, %Filter{op: op, value: values}) do
      [key] = state.primary_key
      {related, ref} = related_rows(state, path)
      among = condition(ref, %Filter{key: "", op: :in, value: values})
      some = condition(ref, %Filter{key: "", op: :not_nil})

      {ids, among?} =
        case op do
          :in -> {where(related, ^among), true}
          :none_of -> {where(related, ^among), false}
          :not_nil -> {where(related, ^some), true}
          :is_nil -> {where(related, ^some), false}
          :all_of -> {all_of(related, ref, among, values, key), true}
        end

      if among?,
        do: dynamic([r], field(r, ^key) in subquery(ids)),
        else: dynamic([r], field(r, ^key) not in subquery(ids))
    end

    defp all_of(related, ref, among, values, key) do
      n = values |> Enum.uniq() |> length()

      related
      |> where(^among)
      |> group_by([r], field(r, ^key))
      |> having(^dynamic(count(^value(ref), :distinct) == ^n))
    end

    # The keys of the schema's rows joined to their related rows, and the
    # field at the end of the path.
    defp related_rows(%{base: %{from: %{source: {_table, schema}}}, primary_key: [key]}, path) do
      from(r in schema, as: :masu, select: field(r, ^key)) |> expression(:masu, path)
    end

    # `!` escapes the wildcards of LIKE: unlike a backslash, it means the
    # same in the string literals of PostgreSQL, MySQL and SQLite.
    defp escape(text) do
      text
      |> String.downcase()
      |> String.replace("!", "!!")
      |> String.replace("%", "!%")
      |> String.replace("_", "!_")
    end

    defp where_search(query, nil, _columns, _state), do: query

    defp where_search(query, text, columns, state) do
      case for(%Column{searchable: true} = c <- columns, Column.stored?(c), do: c) do
        [] ->
          query

        searched ->
          pattern = "%" <> escape(text) <> "%"

          {query, condition} =
            Enum.reduce(searched, {query, dynamic(false)}, fn column, {query, acc} ->
              {query, found} = found(query, column, pattern, state)
              {query, dynamic(^acc or ^found)}
            end)

          where(query, ^condition)
      end
    end

    # Of many values: the rows that have a value that matches.
    defp found(query, %Column{many: true, field: path}, pattern, state) do
      [key] = state.primary_key
      {related, ref} = related_rows(state, path)
      ids = where(related, ^like(text(state, ref, path), pattern))
      {query, dynamic([r], field(r, ^key) in subquery(ids))}
    end

    defp found(query, %Column{field: f}, pattern, state) do
      {query, ref} = expression(query, state.root, f)
      {query, like(text(state, ref, f), pattern)}
    end

    # The query in the grid's order, and that order as a keyword list, or
    # nil when it is the query's own order_by (which a window cannot copy).
    defp order(query, sorts, columns, %{primary_key: primary_key, root: root}) do
      fields =
        for %Sort{key: key, direction: direction} <- sorts,
            %Column{} = column <- [Column.find(columns, key)],
            Column.stored?(column) and column.many != true,
            do: {direction, column.field}

      query = join_all(query, Enum.map(fields, &elem(&1, 1)))

      case fields do
        # Without an order of its own, a query reads its rows in the order
        # of its primary key: an offset means nothing in no order.
        [] when query.order_bys == [] and primary_key != [] ->
          order = Enum.map(primary_key, &{:asc, &1})
          {order_by(query, ^order), order}

        [] ->
          {query, if(query.order_bys == [], do: [])}

        # The primary key goes the way of the last sort: an index of
        # (a, id) is then read in the order, forwards or backwards.
        fields ->
          {direction, _f} = List.last(fields)

          tiebreak =
            for key <- primary_key, not List.keymember?(fields, key, 1), do: {direction, key}

          order = fields ++ tiebreak
          {query |> exclude(:order_by) |> order_by(^sql_order(order, root)), order}
      end
    end

    # An order of fields and paths (`{direction, field}`) in SQL.
    defp sql_order(order, root),
      do: Enum.map(order, fn {direction, f} -> {direction, value(ref(root, f))} end)

    # The columns the source reads in SQL, each of many values or not; a
    # path the schema does not have is left out (the grid does not sort
    # or filter by it).
    defp known(state, columns) do
      for column <- columns, known = known_column(state, column), do: known
    end

    defp known_column(state, column) do
      if Column.path?(column) do
        case reflect(state, column.field) do
          {:ok, many} -> %{column | many: many}
          :error -> nil
        end
      else
        column
      end
    end

    # The associations of the paths of the columns, preloaded so that each
    # row has its related values: `[customer: :company]`. An association
    # the query preloads through a join of its own is left as it is.
    defp preloads(state, columns) do
      joined = Keyword.keys(state.base.assocs)

      columns
      |> Enum.filter(&Column.path?/1)
      |> Enum.map(fn %Column{field: path} -> Enum.drop(path, -1) end)
      |> Enum.reject(fn [first | _] -> first in joined end)
      |> Enum.uniq()
      |> Enum.map(&nest/1)
    end

    defp nest([assoc]), do: assoc
    defp nest([assoc | rest]), do: [{assoc, nest(rest)}]

    defp with_preloads(query, %{preloads: []}), do: query
    defp with_preloads(query, %{preloads: preloads}), do: preload(query, ^preloads)

    # The query with the joins of the columns' paths of one value.
    defp join_all(query, columns) do
      Enum.reduce(columns, query, fn
        %Column{many: true}, query -> query
        %Column{field: f}, query -> joined(query, f)
        f, query -> joined(query, f)
      end)
    end

    # A column's value in SQL, and the query with the joins it needs: a
    # field of the first source, or of a related row through its path. A
    # sort, a filter, the search, a group and a total each take theirs
    # here.
    defp expression(query, root, f), do: {joined(query, f), ref(root, f)}

    # A field as `{binding, field}`: of the first source (`root`), or of the
    # join of a path.
    defp ref(root, [f]), do: ref(root, f)
    defp ref(root, f) when is_atom(f), do: {root, f}

    defp ref(_root, path) do
      {steps, [f]} = Enum.split(path, -1)
      {binding_name(steps), f}
    end

    defp value({b, f}), do: dynamic(field(as(^b), ^f))

    # A LEFT JOIN for each step of a path, as a named binding (`:customer`,
    # `:customer_company`), unless the query has one of that name.
    defp joined(query, f) when is_atom(f), do: query
    defp joined(query, [_f]), do: query

    defp joined(query, path) do
      steps = Enum.drop(path, -1)

      Enum.reduce(1..length(steps), query, fn n, query ->
        name = steps |> Enum.take(n) |> binding_name()

        cond do
          has_named_binding?(query, name) ->
            query

          n == 1 ->
            join(query, :left, [r], a in assoc(r, ^hd(steps)), as: ^name)

          true ->
            parent = steps |> Enum.take(n - 1) |> binding_name()
            join(query, :left, [{^parent, p}], a in assoc(p, ^Enum.at(steps, n - 1)), as: ^name)
        end
      end)
    end

    defp binding_name([assoc]), do: assoc

    defp binding_name(steps),
      do: steps |> Enum.map_join("_", &Atom.to_string/1) |> String.to_atom()

    # Whether a path is of the schema's associations to a field: `{:ok,
    # many}`, where many says that a step is a has_many or many_to_many
    # (of a schema of one primary key), or :error.
    defp reflect(%{base: %Ecto.Query{from: %{source: {_table, schema}}}} = state, path)
         when is_atom(schema) and schema != nil do
      {steps, [field]} = Enum.split(path, -1)

      with {:ok, related, many} <- related(schema, steps),
           true <- field in related.__schema__(:fields),
           true <- not many or length(state.primary_key) == 1 do
        {:ok, many}
      else
        _other -> :error
      end
    end

    defp reflect(_state, _path), do: :error

    defp related(schema, steps) do
      Enum.reduce_while(steps, {:ok, schema, false}, fn step, {:ok, schema, many} ->
        case schema.__schema__(:association, step) do
          %{related: related, cardinality: cardinality} ->
            {:cont, {:ok, related, many or cardinality == :many}}

          nil ->
            {:halt, :error}
        end
      end)
    end
  end
end

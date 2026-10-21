defmodule Masu.Source.KeysetTest do
  use ExUnit.Case, async: false

  alias Masu.{Column, Query, Sort, Source}
  alias MasuTest.{Item, Repo}

  @columns [
    Column.new(field: :id, type: :integer),
    Column.new(field: :name),
    Column.new(field: :score, type: :integer)
  ]

  defp source(sorts) do
    Item
    |> Source.new(repo: Repo)
    |> Source.prepare(%Query{sorts: sorts}, @columns)
  end

  defp ids(rows), do: Enum.map(rows, & &1.id)

  # The blocks from each offset, read as a grid reads them: the source
  # learns each block's rows (`Source.seen/3`) before the next one.
  defp blocks(source, froms, limit) do
    {blocks, _source} =
      Enum.map_reduce(froms, source, fn from, source ->
        rows = Source.rows(source, from, limit)
        {rows, Source.seen(source, from, rows)}
      end)

    blocks
  end

  # The SQL of the queries that `fun` runs.
  defp queries(fun) do
    test = self()
    handler = "keyset-#{System.unique_integer()}"

    :telemetry.attach(
      handler,
      [:masu_test, :repo, :query],
      fn _event, _measure, meta, _config ->
        send(test, {:query, meta.query})
      end,
      nil
    )

    result = fun.()
    :telemetry.detach(handler)
    {result, collect([])}
  end

  defp collect(acc) do
    receive do
      {:query, sql} -> collect([sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  for sorts <- [
        [],
        [{"name", :asc}],
        [{"name", :desc}],
        [{"score", :asc}, {"name", :desc}],
        [{"score", :desc}, {"name", :asc}],
        [{"name", :desc}, {"score", :desc}]
      ] do
    test "blocks read by key are the rows an OFFSET reads, sorted by #{inspect(sorts)}" do
      sorts =
        Enum.map(unquote(Macro.escape(sorts)), fn {key, direction} -> Sort.new(key, direction) end)

      all = sorts |> source() |> Source.rows(0, 1000) |> ids()
      assert length(all) == 237

      source = source(sorts)
      {blocks, sql} = queries(fn -> blocks(source, 0..236//40, 40) end)

      assert blocks |> List.flatten() |> ids() == all
      # The first block has no OFFSET to follow, the others read by key.
      refute Enum.any?(sql, &(&1 =~ "OFFSET"))
    end
  end

  # PostgreSQL sorts NULLs last when ascending; SQLite and MySQL first.
  defp postgres?, do: MasuTest.DB.adapter() == Ecto.Adapters.Postgres

  # A field in the SQL: `i0."name"`, or with backquotes in MySQL.
  defp column(field) do
    if MasuTest.DB.adapter() == Ecto.Adapters.MyXQL, do: "i0.`#{field}`", else: ~s(i0."#{field}")
  end

  # A comparison with a parameter: `$1` in PostgreSQL, `?` in the others.
  defp comparison(field, op), do: "#{column(field)} #{op} #{if postgres?(), do: "$", else: "?"}"

  test "a block by key has a range on the first sort, which an index reads from" do
    # Ascending in SQLite and MySQL, the 47 items with no score come first;
    # in PostgreSQL, last.
    source = source([Sort.new("score", :asc), Sort.new("name", :desc)])
    {_blocks, [_first, second]} = queries(fn -> blocks(source, [0, 60], 60) end)

    assert second =~ comparison("score", ">=")
  end

  test "a block where the values of the first sort end goes on with its NULLs" do
    # The 33 items with no name come after the others: descending in SQLite
    # and MySQL, ascending in PostgreSQL.
    {direction, op} = if postgres?(), do: {:asc, ">="}, else: {:desc, "<="}
    source = source([Sort.new("name", direction)])
    all = source |> Source.rows(0, 1000) |> ids()

    {blocks, sql} = queries(fn -> blocks(source, [160, 200], 40) end)

    assert blocks |> List.flatten() |> ids() == Enum.slice(all, 160, 80)
    assert [_jump, values, nulls] = sql
    assert values =~ comparison("name", op)
    assert nulls =~ "#{column("name")} IS NULL"
  end

  test "the primary key that ends the order goes the way of the last sort" do
    assert %{state: %{order: [desc: :name, desc: :id]}} = source([Sort.new("name", :desc)])

    assert %{state: %{order: [desc: :score, asc: :name, asc: :id]}} =
             source([Sort.new("score", :desc), Sort.new("name", :asc)])
  end

  test "a jump reads by OFFSET, and the block after it by key" do
    source = source([Sort.new("score", :asc), Sort.new("name", :asc)])
    all = source |> Source.rows(0, 1000) |> ids()

    {[jump, next], sql} = queries(fn -> blocks(source, [120, 150], 30) end)

    assert ids(jump) == Enum.slice(all, 120, 30)
    assert ids(next) == Enum.slice(all, 150, 30)
    assert [first, second] = sql
    assert first =~ "OFFSET"
    refute second =~ "OFFSET"
  end

  test "a new query starts again" do
    source = source([Sort.new("name", :asc)])
    source = Source.seen(source, 0, Source.rows(source, 0, 40))
    other = Source.prepare(source, %Query{sorts: [Sort.new("name", :desc)]}, @columns)

    assert other |> Source.rows(40, 40) |> ids() ==
             other |> Source.rows(0, 80) |> ids() |> Enum.drop(40)
  end

  test "the source keeps its cursors, not the process: a task reads the next block by key" do
    source = source([Sort.new("score", :desc), Sort.new("name", :asc)])
    all = source |> Source.rows(0, 1000) |> ids()

    keys = Process.get_keys()
    source = Source.seen(source, 0, Source.rows(source, 0, 50))
    assert Process.get_keys() == keys

    {next, sql} = queries(fn -> Task.await(Task.async(fn -> Source.rows(source, 50, 50) end)) end)

    assert ids(next) == Enum.slice(all, 50, 50)
    refute Enum.any?(sql, &(&1 =~ "OFFSET"))
  end

  test "with an adapter whose order of NULLs is not known, only the primary key's order reads by key" do
    other = fn sorts ->
      Item
      |> Source.new(repo: MasuTest.OtherRepo)
      |> Source.prepare(%Query{sorts: sorts}, @columns)
    end

    for {sorts, offset?} <- [{[Sort.new("name", :asc)], true}, {[], false}] do
      all = sorts |> source() |> Source.rows(0, 1000) |> ids()
      {blocks, sql} = queries(fn -> blocks(other.(sorts), 0..236//40, 40) end)

      assert blocks |> List.flatten() |> ids() == all
      assert Enum.any?(sql, &(&1 =~ "OFFSET")) == offset?
    end
  end
end

defmodule Masu.Source.KeysetAsyncTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [order_by: 2]
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Masu.Test

  @endpoint MasuTest.Endpoint

  test "a grid that reads in tasks (load={:async}) reads the block after a block by key" do
    {:ok, view, _html} = live(build_conn(), "/keyset")
    render_async(view, 2000)

    test = self()
    handler = "keyset-async-#{System.unique_integer()}"

    :telemetry.attach(
      handler,
      [:masu_test, :repo, :query],
      fn _event, _measure, meta, _config -> send(test, {:query, meta.query}) end,
      nil
    )

    next = ids(view, "items", from: 100, count: 100)
    :telemetry.detach(handler)

    all = MasuTest.Item |> order_by([:name, :id]) |> MasuTest.Repo.all() |> Enum.map(& &1.id)
    assert next == Enum.slice(all, 100, 100)

    assert_received {:query, sql}
    refute sql =~ "OFFSET"
  end
end

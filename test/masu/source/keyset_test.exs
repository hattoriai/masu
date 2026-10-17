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
      {blocks, sql} = queries(fn -> for from <- 0..236//40, do: Source.rows(source, from, 40) end)

      assert blocks |> List.flatten() |> ids() == all
      # The first block has no OFFSET to follow, the others read by key.
      refute Enum.any?(sql, &(&1 =~ "OFFSET"))
    end
  end

  test "a jump reads by OFFSET, and the block after it by key" do
    source = source([Sort.new("score", :asc), Sort.new("name", :asc)])
    all = source |> Source.rows(0, 1000) |> ids()

    {[jump, next], sql} =
      queries(fn -> [Source.rows(source, 120, 30), Source.rows(source, 150, 30)] end)

    assert ids(jump) == Enum.slice(all, 120, 30)
    assert ids(next) == Enum.slice(all, 150, 30)
    assert [first, second] = sql
    assert first =~ "OFFSET"
    refute second =~ "OFFSET"
  end

  test "a new query starts again" do
    source = source([Sort.new("name", :asc)])
    Source.rows(source, 0, 40)
    other = source([Sort.new("name", :desc)])

    assert other |> Source.rows(40, 40) |> ids() ==
             other |> Source.rows(0, 80) |> ids() |> Enum.drop(40)
  end
end

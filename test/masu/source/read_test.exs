defmodule Masu.Source.ReadTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Masu.Test

  alias Masu.{Column, Filter, Query, Sort, Source}
  alias MasuTest.{Item, Repo}

  @endpoint MasuTest.Endpoint

  @columns [
    Column.new(field: :id, type: :integer),
    Column.new(field: :name),
    Column.new(field: :score, type: :integer)
  ]

  # A read of the app's own, which tells the test what it was given.
  defp read(test) do
    fn query, page ->
      send(test, {:read, query, page})
      query |> offset(^page.offset) |> limit(^page.limit) |> Repo.all()
    end
  end

  defp source(read, query) do
    Item
    |> Source.new(repo: Repo, read: read)
    |> Source.prepare(query, @columns)
  end

  test "reads each block with the query, the place, the order and the row before it" do
    query = %Query{
      sorts: [Sort.new("score", :desc)],
      filters: [Filter.new("score", :gte, 3)]
    }

    source = source(read(self()), query)

    first = Source.rows(source, 0, 40)
    assert_received {:read, ecto, %{offset: 0, limit: 40, after: nil, order: order}}
    assert order == [desc: :score, desc: :id]
    assert Enum.all?(Repo.all(ecto), &(&1.score >= 3))

    source = Source.seen(source, 0, first)
    last = List.last(first)

    next = Source.rows(source, 40, 40)
    assert_received {:read, _ecto, %{offset: 40, limit: 40, after: after_row}}
    assert after_row == [score: last.score, id: last.id]

    expected = Item |> where([i], i.score >= 3) |> order_by(desc: :score, desc: :id) |> Repo.all()
    assert Enum.map(first ++ next, & &1.id) == expected |> Enum.take(80) |> Enum.map(& &1.id)
  end

  test "a jump has no row before it" do
    source = source(read(self()), %Query{sorts: [Sort.new("name", :asc)]})
    Source.rows(source, 120, 30)
    assert_received {:read, _ecto, %{offset: 120, after: nil}}
  end

  test "gives what the read gives: a count with the rows, or an error" do
    counted = source(fn _query, _page -> {[], 9} end, %Query{})
    assert Source.window(counted, 0, 10) == {[], 9}

    failing = source(fn _query, _page -> {:error, "the warehouse is down"} end, %Query{})
    assert_raise Masu.Source.Error, fn -> Source.rows(failing, 0, 10) end
  end

  test "the export reads its blocks with it" do
    columns = [Column.new(field: :id, type: :integer)]
    test = self()

    export = %Masu.Export{
      input: Item,
      opts: [repo: Repo, read: read(test)],
      query: %Query{},
      columns: columns,
      all_columns: columns,
      name: "items"
    }

    rows = export |> Masu.Export.blocks() |> Enum.concat()
    assert length(rows) == 237
    assert_received {:read, _ecto, %{offset: 0, limit: 500, after: nil}}
  end

  test "is a function of two arguments, for an Ecto source" do
    assert_raise ArgumentError, ~r/read is a function of two arguments/, fn ->
      Source.new(Item, repo: Repo, read: fn _query -> [] end)
    end

    assert_raise ArgumentError, ~r/read is for an Ecto source/, fn ->
      Source.new([%{id: 1}], read: fn _query, _page -> [] end)
    end
  end

  test "a grid shows the rows its read gives" do
    {:ok, view, _html} = live(build_conn(), "/keyset")

    names = view |> rows("read") |> Enum.map(& &1["name"])
    assert length(names) == 100
    assert Enum.all?(names, &String.starts_with?(&1, "read: "))
  end
end

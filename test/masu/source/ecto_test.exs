defmodule Masu.Source.EctoTest do
  # The repo that test_helper.exs starts (MasuTest.DB), shared with the grid tests.
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Masu.{Column, Query, Source}
  alias MasuTest.{Order, Repo}

  defp columns,
    do: [
      Column.new(field: :number),
      Column.new(field: :customer),
      Column.new(field: :status, type: :enum),
      Column.new(field: :total, type: :decimal),
      Column.new(field: :placed_on, type: :date),
      Column.new(key: "code", value: &String.downcase(&1.number))
    ]

  defp numbers(queryable, opts) do
    {:ok, query} = Query.new(opts, columns())

    queryable
    |> Source.new(repo: Repo)
    |> Source.prepare(query, columns())
    |> Source.rows(0, 100)
    |> Enum.map(& &1.number)
  end

  test "without a sort, the rows come in the order of the primary key" do
    assert numbers(Order, []) == ~w(A-1 A-2 A-3 A-4 A-5 A-6)
  end

  test "sorts in the database, by several columns, with the primary key last" do
    assert numbers(Order, sort: [{:total, :desc}]) == ~w(A-5 A-2 A-4 A-6 A-1 A-3)

    # MySQL's collation sorts text without case: Cyd, acme corp, Acme.
    assert numbers(Order, sort: [:status, {:customer, :desc}]) ==
             if(MasuTest.DB.adapter() == Ecto.Adapters.MyXQL,
               do: ~w(A-5 A-2 A-3 A-4 A-1 A-6),
               else: ~w(A-5 A-2 A-4 A-3 A-1 A-6)
             )
  end

  test "filters and searches in the database, keeping the query's own where" do
    query = from(o in Order, where: o.status != "void")

    assert numbers(query, []) == ~w(A-1 A-2 A-3 A-4 A-5)
    assert numbers(query, filters: [{:customer, :contains, "AC"}]) == ~w(A-1 A-4)
    assert numbers(query, filters: [{:customer, :starts_with, "a"}]) == ~w(A-1 A-4)
    assert numbers(query, filters: [{:customer, :ends_with, "%"}]) == ~w(A-5)
    assert numbers(query, filters: [{:customer, :contains, "_"}]) == []
    assert numbers(query, filters: [{:total, :gte, "100"}]) == ~w(A-2 A-4 A-5)

    assert numbers(query, filters: [{:placed_on, :between, ["2026-01-02", "2026-01-03"]}]) ==
             ~w(A-2 A-3)

    assert numbers(query, filters: [{:status, :in, ["paid", "late"]}]) == ~w(A-1 A-2 A-3 A-4)
    assert numbers(query, filters: [{:status, :neq, "paid"}]) == ~w(A-2 A-5)
    assert numbers(query, search: "bob") == ~w(A-2)
  end

  test "searches and filters a field that is not text as text, on each database" do
    # Columns without a type are of text: each is searched, here a number
    # and a date. PostgreSQL has no lower() of either.
    columns = [Column.new(field: :id), Column.new(field: :placed_on)]

    run = fn opts ->
      {:ok, query} = Query.new(opts, columns)

      Order
      |> Source.new(repo: Repo)
      |> Source.prepare(query, columns)
      |> Source.rows(0, 100)
      |> Enum.map(& &1.id)
    end

    orders = Repo.all(from(o in Order, order_by: o.id))
    text? = fn order, text -> String.contains?("#{order.id} #{order.placed_on}", text) end

    assert run.(search: "3") == for(o <- orders, text?.(o, "3"), do: o.id)
    assert run.(search: "-01-0") == for(o <- orders, text?.(o, "-01-0"), do: o.id)
    assert run.(filters: [{:id, :contains, "2"}]) == for(o <- orders, "#{o.id}" =~ "2", do: o.id)

    assert run.(filters: [{:id, :not_contains, "2"}]) ==
             for(o <- orders, not ("#{o.id}" =~ "2"), do: o.id)

    {:ok, query} = Query.new([], columns)
    source = Order |> Source.new(repo: Repo) |> Source.prepare(query, columns)
    values = Source.values(source, hd(columns), query, columns, search: "5")
    assert Enum.map(values, &elem(&1, 0)) == for(o <- orders, "#{o.id}" =~ "5", do: o.id)
  end

  test "counts the query, and reads one block at a time" do
    {:ok, query} = Query.new([filters: [{:status, :eq, "paid"}]], columns())
    source = Order |> Source.new(repo: Repo) |> Source.prepare(query, columns())

    assert Source.count(source) == 3
    assert source |> Source.rows(1, 1) |> Enum.map(& &1.number) == ["A-3"]
  end

  test "a column of a value function does not sort or filter in the database" do
    source = Source.new(Order, repo: Repo)

    refute Source.supports?(source, Column.find(columns(), "code"))
    assert Source.supports?(source, Column.find(columns(), "total"))
  end

  test "needs a repo" do
    assert_raise ArgumentError, ~r/needs a :repo/, fn -> Source.new(Order, []) end
    assert_raise ArgumentError, ~r/takes a list of rows/, fn -> Source.new(:nope, repo: Repo) end
  end
end

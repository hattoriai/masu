defmodule Masu.Source.ListTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Masu.{Column, Query, Source}

  defp columns,
    do: [
      Column.new(field: :name),
      Column.new(field: :age, type: :integer),
      Column.new(field: :city),
      Column.new(key: "initial", value: &String.first(&1.name))
    ]

  @rows [
    %{id: 1, name: "Ada", age: 36, city: "London"},
    %{id: 2, name: "bob", age: nil, city: "Lisbon"},
    %{id: 3, name: "Cy", age: 36, city: nil},
    %{id: 4, name: "Dee", age: 20, city: "london"}
  ]

  defp ids(source, opts) do
    {:ok, query} = Query.new(opts, columns())

    source
    |> Source.prepare(query, columns())
    |> Source.rows(0, 100)
    |> Enum.map(& &1.id)
  end

  test "sorts by several columns, nil last in both directions, equal rows in list order" do
    source = Source.new(@rows, [])

    assert ids(source, sort: [:age]) == [4, 1, 3, 2]
    assert ids(source, sort: [{:age, :desc}]) == [1, 3, 4, 2]
    assert ids(source, sort: [{:age, :desc}, {:name, :desc}]) == [3, 1, 4, 2]
    assert ids(source, sort: [:name]) == [1, 2, 3, 4]
    assert ids(source, sort: ["initial"]) == [1, 2, 3, 4]
    assert ids(source, []) == [1, 2, 3, 4]
  end

  test "filters and searches, without case for text" do
    source = Source.new(@rows, [])

    assert ids(source, filters: [{:city, :eq, "London"}]) == [1]
    assert ids(source, filters: [{:city, :starts_with, "lo"}]) == [1, 4]
    assert ids(source, filters: [{:city, :is_nil}]) == [3]
    assert ids(source, filters: [{:city, :neq, "London"}]) == [2, 3, 4]
    assert ids(source, filters: [{:age, :between, [20, 36]}]) == [1, 3, 4]
    assert ids(source, filters: [{:age, :in, [20, 99]}]) == [4]
    assert ids(source, filters: [{:age, :gt, 20}, {:city, :not_nil}]) == [1]
    assert ids(source, search: "LIS") == [2]
  end

  test "counts and reads blocks of the query" do
    {:ok, query} = Query.new([filters: [{:age, :not_nil}]], columns())
    source = @rows |> Source.new([]) |> Source.prepare(query, columns())

    assert Source.count(source) == 3
    assert source |> Source.rows(1, 5) |> Enum.map(& &1.id) == [3, 4]
    assert Source.rows(source, 3, 5) == []
    assert Source.rows(source, 10, 5) == []
  end

  property "a sort by one integer column is the order of Enum.sort_by, stable" do
    check all(ages <- list_of(one_of([integer(0..20), constant(nil)]), max_length: 60)) do
      rows =
        ages
        |> Enum.with_index()
        |> Enum.map(fn {age, id} -> %{id: id, name: "x", age: age, city: nil} end)

      expected = rows |> Enum.sort_by(&{is_nil(&1.age), &1.age}) |> Enum.map(& &1.id)

      assert ids(Source.new(rows, []), sort: [:age]) == expected
    end
  end

  property "two sorts in any direction give the order of Masu.Value.compare/2, decimals exactly" do
    value =
      one_of([
        constant(nil),
        map(integer(-3..3), &Decimal.new/1),
        # Decimals that floats cannot tell apart.
        map(integer(0..3), &Decimal.add(Decimal.new("0.1000000000000000001"), &1))
      ])

    check all(
            values <-
              list_of(
                tuple({value, one_of([string(:alphanumeric, max_length: 2), constant(nil)])}),
                max_length: 40
              ),
            dirs <- tuple({member_of([:asc, :desc]), member_of([:asc, :desc])})
          ) do
      columns = [Column.new(field: :d, type: :decimal), Column.new(field: :t)]
      rows = values |> Enum.with_index() |> Enum.map(fn {{d, t}, id} -> %{id: id, d: d, t: t} end)
      {dir_d, dir_t} = dirs

      {:ok, query} = Query.new([sort: [{:d, dir_d}, {:t, dir_t}]], columns)

      got =
        rows
        |> Source.new([])
        |> Source.prepare(query, columns)
        |> Source.rows(0, 100)
        |> Enum.map(& &1.id)

      expected =
        Enum.sort(rows, fn a, b ->
          reference_before?([a.d, a.t], [b.d, b.t], [dir_d, dir_t])
        end)
        |> Enum.map(& &1.id)

      assert got == expected
    end
  end

  # The order by comparisons, one pair of rows at a time.
  defp reference_before?([], [], []), do: true

  defp reference_before?([a | as], [b | bs], [direction | directions]) do
    case Masu.Value.compare(a, b) do
      :eq -> reference_before?(as, bs, directions)
      :lt -> direction == :asc or is_nil(b)
      :gt -> direction == :desc and not is_nil(a)
    end
  end
end

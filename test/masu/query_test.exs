defmodule Masu.QueryTest do
  use ExUnit.Case, async: true

  alias Masu.{Column, Filter, Query, Sort}

  @columns [
    Column.new(field: :name),
    Column.new(field: :age, type: :integer),
    Column.new(field: :born, type: :date),
    Column.new(field: :total, type: :decimal),
    Column.new(field: :secret, sortable: false, filterable: false)
  ]

  test "from_wire/2 reads sorts, filters and a search" do
    assert {:ok, query} =
             Query.from_wire(
               %{
                 "sorts" => [
                   %{"key" => "age", "dir" => "desc"},
                   %{"key" => "name", "dir" => "asc"}
                 ],
                 "filters" => [
                   %{"key" => "born", "op" => "gte", "value" => "1900-01-01"},
                   %{"key" => "age", "op" => "between", "value" => ["18", 65]},
                   %{"key" => "total", "op" => "lt", "value" => "10.5"}
                 ],
                 "search" => "  ada "
               },
               @columns
             )

    assert query.sorts == [Sort.new("age", :desc), Sort.new("name")]

    assert [
             %Filter{key: "born", op: :gte, value: ~D[1900-01-01]},
             %Filter{key: "age", op: :between, value: [18, 65]},
             %Filter{key: "total", op: :lt, value: total}
           ] = query.filters

    assert Decimal.equal?(total, Decimal.new("10.5"))
    assert query.search == "ada"
  end

  test "sorts on unknown or unsortable columns, and repeated ones, are left out" do
    {:ok, query} =
      Query.from_wire(
        %{
          "sorts" => [
            %{"key" => "secret", "dir" => "asc"},
            %{"key" => "nope", "dir" => "asc"},
            %{"key" => "age", "dir" => "asc"},
            %{"key" => "age", "dir" => "desc"}
          ]
        },
        @columns
      )

    assert query.sorts == [Sort.new("age")]
  end

  test "a filter that does not check is an error" do
    assert {:error, "There is no column \"nope\"."} =
             Query.from_wire(
               %{"filters" => [%{"key" => "nope", "op" => "eq", "value" => 1}]},
               @columns
             )

    assert {:error, "The column \"secret\" does not filter."} =
             Query.from_wire(
               %{"filters" => [%{"key" => "secret", "op" => "eq", "value" => 1}]},
               @columns
             )

    assert {:error, "The filter contains is for text, not integer."} =
             Query.from_wire(
               %{"filters" => [%{"key" => "age", "op" => "contains", "value" => "1"}]},
               @columns
             )

    assert {:error, "The value \"old\" is not of the type integer."} =
             Query.from_wire(
               %{"filters" => [%{"key" => "age", "op" => "gt", "value" => "old"}]},
               @columns
             )

    assert {:error, "Not a filter operator: \"like\"."} =
             Query.from_wire(
               %{"filters" => [%{"key" => "name", "op" => "like", "value" => "a"}]},
               @columns
             )

    assert {:error, _} = Query.from_wire(%{"sorts" => "age"}, @columns)

    assert {:error, _} =
             Query.from_wire(%{"sorts" => [%{"key" => "age", "dir" => "up"}]}, @columns)
  end

  test "fit/2 keeps the filters it cast: the rows of a controlled grid come again" do
    {:ok, query} =
      Query.new(
        [
          filters: [
            {"age", :gt, "30"},
            {"born", :lt, "1900-01-01"},
            {"total", :gte, "120.50"},
            {"total", :between, ["1", "2.5"]}
          ]
        ],
        @columns
      )

    assert Query.fit(query, @columns) == {query, []}
  end

  test "new/2 takes Elixir terms, and to_wire/1 gives them back" do
    assert {:ok, query} =
             Query.new(
               [
                 sort: [{:age, :desc}, :name],
                 filters: [{:name, :starts_with, "a"}, {:born, :not_nil}]
               ],
               @columns
             )

    assert Query.to_wire(query) == %{
             "sorts" => [%{"key" => "age", "dir" => "desc"}, %{"key" => "name", "dir" => "asc"}],
             "filters" => [
               %{"key" => "name", "op" => "starts_with", "value" => "a"},
               %{"key" => "born", "op" => "not_nil", "value" => nil}
             ],
             "search" => nil,
             "groups" => []
           }

    assert {:ok, ^query} = Query.from_wire(Query.to_wire(query), @columns)
  end
end

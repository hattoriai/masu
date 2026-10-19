defmodule Masu.Source.RelatedTest do
  # Columns of related rows (`field={[:customer, :name]}`) in the SQLite
  # repo of test_helper.exs. The same queries run by hand on PostgreSQL
  # and MySQL: see `MasuTest.Sales`.
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Masu.{Column, Filter, Query, Sort, Source}
  alias Masu.Source.Ecto, as: EctoSource
  alias MasuTest.{Repo, Sale}

  defp columns,
    do: [
      Column.new(field: :number),
      Column.new(field: :amount, type: :integer, aggregate: :sum),
      Column.new(field: [:customer, :name], searchable: true),
      Column.new(field: [:customer, :company, :name], key: "company"),
      Column.new(field: [:customer, :company, :size], key: "size", type: :enum),
      Column.new(field: [:tags, :name], key: "tags", type: :enum, many: true, searchable: true),
      Column.new(field: [:lines, :product], key: "products", many: true)
    ]

  defp source(queryable \\ Sale, opts) do
    {:ok, query} = Query.new(opts, columns())
    queryable |> Source.new(repo: Repo) |> Source.prepare(query, columns())
  end

  # NULL comes first in SQLite and MySQL, last in PostgreSQL.
  defp nulls(list, nulls) do
    if Repo.__adapter__() == Ecto.Adapters.Postgres, do: list ++ nulls, else: nulls ++ list
  end

  defp numbers(queryable \\ Sale, opts),
    do: queryable |> source(opts) |> Source.rows(0, 100) |> Enum.map(& &1.number)

  # The blocks from each offset, as a grid reads them: the source learns
  # each block's rows before the next one, and reads it by key.
  defp blocks(source, size) do
    Stream.unfold({source, 0}, fn {source, from} ->
      case Source.rows(source, from, size) do
        [] -> nil
        rows -> {rows, {Source.seen(source, from, rows), from + length(rows)}}
      end
    end)
    |> Enum.flat_map(& &1)
  end

  describe "a column of a related row's field" do
    test "reads the value through the path, nil where there is no related row" do
      column = Column.find(columns(), "customer.name")
      assert column.label == "Customer name"
      assert Column.path?(column) and Column.stored?(column)

      rows = Source.rows(source([]), 0, 100)

      assert Enum.map(rows, &Column.get(column, &1)) ==
               ~w(Bea Ana) ++ [nil] ++ ~w(Dora Ana Cid Eve)

      company = Column.find(columns(), "company")

      assert Enum.map(rows, &Column.get(company, &1)) == [
               "Globex",
               "Acme",
               nil,
               "Initech",
               "Acme",
               nil,
               "Acme"
             ]
    end

    test "sorts with a LEFT JOIN, NULL where the database puts it, the primary key last" do
      assert numbers(sort: [{"customer.name", :asc}]) ==
               nulls(~w(S-2 S-5 S-1 S-6 S-4 S-7), ["S-3"])

      assert numbers(sort: [{"customer.name", :desc}]) ==
               Enum.reverse(nulls(~w(S-2 S-5 S-1 S-6 S-4 S-7), ["S-3"]))

      assert numbers(sort: [{"company", :asc}, {"number", :desc}]) ==
               nulls(~w(S-7 S-5 S-2 S-1 S-4), ~w(S-6 S-3))
    end

    test "reads every block by key in the order of a path, as a whole read gives it" do
      for sorts <- [
            [{"customer.name", :asc}],
            [{"customer.name", :desc}],
            [{"company", :asc}, {"amount", :desc}],
            [{"company", :desc}]
          ],
          size <- [1, 2, 3] do
        source = source(sort: sorts)
        whole = source |> Source.rows(0, 100) |> Enum.map(& &1.id)
        assert source |> blocks(size) |> Enum.map(& &1.id) == whole, inspect({sorts, size})
      end
    end

    test "keeps the cursor of each block: a block is read by key, not by offset" do
      source = source(sort: [{"customer.name", :asc}])
      rows = Source.rows(source, 0, 3)
      seen = Source.seen(source, 0, rows)
      assert Map.has_key?(seen.state.cursors, 3)
    end

    test "filters with the join, nested too" do
      assert numbers(filters: [{"customer.name", :eq, "Ana"}]) == ~w(S-2 S-5)
      assert numbers(filters: [{"customer.name", :in, ["Ana", "Bea"]}]) == ~w(S-1 S-2 S-5)
      assert numbers(filters: [{"customer.name", :contains, "D"}]) == ~w(S-4 S-6)
      assert numbers(filters: [{"customer.name", :is_nil, nil}]) == ~w(S-3)
      assert numbers(filters: [{"company", :eq, "Acme"}]) == ~w(S-2 S-5 S-7)
      assert numbers(filters: [{"company", :is_nil, nil}]) == ~w(S-3 S-6)
      assert numbers(filters: [{"company", :neq, "Acme"}]) == ~w(S-1 S-3 S-4 S-6)
      assert numbers(filters: [{"size", :in, ["small"]}]) == ~w(S-1 S-4)
    end

    test "searches the related field" do
      assert numbers(search: "dor") == ~w(S-4)
    end

    test "uses a join of the same name that the query has" do
      query =
        from(s in Sale,
          join: c in assoc(s, :customer),
          as: :customer,
          where: c.name != "Eve"
        )

      assert numbers(query, sort: [{"customer.name", :asc}]) == ~w(S-2 S-5 S-1 S-6 S-4)
      assert length(source(query, sort: [{"customer.name", :asc}]).state.query.joins) == 1
    end

    test "joins only when a sort, a filter, the search or a group needs it" do
      assert source([]).state.query.joins == []
      assert length(source(sort: [{"company", :asc}]).state.query.joins) == 2
    end

    test "groups and totals by a path, with the counts" do
      {:ok, query} = Query.new([group_by: ["company"]], columns())
      source = Sale |> Source.new(repo: Repo) |> Source.prepare(query, columns())

      groups = for {:group, group, _info} <- source.state.segments, do: group

      assert Enum.map(groups, &{&1.value, &1.count}) ==
               nulls([{"Acme", 3}, {"Globex", 1}, {"Initech", 1}], [{nil, 2}])

      # A sum is a decimal in MySQL.
      assert to_string(Source.totals(source)["amount"]) == "210"

      # An open group's rows, after its own row, by the path's value.
      acme = Enum.find(groups, &(&1.value == "Acme"))
      at = Enum.find_index(groups, &(&1 == acme)) + 1
      open = %{query | expanded: MapSet.new([Masu.Group.id(acme)])}
      source = Sale |> Source.new(repo: Repo) |> Source.prepare(open, columns())
      assert source |> Source.rows(at, 3) |> Enum.map(& &1.number) == ~w(S-2 S-5 S-7)
    end

    test "the menu of values: each value and how many rows have it" do
      source = Source.new(Sale, repo: Repo)
      column = Column.find(columns(), "customer.name")

      assert Source.values(source, column, %Query{}, columns(), []) ==
               [{"Ana", 2} | nulls([{"Bea", 1}, {"Cid", 1}, {"Dora", 1}, {"Eve", 1}], [{nil, 1}])]

      assert Source.values(source, column, %Query{}, columns(), search: "a") ==
               [{"Ana", 2}, {"Bea", 1}, {"Dora", 1}]
    end

    test "a column of a value function has no values to count" do
      source = Source.new(Sale, repo: Repo)
      column = Column.new(key: "code", value: &String.downcase(&1.number))
      assert Source.values(source, column, %Query{}, [column | columns()], []) == []
    end

    test "the values of an enum of a related schema" do
      state = Source.new(Sale, repo: Repo).state
      assert EctoSource.enum_values(state, [:customer, :company, :size]) == ~w(small large)
    end

    test "the selection is a query of the schema's rows, without the joins" do
      {:ok, query} = Query.new([filters: [{"company", :eq, "Acme"}]], columns())
      source = Source.new(Sale, repo: Repo)
      {:query, selected} = Source.select_all(source, query, columns(), [5], & &1.id)

      assert selected.joins == []
      assert selected |> Repo.all() |> Enum.map(& &1.number) |> Enum.sort() == ~w(S-2 S-7)

      # An update of the selection runs in each database (MySQL refuses a
      # subquery of the table it updates, but for a derived table).
      Repo.transaction(fn ->
        assert {2, _} = Repo.update_all(selected, set: [amount: 0])
        Repo.rollback(:done)
      end)
    end

    test "finds a row's place in the order of a path" do
      source = source(sort: [{"customer.name", :asc}])
      place = Enum.find_index(nulls(~w(S-2 S-5 S-1), ["S-3"]), &(&1 == "S-1"))
      assert Source.locate(source, 1, & &1.id) == place
    end

    test "a path the schema does not have does not sort or filter" do
      source = Source.new(Sale, repo: Repo)

      assert Source.supports?(source, Column.new(field: [:customer, :name]))
      refute Source.supports?(source, Column.new(field: [:customer, :nope]))
      refute Source.supports?(source, Column.new(field: [:nope, :name]))
      refute Source.many?(source, Column.new(field: [:customer, :company, :name]))
      assert Source.many?(source, Column.new(field: [:tags, :name]))
    end
  end

  describe "a column of many values" do
    test "shows the values of each row's related rows" do
      tags = Column.find(columns(), "tags")
      rows = Source.rows(source([]), 0, 100)

      assert Enum.map(rows, &Enum.sort(Column.get(tags, &1))) ==
               [~w(gift urgent), ~w(gift), [], ~w(bulk urgent), ~w(bulk gift urgent), [], []]

      assert Column.wire(tags, hd(rows)) |> Enum.sort() == ~w(gift urgent)
    end

    test "filters by has any of, all of, none of, none and some, without repeating rows" do
      assert numbers(filters: [{"tags", :in, ["urgent", "gift"]}]) == ~w(S-1 S-2 S-4 S-5)
      assert numbers(filters: [{"tags", :all_of, ["urgent", "gift"]}]) == ~w(S-1 S-5)
      assert numbers(filters: [{"tags", :all_of, ["urgent", "urgent"]}]) == ~w(S-1 S-4 S-5)
      assert numbers(filters: [{"tags", :none_of, ["urgent"]}]) == ~w(S-2 S-3 S-6 S-7)
      assert numbers(filters: [{"tags", :is_nil, nil}]) == ~w(S-3 S-6 S-7)
      assert numbers(filters: [{"tags", :not_nil, nil}]) == ~w(S-1 S-2 S-4 S-5)
      assert numbers(filters: [{"products", :in, ["pen"]}]) == ~w(S-1 S-2)

      assert Source.count(source(filters: [{"tags", :in, ["urgent", "gift"]}])) == 4
    end

    test "refuses the operators of one value" do
      assert {:error, _} = Filter.cast(Filter.new("tags", :eq, "gift"), columns())
      assert {:error, _} = Filter.cast(Filter.new("customer.name", :all_of, ["a"]), columns())
    end

    test "the search matches any of the values" do
      assert numbers(search: "bul") == ~w(S-4 S-5)
    end

    test "does not sort: a sort by it keeps the order of the primary key" do
      column = Column.find(columns(), "tags")
      query = %Query{sorts: [%Sort{key: column.key, direction: :asc}]}
      source = Sale |> Source.new(repo: Repo) |> Source.prepare(query, columns())
      assert source |> Source.rows(0, 100) |> Enum.map(& &1.id) == Enum.to_list(1..7)
    end

    test "the menu of values: how many rows have each" do
      source = Source.new(Sale, repo: Repo)
      column = Column.find(columns(), "tags")
      {:ok, query} = Query.new([filters: [{"amount", :gte, 20}]], columns())

      assert Source.values(source, column, %Query{}, columns(), []) ==
               [{"gift", 3}, {"urgent", 3}, {"bulk", 2}]

      assert Source.values(source, column, query, columns(), []) ==
               [{"urgent", 3}, {"bulk", 2}, {"gift", 2}]
    end

    test "the selection keeps the filter as a subquery" do
      {:ok, query} = Query.new([filters: [{"tags", :all_of, ["gift", "urgent"]}]], columns())

      {:query, selected} =
        Source.select_all(Source.new(Sale, repo: Repo), query, columns(), [], & &1.id)

      assert selected |> Repo.all() |> Enum.map(& &1.number) |> Enum.sort() == ~w(S-1 S-5)
    end
  end

  describe "a list's rows" do
    defp list_rows, do: Sale |> Repo.all() |> Repo.preload([:tags, :lines, customer: :company])

    defp list_numbers(opts) do
      {:ok, query} = Query.new(opts, columns())
      source = Source.new(list_rows(), [])
      columns = Enum.map(columns(), &%{&1 | many: Source.many?(source, &1)})

      source
      |> Source.prepare(query, columns)
      |> Source.rows(0, 100)
      |> Enum.map(& &1.number)
    end

    test "sort, filter and search through the paths as the database does" do
      # A list puts nil last and compares text without case.
      assert list_numbers(sort: [{"customer.name", :asc}]) == ~w(S-2 S-5 S-1 S-6 S-4 S-7 S-3)
      assert list_numbers(filters: [{"company", :eq, "Acme"}]) == ~w(S-2 S-5 S-7)
      assert list_numbers(filters: [{"tags", :all_of, ["urgent", "gift"]}]) == ~w(S-1 S-5)
      assert list_numbers(filters: [{"tags", :none_of, ["urgent"]}]) == ~w(S-2 S-3 S-6 S-7)
      assert list_numbers(filters: [{"tags", :is_nil, nil}]) == ~w(S-3 S-6 S-7)
      assert list_numbers(search: "bul") == ~w(S-4 S-5)
    end

    test "a path through several rows is of many values" do
      source = Source.new(list_rows(), [])
      assert Source.many?(source, Column.new(field: [:tags, :name]))
      refute Source.many?(source, Column.new(field: [:customer, :name]))
    end

    test "the values of many: how many rows have each" do
      source = Source.new(list_rows(), [])
      column = %{Column.find(columns(), "tags") | many: true}

      assert Source.values(source, column, %Query{}, columns(), []) ==
               [{"gift", 3}, {"urgent", 3}, {"bulk", 2}]
    end
  end

  describe "a source of your own" do
    defmodule Own do
      @behaviour Masu.Source
      def init(rows, _opts), do: rows
      def prepare(rows, _query, _columns), do: rows
      def count(rows), do: length(rows)
      def rows(rows, offset, limit), do: Enum.slice(rows, offset, limit)
    end

    test "does not sort or filter by a path unless it says so" do
      source = Source.new({Own, []}, [])
      refute Source.supports?(source, Column.new(field: [:customer, :name]))
      assert Source.supports?(source, Column.new(field: :number))
      refute Source.many?(source, Column.new(field: [:tags, :name]))
      assert Source.many?(source, Column.new(field: [:tags, :name], many: true))
    end

    test "a controlled grid's rows sort and filter by a path: the LiveView runs the query" do
      source = Source.new({Masu.Source.Given, []}, [])
      assert Source.supports?(source, Column.new(field: [:customer, :name]))
    end
  end
end

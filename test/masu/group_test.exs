defmodule Masu.GroupTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Masu.Test

  @endpoint MasuTest.Endpoint

  defp open(source, params \\ ""),
    do: build_conn() |> live("/groups?source=#{source}#{params}") |> elem(1)

  defp summary(view),
    do: view |> groups("orders") |> Enum.map(&{&1.value, &1.count, &1.totals["total"]})

  # SQLite sums decimals as floats: the totals are compared as numbers.
  defp number(nil), do: nil

  defp number(text),
    do: text |> Decimal.new() |> Decimal.normalize() |> Decimal.to_string(:normal)

  describe "Masu.Group.aggregates/2" do
    alias Masu.{Column, Group}

    test "decimals add up exactly; nil is not a value" do
      rows = [
        %{n: Decimal.new("0.1"), d: ~D[2026-01-02]},
        %{n: Decimal.new("0.2"), d: nil},
        %{n: nil, d: ~D[2026-01-01]}
      ]

      columns = [
        Column.new(field: :n, type: :decimal, aggregate: :sum),
        Column.new(field: :d, type: :date, aggregate: :min, key: "first"),
        Column.new(value: & &1.n, key: "avg", type: :decimal, aggregate: :avg),
        Column.new(value: & &1.n, key: "count", aggregate: :count),
        Column.new(value: &(&1.d && &1.d.year), key: "years", aggregate: :count_distinct),
        Column.new(value: & &1, key: "rows", aggregate: &length/1)
      ]

      assert %{
               "n" => sum,
               "first" => ~D[2026-01-01],
               "avg" => avg,
               "count" => 2,
               "years" => 1,
               "rows" => 3
             } =
               Group.aggregates(rows, columns)

      assert Decimal.equal?(sum, Decimal.new("0.3"))
      assert Decimal.equal?(avg, Decimal.new("0.15"))
    end

    test "a column of no values totals to nil, and a count to 0" do
      columns = [Column.new(field: :n, aggregate: :sum), Column.new(field: :m, aggregate: :count)]
      assert Group.aggregates([%{n: nil, m: nil}], columns) == %{"n" => nil, "m" => 0}
    end

    test "an unknown aggregate is refused" do
      assert_raise ArgumentError, ~r/aggregate is one of/, fn ->
        Column.new(field: :n, aggregate: :median)
      end
    end
  end

  for source <- ["list", "ecto"] do
    describe "grouping #{source} rows" do
      @source source

      test "groups show their value, count and totals, closed, and open on their rows" do
        view = open(@source, "&group=status")

        assert [
                 {"draft", 1, _},
                 {"late", 1, _},
                 {"paid", 3, paid},
                 {"void", 1, _}
               ] = summary(view)

        assert number(paid) == "139.99"
        assert total(view, "orders") == 4

        assert [%{totals: %{"placed_on" => "2026-01-04"}} | _] =
                 Enum.drop(groups(view, "orders"), 2)

        expand(view, "orders", ["masu-group", "status", "paid"])
        assert total(view, "orders") == 7

        assert view |> rows("orders") |> Enum.slice(3, 3) |> Enum.map(& &1["number"]) == [
                 "A-1",
                 "A-3",
                 "A-4"
               ]

        assert [%{level: 0, expanded: true}] =
                 view
                 |> nodes("orders")
                 |> Enum.filter(&(&1.id == ["masu-group", "status", "paid"]))

        assert view |> nodes("orders") |> Enum.at(3) |> Map.take([:level, :children]) == %{
                 level: 1,
                 children: false
               }

        collapse(view, "orders", ["masu-group", "status", "paid"])
        assert total(view, "orders") == 4
      end

      test "groups sort by their value, or by a total" do
        view = open(@source, "&group=status")

        sort(view, "orders", {"status", :desc})
        assert view |> summary() |> Enum.map(&elem(&1, 0)) == ["void", "paid", "late", "draft"]

        sort(view, "orders", {"total", :desc})
        assert view |> summary() |> Enum.map(&elem(&1, 0)) == ["draft", "late", "paid", "void"]
      end

      test "a filter counts and totals what it keeps; * opens every group" do
        view = open(@source, "&group=status")
        filter(view, "orders", [{"status", :neq, "void"}])
        assert view |> summary() |> Enum.map(&elem(&1, 0)) == ["draft", "late", "paid"]
        assert number(totals(view, "orders")["total"]) == "1389.49"

        expand_siblings(view, "orders", ["masu-group", "status", "late"])
        assert total(view, "orders") == 8
      end

      test "groups of groups" do
        view = open(@source, "&group=status,customer")
        expand(view, "orders", ["masu-group", "status", "paid"])

        # A list sorts text without case; SQLite by its collation.
        customers =
          if @source == "list",
            do: ["Acme", "acme corp", "Cyd"],
            else: ["Acme", "Cyd", "acme corp"]

        assert view |> groups("orders") |> Enum.map(&{&1.level, &1.value}) ==
                 [{0, "draft"}, {0, "late"}, {0, "paid"}] ++
                   Enum.map(customers, &{1, &1}) ++ [{0, "void"}]

        expand(view, "orders", ["masu-group", "status", "paid", "customer", "Cyd"])
        # The rows of the open group (groups' rows have no number).
        assert view |> rows("orders") |> Enum.map(& &1["number"]) |> Enum.reject(&is_nil/1) == [
                 "A-3"
               ]
      end

      test "expanded={:all} starts every group open; a group closed stays closed" do
        view = open(@source, "&group=status,customer&open=all")
        # 4 statuses, 6 customers in them and their 6 orders.
        assert total(view, "orders") == 16
        assert view |> nodes("orders") |> Enum.filter(& &1.children) |> Enum.all?(& &1.expanded)

        collapse(view, "orders", ["masu-group", "status", "paid"])
        assert total(view, "orders") == 10

        filter(view, "orders", [{"status", :neq, "void"}])
        assert total(view, "orders") == 7

        expand(view, "orders", ["masu-group", "status", "paid"])
        assert total(view, "orders") == 13

        # Grouped by another column from the header menu: open too.
        group(view, "orders", ["customer"])
        assert view |> groups("orders") |> Enum.all?(& &1.expanded)
        # The groups, and the 5 orders the filter keeps.
        assert total(view, "orders") == length(groups(view, "orders")) + 5
      end

      test "expanded with keys starts the groups of those columns open" do
        view = open(@source, "&group=status,customer&open=status")
        assert total(view, "orders") == 10

        assert view |> groups("orders") |> Enum.map(&{&1.level, &1.expanded}) |> Enum.uniq() ==
                 [{0, true}, {1, false}]

        group(view, "orders", ["customer"])
        refute view |> groups("orders") |> Enum.any?(& &1.expanded)
      end

      test "the totals of the query, grouped or not, and grouping from the header menu" do
        view = open(@source)
        assert number(totals(view, "orders")["total"]) == "1439.49"
        assert totals(view, "orders")["placed_on"] == "2026-01-06"
        assert total(view, "orders") == 6

        group(view, "orders", ["status"])
        assert total(view, "orders") == 4
        assert view(view, "orders")["group"] == "status"

        group(view, "orders", [])
        assert total(view, "orders") == 6
      end
    end
  end
end

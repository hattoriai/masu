defmodule Masu.FilterOpsTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Masu.Test

  alias Masu.{Column, Filter, Query}

  @endpoint MasuTest.Endpoint

  defp column(view, key) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#people")
    |> LazyHTML.attribute("data-masu")
    |> hd()
    |> JSON.decode!()
    |> Map.fetch!("columns")
    |> Enum.find(&(&1["key"] == key))
  end

  defp query(view, filters) do
    view
    |> element("#people")
    |> render_hook("masu:query", %{"sorts" => [], "filters" => filters})

    %{proxy: {ref, _topic, _pid}} = view
    assert_receive {^ref, {:reply, reply}}
    reply
  end

  describe "a source that runs some operators" do
    test "its columns offer those of their type, and between, which Masu runs as ≥ and ≤" do
      {:ok, view, _html} = live(build_conn(), "/filter-ops")

      assert column(view, "name")["filters"] ==
               ~w(eq neq contains gt gte lt lte is_nil not_nil between)

      assert column(view, "age")["filters"] == ~w(eq neq gt gte lt lte is_nil not_nil between)
      # No "is one of" for an enum.
      refute "in" in column(view, "city")["filters"]
      # A column it does not filter by.
      assert %{"filters" => [], "filterable" => false} = column(view, "code")
    end

    test "between runs, as the source's own ≥ and ≤" do
      {:ok, view, _html} = live(build_conn(), "/filter-ops")
      filter(view, "people", [{"age", :between, [40, 80]}])
      assert view |> rows("people") |> Enum.map(& &1["age"]) == [41, 72]

      assert [%{"op" => "between"}] =
               view |> view("people") |> Map.fetch!("filter") |> Map.values()
    end

    test "the server refuses an operator it does not run" do
      {:ok, view, _html} = live(build_conn(), "/filter-ops")
      all = total(view, "people")

      assert %{"error" => error} =
               query(view, [%{"key" => "city", "op" => "in", "value" => ["London"]}])

      assert error =~ ~s(The source of the column "city" does not filter by in.)

      assert %{"error" => _not_filtered} =
               query(view, [%{"key" => "code", "op" => "eq", "value" => "P1"}])

      assert total(view, "people") == all
    end

    test "a view's filter it does not run is dropped and reported, as an unknown column's" do
      {:ok, view, _html} = live(build_conn(), "/filter-ops")

      params = %{
        "filter" => %{
          "0" => %{"key" => "city", "op" => "in", "value" => ["London"]},
          "1" => %{"key" => "age", "op" => "gt", "value" => "80"}
        }
      }

      assert apply_view(view, "people", params) == ["city"]
      assert view |> rows("people") |> Enum.map(& &1["age"]) == [85, 86]
    end

    test "an enum's values for its menu are read with the filters the source runs" do
      {:ok, view, _html} = live(build_conn(), "/filter-ops")
      filter(view, "people", [{"age", :between, [30, 80]}])

      assert values(view, "people", "city") |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
               ["London", "Nuenen", "Wilmslow"]
    end
  end

  describe "a column's own operators (filters)" do
    test "are those it offers, of its type, with between; a source's narrow them" do
      column = Column.new(field: :age, type: :integer, filters: [:eq, :gte, :lte, :contains])
      assert column.filter_ops == [:eq, :gte, :lte, :between]

      assert_raise ArgumentError, ~r/operators of Masu.Filter, got: \[:like\]/, fn ->
        Column.new(field: :name, filters: [:like])
      end
    end

    test "a controlled grid's column refuses the others" do
      columns = [Column.new(key: "name", field: 0, filters: [:eq, :contains])]
      assert {:error, error} = Query.new([filters: [{"name", :starts_with, "A"}]], columns)
      assert error =~ "does not filter by starts_with"
    end
  end

  describe "operators" do
    test "of a type" do
      assert :contains in Filter.ops(:text)
      refute :contains in Filter.ops(:integer)

      assert Filter.ops(:integer) ==
               Filter.ops() --
                 [:contains, :not_contains, :starts_with, :ends_with, :all_of, :none_of]
    end

    test "of many values: has any of, all of, none of, none and some" do
      assert Filter.many_ops() == [:in, :all_of, :none_of, :is_nil, :not_nil]
      refute :all_of in Filter.ops(:text)
    end

    test "offered: those of the type the source runs, and between of ≥ and ≤" do
      assert Filter.offered([:eq, :gte, :lte, :contains], :integer) == [:eq, :gte, :lte, :between]
      assert Filter.offered([:eq, :gte], :integer) == [:eq, :gte]
      assert Filter.offered([:between, :gte, :lte], :date) == [:gte, :lte, :between]
    end

    test "expanded into those the source runs" do
      between = Filter.new("age", :between, [1, 2])

      assert Filter.expand(between, [:gte, :lte]) == [
               Filter.new("age", :gte, 1),
               Filter.new("age", :lte, 2)
             ]

      assert Filter.expand(between, [:between]) == [between]
      assert Filter.expand(Filter.new("age", :eq, 1), [:eq]) == [Filter.new("age", :eq, 1)]
    end

    test "a grid's own filters, checked against its source's" do
      columns = [%Column{key: "city", field: :city, type: :enum, filter_ops: [:eq]}]
      assert {:error, error} = Query.new([filters: [{"city", :in, ["London"]}]], columns)
      assert error =~ "does not filter by in"
      assert {:ok, %Query{}} = Query.new([filters: [{"city", :eq, "London"}]], columns)
    end
  end
end

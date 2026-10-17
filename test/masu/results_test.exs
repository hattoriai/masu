defmodule Masu.ResultsTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Masu.Test

  alias Masu.Column

  @endpoint MasuTest.Endpoint

  defp config(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#results")
    |> LazyHTML.attribute("data-masu")
    |> hd()
    |> JSON.decode!()
  end

  defp types(view),
    do: view |> config() |> Map.fetch!("columns") |> Map.new(&{&1["key"], &1["type"]})

  for as <- ["source", "columns"] do
    describe "a query's results, of #{as}" do
      @as as

      test "rows as lists, read by place, with types learned from the values" do
        {:ok, view, _html} = live(build_conn(), "/results?as=#{@as}")

        assert types(view) == %{
                 "name" => "text",
                 "age" => "integer",
                 "born" => "date",
                 "balance" => "decimal",
                 "admin" => "boolean",
                 "note" => "text"
               }

        assert [
                 %{
                   "name" => "Ada",
                   "age" => 36,
                   "born" => "1815-12-10",
                   "balance" => "120.50",
                   "admin" => true
                 }
                 | _
               ] =
                 rows(view, "results")

        aligns = view |> config() |> Map.fetch!("columns") |> Map.new(&{&1["key"], &1["align"]})
        assert aligns["age"] == "end"
        assert aligns["name"] == "start"
      end

      test "sort and filter as their types" do
        {:ok, view, _html} = live(build_conn(), "/results?as=#{@as}")

        view |> sort("results", {"age", :desc}) |> filter("results", [{"age", :gt, "40"}])
        assert view |> rows("results") |> Enum.map(& &1["name"]) == ["Grace", "Edsger", "Alan"]

        filter(view, "results", [{"born", :between, ["1900-01-01", "1999-12-31"]}])
        assert view |> rows("results") |> Enum.map(& &1["name"]) == ["Grace", "Alan"]
      end

      test "another query, of other columns: the view keeps what is of the columns there still" do
        {:ok, view, _html} = live(build_conn(), "/results?as=#{@as}")
        view |> sort("results", {"age", :desc}) |> filter("results", [{"name", :contains, "a"}])

        view |> element("#cities") |> render_click()

        assert types(view) == %{"city" => "text", "people" => "integer", "age" => "number"}
        assert columns(view, "results") == ["City", "People", "Age"]
        # The sort by age stays; the filter of name, a column that is gone, goes, and is named.
        assert view |> rows("results") |> Enum.map(& &1["city"]) == ["Lisbon", "London", "Tokyo"]
        assert [_id, "name"] = config(view)["notice"]
      end
    end
  end

  describe "a column's type, of its values" do
    test "the type every value has, else text" do
      assert Column.infer([1, nil, 3]) == :integer
      assert Column.infer([1, 2.5]) == :number
      assert Column.infer([Decimal.new("1.5")]) == :decimal
      assert Column.infer([~D[2026-01-01]]) == :date
      assert Column.infer([~U[2026-01-01 00:00:00Z], ~N[2026-01-01 00:00:00]]) == :datetime
      assert Column.infer([~T[10:00:00]]) == :time
      assert Column.infer([true, false]) == :boolean
      assert Column.infer(["a", 1]) == :text
      assert Column.infer([nil]) == :text
      assert Column.infer([]) == :text
    end

    test "a column of :auto is made again of its type, with that type's defaults" do
      column = Column.new(field: 1, key: "age", type: :auto)
      assert %Column{type: :auto, key: "age"} = column

      assert %Column{type: :integer, align: :end, searchable: false, width: 120} =
               Column.typed(column, :integer)

      assert Column.get(column, ["Ada", 36]) == 36
      assert Column.new(field: 2).key == "2"
    end
  end
end

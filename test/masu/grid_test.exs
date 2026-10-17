defmodule Masu.GridTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Masu.Test

  @endpoint MasuTest.Endpoint

  setup do
    {:ok, conn: build_conn()}
  end

  describe "a grid of a list" do
    test "renders its first rows on the server, in the order of its sort", %{conn: conn} do
      {:ok, view, html} = live(conn, "/people")

      assert html =~ ~s(role="grid")
      assert html =~ ~s(aria-rowcount="6")
      assert html =~ "<strong>Barbara Liskov</strong>"
      assert columns(view, "people") == ~w(Name City Age Born Admin Balance Initials)
      assert total(view, "people") == 5

      assert [
               %{
                 "name" => "Barbara Liskov",
                 "age" => 86,
                 "balance" => "99.99",
                 "born" => "1939-11-07",
                 "initials" => "BL"
               }
               | _
             ] =
               rows(view, "people")

      assert ids(view, "people") == [5, 3, 4, 2, 1]
    end

    test "sorts, filters and searches as the browser asks", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/people")

      view |> sort("people", "name")

      assert Enum.map(rows(view, "people"), & &1["name"]) ==
               [
                 "Ada Lovelace",
                 "alan Turing",
                 "Barbara Liskov",
                 "Edsger Dijkstra",
                 "Grace Hopper"
               ]

      view |> sort("people", [{"admin", :desc}, {"balance", :asc}])
      assert ids(view, "people") == [1, 3, 2, 4, 5]

      view |> filter("people", [{"born", :lt, "1920-01-01"}])
      assert total(view, "people") == 3

      view |> search("people", "lon")
      assert ids(view, "people") == [1]

      view |> filter("people", []) |> search("people", "")
      assert total(view, "people") == 5
    end

    test "a filter that does not check is answered with an error, and changes nothing", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/people")

      render_hook(element(view, "#people"), "masu:query", %{
        "filters" => [%{"key" => "age", "op" => "contains", "value" => "1"}]
      })

      assert_reply(view, %{"error" => "contains is for text, not integer", "revision" => 0})
      assert total(view, "people") == 5
    end

    test "new rows from the LiveView keep the person's query and change the revision", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/people")

      view |> sort("people", {"age", :asc})
      render_click(element(view, "#add"))

      assert total(view, "people") == 6
      assert List.last(ids(view, "people")) == 6
      assert render(view) =~ ~s(&quot;revision&quot;:2)
    end

    test "answers a block of at most 500 rows", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/people")

      render_hook(element(view, "#people"), "masu:rows", %{"from" => 3, "count" => 10_000})
      assert_reply(view, %{"from" => 3, "rows" => [[2 | _], [1 | _]], "total" => 5})
    end
  end

  describe "a grid of an Ecto query" do
    test "sorts, filters and counts in the database", %{conn: conn} do
      {:ok, view, html} = live(conn, "/orders")

      assert html =~ ~s(aria-rowcount="6")
      assert total(view, "orders") == 5

      view |> sort("orders", {"total", :desc})
      assert [%{"number" => "A-5", "total" => total} | _] = rows(view, "orders")
      assert Decimal.equal?(Decimal.new(total), Decimal.new("999"))

      view |> filter("orders", [{"status", :eq, "paid"}])
      assert ids(view, "orders") == [4, 1, 3]
    end

    test "a column of a value function is shown but does not sort", %{conn: conn} do
      {:ok, view, html} = live(conn, "/orders")

      assert [%{"code" => "a-1"} | _] = rows(view, "orders")
      refute html =~ ~s(data-key="code" aria-sort)

      view |> sort("orders", "code")
      assert ids(view, "orders") == [1, 2, 3, 4, 5]
    end
  end

  describe "the values of a column, for its filter menu" do
    test "a list counts them among the rows of the other filters, the most frequent first", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/people")

      assert values(view, "people", "admin") == [{false, 3}, {true, 2}]

      view |> filter("people", [{"admin", :eq, true}, {"age", :gt, 50}])
      assert values(view, "people", "admin") == [{false, 2}, {true, 1}]
      assert values(view, "people", "city", search: "ARL") == [{"Arlington", 1}]
    end

    test "an Ecto source counts them with one GROUP BY", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/orders")

      assert values(view, "orders", "status") == [{"paid", 3}, {"draft", 1}, {"late", 1}]
      assert values(view, "orders", "customer", search: "acme") == [{"Acme", 1}, {"acme corp", 1}]

      view |> search("orders", "acme")
      assert values(view, "orders", "status") == [{"paid", 2}]
      assert values(view, "orders", "code") == []
    end
  end

  describe "the place of a row in the grid's order" do
    test "a list finds it in its order, and not when its filters leave it out", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/people")

      # By age, descending: Barbara 86, Grace 85, Edsger 72, Alan 41, Ada 36.
      assert place(view, "people", 5) == 0
      assert place(view, "people", 1) == 4

      view |> sort("people", "name")
      assert place(view, "people", 1) == 0

      view |> filter("people", [{"age", :gt, 80}])
      assert place(view, "people", 1) == nil
      assert place(view, "people", 3) == 1
    end

    test "an Ecto source counts with row_number() in a window of its order", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/orders")

      assert place(view, "orders", 1) == 0
      view |> sort("orders", {"total", :desc})
      assert place(view, "orders", 5) == 0
      assert place(view, "orders", 3) == 4

      view |> filter("orders", [{"status", :eq, "paid"}])
      assert place(view, "orders", 4) == 0
      assert place(view, "orders", 2) == nil
      assert place(view, "orders", 6) == nil
    end
  end
end

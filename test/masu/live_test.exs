defmodule Masu.LiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Masu.Test

  alias MasuTest.{Order, Repo}

  @endpoint MasuTest.Endpoint

  setup do
    {:ok, conn: build_conn()}
  end

  describe "a grid of a list" do
    test "takes a changed row, a new row and a deleted row into its query", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/live/people")
      assert total(view, "people") == 5

      Masu.Live.broadcast_upsert(MasuTest.PubSub, "people", %{id: 2, name: "Alan Turing", age: 42})

      Masu.Live.broadcast_upsert(MasuTest.PubSub, "people", %{
        id: 9,
        name: "Aaron Swartz",
        age: 26
      })

      Masu.Live.broadcast_delete(MasuTest.PubSub, "people", 4)

      assert total(view, "people") == 5

      assert Enum.map(rows(view, "people"), &{&1["name"], &1["age"]}) == [
               {"Aaron Swartz", 26},
               {"Ada Lovelace", 36},
               {"Alan Turing", 42},
               {"Barbara Liskov", 86},
               {"Grace Hopper", 85}
             ]
    end

    test "keeps the person's query, and tells the browser which rows changed", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/live/people")
      view |> filter("people", [{"age", :gt, 80}])

      Masu.Live.broadcast_upsert(MasuTest.PubSub, "people", %{
        id: 1,
        name: "Ada Lovelace",
        age: 90
      })

      Masu.Live.broadcast_upsert(MasuTest.PubSub, "people", %{id: 7, name: "Young", age: 20})

      assert ids(view, "people") == [1, 5, 3]
      html = render(view)
      assert html =~ "&quot;changed&quot;:[1,7]"
      assert html =~ "&quot;revision&quot;:2"
    end

    test "a delete may give the row instead of its id", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/live/people")
      Masu.Live.broadcast_delete(MasuTest.PubSub, "people", %{id: 1, name: "Ada Lovelace"})
      refute 1 in ids(view, "people")
    end
  end

  describe "a grid of an Ecto source" do
    test "asks its query again", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/live/orders")
      assert total(view, "orders") == 6

      order =
        Repo.insert!(%Order{
          number: "A-7",
          customer: "New",
          status: "paid",
          total: Decimal.new(1),
          placed_on: ~D[2026-01-07]
        })

      Masu.Live.broadcast_upsert(MasuTest.PubSub, "orders", order)

      assert total(view, "orders") == 7

      assert List.last(rows(view, "orders", count: 10)) == %{
               "number" => "A-7",
               "status" => "paid"
             }

      Repo.delete!(order)
      Masu.Live.broadcast_delete(MasuTest.PubSub, "orders", order)
      assert total(view, "orders") == 6
    end
  end

  @tag :capture_log
  test "a grid with live in a LiveView without the hook says what to add", %{conn: conn} do
    assert {{%ArgumentError{message: message}, _stack}, _} =
             catch_exit(live(conn, "/live/no-hook"))

    assert message =~ "Add `on_mount Masu.Live`"
  end

  test "other messages go to the LiveView's own handle_info", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/live/people")
    Masu.Live.broadcast_upsert(MasuTest.PubSub, "other topic", %{id: 1})
    assert total(view, "people") == 5
  end
end

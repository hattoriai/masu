defmodule Masu.EditTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Masu.Test

  alias MasuTest.{Order, Repo}

  @endpoint MasuTest.Endpoint

  setup do
    {:ok, conn: build_conn()}
  end

  describe "a grid of a list with a changeset" do
    test "saves the edits of a row together, and shows them in its query", %{conn: conn} do
      {:ok, view, html} = live(conn, "/edit/people")
      assert html =~ "&quot;editable&quot;:true"

      assert :ok = edit(view, "people", [{2, "name", "Alan Turing"}, {2, "age", "42"}])
      assert %{"name" => "Alan Turing", "age" => 42} = Enum.at(rows(view, "people"), 1)

      view |> sort("people", "name")
      assert hd(ids(view, "people")) == 1
    end

    test "puts the changeset's errors on their cells, and saves nothing of the row", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/edit/people")

      assert {:error, errors} =
               edit(view, "people", [{1, "name", ""}, {1, "age", "200"}, {3, "age", "90"}])

      assert {1, "name", "can't be blank"} in errors
      assert {1, "age", "must be less than 150"} in errors
      assert length(errors) == 2

      assert [%{"name" => "Ada Lovelace", "age" => 36}, _, %{"age" => 90} | _] =
               rows(view, "people")
    end

    test "refuses a column that does not edit, and a row the grid does not have", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/edit/people")

      assert {:error, [{1, "city", "This cell cannot be edited."}]} =
               edit(view, "people", [{1, "city", "Paris"}])

      assert {:error, [{1, "initials", _}]} = edit(view, "people", [{1, "initials", "X"}])

      assert {:error, [{99, "name", "This row is not in the grid."}]} =
               edit(view, "people", [{99, "name", "X"}])
    end

    test "a column of a value function, or with editable={false}, says it does not edit", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, "/edit/people")

      config =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#people")
        |> LazyHTML.attribute("data-masu")
        |> hd()
        |> JSON.decode!()

      assert Enum.map(config["columns"], &{&1["key"], &1["editable"]}) == [
               {"name", true},
               {"age", true},
               {"city", false},
               {"initials", false}
             ]
    end

    test "the other edited cells of a refused row say why they were not saved", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/edit/people")

      assert {:error,
              [
                {2, "age", "must be greater than 0"},
                {2, "name", "Not saved: the row has an error."}
              ]} =
               edit(view, "people", [{2, "name", "Alan"}, {2, "age", "-1"}])

      assert %{"name" => "alan Turing"} = Enum.at(rows(view, "people"), 1)
    end
  end

  describe "a grid of an Ecto source with a changeset" do
    test "updates the row in the database, and refuses a row outside its query", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/edit/orders")

      assert :ok = edit(view, "orders", [{1, "total", "11.50"}, {1, "status", "late"}])
      order = Repo.get!(Order, 1)
      assert Decimal.equal?(order.total, Decimal.new("11.50"))
      assert order.status == "late"

      assert {:error, [{1, "status", "is invalid"}]} =
               edit(view, "orders", [{1, "status", "lost"}])

      assert {:error, [{6, "customer", "This row is not in the grid."}]} =
               edit(view, "orders", [{6, "customer", "Me"}])

      assert Repo.get!(Order, 6).customer == "Void Inc"
    after
      Repo.update!(
        Order.changeset(Repo.get!(Order, 1), %{"total" => "10.00", "status" => "paid"})
      )
    end

    test "other LiveViews that follow the topic get the saved row", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/edit/orders")
      {:ok, other, _html} = live(build_conn(), "/edit/orders")

      assert :ok = edit(view, "orders", [{3, "customer", "Cyd & Co"}])
      assert %{"customer" => "Cyd & Co"} = Enum.at(rows(other, "orders"), 2)
      assert render(other) =~ "&quot;changed&quot;:[3]"
      refute render(view) =~ "&quot;changed&quot;:[3]"
    after
      Repo.update!(Order.changeset(Repo.get!(Order, 3), %{"customer" => "Cyd"}))
    end
  end

  test "a grid with an update function saves with it, and shows its errors", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/edit/update")

    assert :ok = edit(view, "things", [{1, "name", "two"}])
    assert [%{"name" => "TWO"}] = rows(view, "things")
    assert {:error, [{1, "name", "Not that name."}]} = edit(view, "things", [{1, "name", "nope"}])
  end

  describe "cells and rows that the row's state makes read-only" do
    test "a locked row refuses every cell, a column's function refuses its cell", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/edit/locked")

      assert {:error, [{1, "name", "This cell cannot be edited."}]} =
               edit(view, "people", [{1, "name", "X"}])

      # Grace is 85: her age does not edit, her name does, in the same batch.
      assert {:error, [{3, "age", "This cell cannot be edited."}]} =
               edit(view, "people", [{3, "name", "Grace B. Hopper"}, {3, "age", "86"}])

      assert %{"name" => "Grace B. Hopper", "age" => 85} = Enum.at(rows(view, "people"), 2)
      assert :ok = edit(view, "people", [{2, "age", "42"}])
    end

    test "each row tells the browser which of its cells are read-only", %{conn: conn} do
      {:ok, view, html} = live(conn, "/edit/locked")
      assert html =~ "&quot;locks&quot;:true"

      render_hook(element(view, "#people"), "masu:rows", %{"from" => 0, "count" => 3})
      assert_reply(view, %{"rows" => [[1, _, _, true], [2, _, _, []], [3, _, _, [1]]]})
    end
  end

  test "on_save gets the saved rows, in the LiveView's process", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/edit/locked")

    assert :ok = edit(view, "people", [{2, "name", "Alan"}, {4, "name", "Edsger"}])
    assert render(view) =~ ~s(<p id="saved">Alan, Edsger</p>)

    assert {:error, _} = edit(view, "people", [{2, "name", ""}])
    assert render(view) =~ ~s(<p id="saved">Alan, Edsger</p>)
  end
end

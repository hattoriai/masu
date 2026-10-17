defmodule Masu.ActionsTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Masu.Test

  @endpoint MasuTest.Endpoint

  defp heard(view) do
    view |> element("#heard") |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()
  end

  defp config(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#orders")
    |> LazyHTML.attribute("data-masu")
    |> hd()
    |> JSON.decode!()
  end

  # The event the browser sends, without Masu.Test's checks.
  defp push(view, payload) do
    view |> element("#orders") |> render_hook("masu:action", payload)
    %{proxy: {ref, _topic, _pid}} = view
    assert_receive {^ref, {:reply, reply}}
    reply
  end

  describe "the items a grid offers" do
    test "for each column, by its key, its type, a function of it, and :if" do
      {:ok, view, _html} = live(build_conn(), "/actions")

      assert actions(view, "orders", :header, :number) == ["Explain"]
      assert actions(view, "orders", :header, :total) == ["Explain", "Stats"]

      assert actions(view, "orders", :cell, :number) == ["Open", "Copy a link"]

      assert actions(view, "orders", :cell, :customer) == [
               "Open",
               "Only customers",
               "Copy a link"
             ]

      assert actions(view, "orders", :cell, :status) == ["Open", "Copy a link", "Peek"]

      {:ok, admin, _html} = live(build_conn(), "/actions?admin=true")
      assert actions(admin, "orders", :cell, :number) == ["Open", "Void", "Copy a link"]
    end

    test "the built-in items of the cells' menu, and a JS command as the browser runs it" do
      {:ok, view, _html} = live(build_conn(), "/actions")
      config = config(view)
      assert config["cellMenu"] == ["copy", "filter", "sort"]

      link =
        config["columns"]
        |> hd()
        |> Map.fetch!("cellActions")
        |> Enum.find(&(&1["label"] == "Copy a link"))

      assert %{"server" => false, "panel" => false} = link
      assert JSON.decode!(link["js"]) == [["dispatch", %{"event" => "app:link"}]]
    end

    test "a grid without them has none, and no menu on its cells" do
      {:ok, view, _html} = live(build_conn(), "/select?source=list")
      config = config(view)
      assert config["cellMenu"] == []

      assert Enum.all?(
               config["columns"],
               &(&1["headerActions"] == [] and &1["cellActions"] == [])
             )
    end
  end

  describe "running an item" do
    test "of a header: its function gets the column" do
      {:ok, view, _html} = live(build_conn(), "/actions")
      header_action(view, "orders", "Explain", :customer)
      assert heard(view) == "explain orders customer"
    end

    test "of a cell: its event goes to the LiveView, with the row read from the source" do
      {:ok, view, _html} = live(build_conn(), "/actions")
      cell_action(view, "orders", "Open", :number, 2)
      assert heard(view) == "open orders 2 A-2"
    end

    test "of a cell: the value is the source's, whatever the browser sends" do
      {:ok, view, _html} = live(build_conn(), "/actions")

      payload = %{
        "kind" => "cell",
        "action" => 1,
        "key" => "customer",
        "id" => 2,
        "value" => "forged"
      }

      assert push(view, payload) == %{"ok" => true}
      assert heard(view) == "customer Bob's"
    end

    test "on a range: its rows' ids and the columns of the grid" do
      {:ok, view, _html} = live(build_conn(), "/actions?admin=true")

      cell_action(view, "orders", "Void", :number, 1,
        range: {[1, 2, 3], [:number, :nope, :status]}
      )

      assert heard(view) == ~s(void 1 %{columns: ["number", "status"], ids: [1, 2, 3]})
    end

    test "with content: its panel, rendered with the context, until it closes" do
      {:ok, view, _html} = live(build_conn(), "/actions")
      header_action(view, "orders", "Stats", :total)
      assert view |> element("#orders-action-panel #stats") |> render() =~ "Stats of total"
      assert has_element?(view, ~s(#orders-action-panel[role="dialog"][aria-label="Stats"]))

      cell_action(view, "orders", "Peek", :status, 3)
      assert view |> element("#peek") |> render() =~ "A-3 is paid"
      refute has_element?(view, "#stats")

      close_panel(view, "orders")
      refute has_element?(view, "#orders-action-panel")
    end
  end

  describe "the server refuses" do
    test "an item the grid does not offer for the column, or at all" do
      {:ok, view, _html} = live(build_conn(), "/actions")
      # "Stats" (1) is for decimals only.
      assert push(view, %{"kind" => "header", "action" => 1, "key" => "number"}) == %{
               "error" => "action"
             }

      # "Void" is for admins only: its place is "Copy a link"'s, a JS command.
      assert push(view, %{"kind" => "cell", "action" => 2, "key" => "number", "id" => 1}) ==
               %{"error" => "action"}

      # A label that is not the item's: the LiveView changed its items.
      assert push(view, %{
               "kind" => "cell",
               "action" => 0,
               "label" => "Void",
               "key" => "number",
               "id" => 1
             }) ==
               %{"error" => "action"}

      assert push(view, %{"kind" => "cell", "action" => 9, "key" => "number", "id" => 1}) ==
               %{"error" => "action"}

      assert push(view, %{"kind" => "header", "action" => 0, "key" => "nope"}) == %{
               "error" => "action"
             }

      refute has_element?(view, "#heard")
    end

    test "a cell of a row that is not there" do
      {:ok, view, _html} = live(build_conn(), "/actions")

      assert push(view, %{"kind" => "cell", "action" => 0, "key" => "number", "id" => 999}) == %{
               "error" => "row"
             }

      assert push(view, %{"kind" => "cell", "action" => 0, "key" => "number"}) == %{
               "error" => "row"
             }
    end
  end

  describe "declaring" do
    import Phoenix.Component, only: [sigil_H: 2]
    import Masu.Components

    test "an item that does nothing, or a cell_menu of unknown items" do
      assigns = %{rows: [%{id: 1, name: "a"}]}

      assert_raise ArgumentError, ~r/does nothing/, fn ->
        Masu.Action.all([%{label: "Nothing", inner_block: nil}], :cell)
      end

      assert_raise ArgumentError, ~r/cell_menu has \[:paste\]/, fn ->
        rendered_to_string(~H"""
        <.data_grid id="g" rows={@rows} cell_menu={[:copy, :paste]}>
          <:col field={:name} />
        </.data_grid>
        """)
      end
    end
  end
end

defmodule Masu.TreeTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Masu.Test

  alias Masu.Tree

  @endpoint MasuTest.Endpoint

  defp shown(view), do: view |> nodes("accounts") |> Enum.map(&{&1.id, &1.level})

  describe "Masu.Tree.flatten/3" do
    test "shows the roots, and the children of the open rows, depth first" do
      entries = [{1, nil}, {2, 1}, {3, 1}, {4, 3}, {5, nil}]
      flat = Tree.flatten(entries, &(&1 in [1, 3]))

      assert Enum.map(flat, fn {id, _parent, info} ->
               {id, info.level, info.position, info.size}
             end) ==
               [{1, 0, 1, 2}, {2, 1, 1, 2}, {3, 1, 2, 2}, {4, 2, 1, 1}, {5, 0, 2, 2}]

      assert [%{children: true, expanded: true} | _] = Enum.map(flat, &elem(&1, 2))
    end

    test "a row whose parent is not among the rows is a root; a cycle shows each row once" do
      flat = Tree.flatten([{1, 9}, {2, 3}, {3, 2}, {4, 4}], fn _id -> true end)
      assert Enum.map(flat, &elem(&1, 0)) == [1, 4]

      assert Tree.flatten([{1, nil}, {2, 1}, {1, 2}], fn _id -> true end)
             |> Enum.map(&elem(&1, 0)) ==
               [1, 2]
    end

    test "a closed row that a database did not read the children of has children" do
      [{1, nil, info}] = Tree.flatten([{1, nil}], fn _id -> false end, MapSet.new([1]))
      assert %{children: true, expanded: false} = info
    end

    test "with_ancestors climbs to the roots" do
      parents = %{1 => nil, 2 => 1, 3 => 2, 4 => nil}
      assert Tree.with_ancestors([3], &parents[&1]) == MapSet.new([1, 2, 3])
    end
  end

  for source <- ["list", "ecto"] do
    describe "a tree of #{source} rows" do
      @path if(source == "ecto", do: "/tree?source=ecto", else: "/tree")

      setup do
        {:ok, view, _html} = live(build_conn(), @path)
        %{view: view}
      end

      test "shows the roots; a row opens and closes, and remembers its open children", %{
        view: view
      } do
        assert shown(view) == [{1, 0}, {6, 0}, {8, 0}]

        assert [%{children: true, expanded: false}, %{children: true}, %{children: false}] =
                 nodes(view, "accounts")

        expand(view, "accounts", 1)
        assert shown(view) == [{1, 0}, {2, 1}, {3, 1}, {6, 0}, {8, 0}]
        assert total(view, "accounts") == 5

        expand(view, "accounts", 3)
        assert shown(view) == [{1, 0}, {2, 1}, {3, 1}, {4, 2}, {5, 2}, {6, 0}, {8, 0}]
        assert rows(view, "accounts") |> Enum.at(3) == %{"name" => "Checking", "balance" => "500"}

        collapse(view, "accounts", 1)
        assert shown(view) == [{1, 0}, {6, 0}, {8, 0}]

        expand(view, "accounts", 1)
        assert length(shown(view)) == 7
        assert place(view, "accounts", 5) == 4
      end

      test "sorting sorts each row's children among themselves", %{view: view} do
        view |> expand("accounts", 1) |> sort("accounts", {"name", :desc})

        assert Enum.map(rows(view, "accounts"), & &1["name"]) ==
                 ["Liabilities", "Equity", "Assets", "Cash", "Bank"]
      end

      test "a filter keeps the rows that match and their ancestors, open", %{view: view} do
        filter(view, "accounts", [{"name", :contains, "sav"}])
        assert shown(view) == [{1, 0}, {3, 1}, {5, 2}]

        collapse(view, "accounts", 3)
        assert shown(view) == [{1, 0}, {3, 1}]

        # A new filter opens what it keeps again.
        filter(view, "accounts", [{"name", :contains, "loan"}])
        assert shown(view) == [{6, 0}, {7, 1}]

        filter(view, "accounts", [])
        assert shown(view) == [{1, 0}, {6, 0}, {8, 0}]
      end

      test "* opens every row beside a row that has children", %{view: view} do
        expand_siblings(view, "accounts", 8)
        assert shown(view) == [{1, 0}, {2, 1}, {3, 1}, {6, 0}, {7, 1}, {8, 0}]
      end

      test "a tree row edits", %{view: view} do
        expand(view, "accounts", 1)
        assert :ok = edit(view, "accounts", [{2, "name", "Petty cash"}])
        assert Enum.at(rows(view, "accounts"), 1)["name"] == "Petty cash"
        assert :ok = edit(view, "accounts", [{2, "name", "Cash"}])
      end
    end
  end

  test "rows start open with `expanded`" do
    {:ok, view, _html} = live(build_conn(), "/tree?open=6")
    assert shown(view) == [{1, 0}, {6, 0}, {7, 1}, {8, 0}]
  end

  test "expanded={:all} is for groups" do
    import Phoenix.Component, only: [sigil_H: 2]
    import Masu.Components

    assigns = %{rows: [%{id: 1, parent_id: nil, name: "a"}]}

    assert_raise ArgumentError, ~r/expanded=\{:all\} is for groups/, fn ->
      rendered_to_string(~H"""
      <.data_grid id="g" rows={@rows} tree={:parent_id} expanded={:all}>
        <:col field={:name} />
      </.data_grid>
      """)
    end
  end

  test "a live row takes its place in the tree" do
    {:ok, view, _html} = live(build_conn(), "/tree?open=6")

    Masu.Live.broadcast_upsert(MasuTest.PubSub, "tree-accounts", %MasuTest.Account{
      id: 9,
      parent_id: 6,
      name: "Credit card",
      balance: Decimal.new("20")
    })

    assert shown(view) == [{1, 0}, {6, 0}, {7, 1}, {9, 1}, {8, 0}]
  end

  test "the grid is a treegrid" do
    {:ok, _view, html} = live(build_conn(), "/tree")
    assert html =~ ~s(role="treegrid")
  end
end

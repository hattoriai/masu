defmodule Masu.IdsTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Masu.Test

  @endpoint MasuTest.Endpoint

  defp open(kase) do
    {:ok, view, _html} = live(build_conn(), "/ids?case=#{kase}")
    view
  end

  test "rows without an id, in a grid that needs none, are known by their place" do
    view = open("plain")
    assert ids(view, "g", count: 3) == [0, 1, 2]
    assert ids(view, "g", from: 10, count: 2) == [10, 11]
    assert hd(rows(view, "g", from: 10, count: 1))["code"] == "R11"
  end

  test "row_id={:position}: the place in the query, whatever the rows' ids" do
    view = open("position")
    assert ids(view, "g", count: 3) == [0, 1, 2]
    # Their place in this order: the last person first.
    assert hd(rows(view, "g", count: 1))["id"] == 5
  end

  test "row_id as a function: the rows' own ids, which selection takes" do
    view = open("function")
    assert ids(view, "g", count: 2) == ["R1", "R2"]
    select(view, "g", ["R2"])
    assert selection(view, "g").ids == ["R2"]
  end

  test "a grid that needs ids, and a row without one, says what to give it" do
    assert_raise ArgumentError,
                 ~r/a row of the grid g has no id, and its selectable needs one/,
                 fn ->
                   live(build_conn(), "/ids?case=missing")
                 end
  end

  test "row_id={:position} with what needs an id that stays is refused" do
    assert_raise ArgumentError, ~r/has row_id=\{:position\}, and selectable/, fn ->
      live(build_conn(), "/ids?case=position_selectable")
    end
  end

  test "the features that need ids that stay" do
    assert Masu.Grid.stable_id_features(%{}) == []

    assert Masu.Grid.stable_id_features(%{
             changeset: & &1,
             deletable: true,
             selectable: true,
             live: {:pubsub, "t"},
             detail: [%{}],
             tree: :parent_id
           }) == [
             "changeset or on_update",
             "on_delete or deletable",
             "selectable",
             "live",
             ":detail",
             "tree"
           ]
  end
end

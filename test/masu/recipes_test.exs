defmodule Masu.RecipesTest do
  # The recipes of the guides that plug other libraries into a grid, as
  # far as Masu's side of them goes.
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Masu.Test

  @endpoint MasuTest.Endpoint

  test "a range of days from a picker above the grid filters it: the params of the Koyomi guide" do
    {:ok, view, _html} = live(build_conn(), "/orders")

    # What a date range picker posts, as the guide puts it in the grid's view.
    stay = %{"from" => "2026-01-02", "to" => "2026-01-04"}

    filter = %{
      "0" => %{"key" => "placed_on", "op" => "between", "value" => [stay["from"], stay["to"]]}
    }

    assert apply_view(view, "orders", %{"filter" => filter}) == []
    assert view |> rows("orders") |> Enum.map(& &1["number"]) == ["A-2", "A-3", "A-4"]
  end

  test "the picker's form patches the URL, and the grid takes the filter from it" do
    {:ok, view, _html} = live(build_conn(), "/placed")

    view
    |> element("#placed")
    |> render_change(%{"placed" => %{"from" => "2026-01-03", "to" => "2026-01-05"}})

    assert_patch(view)
    assert view |> rows("orders") |> Enum.map(& &1["number"]) == ["A-3", "A-4", "A-5"]

    assert [%{"key" => "placed_on", "op" => "between"}] =
             view |> view("orders") |> Map.fetch!("filter") |> Map.values()
  end
end

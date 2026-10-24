defmodule Masu.GrowTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Masu.Test

  @endpoint MasuTest.Endpoint

  defp grid(view) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("#items")
  end

  defp columns(view) do
    view
    |> grid()
    |> LazyHTML.attribute("data-masu")
    |> hd()
    |> JSON.decode!()
    |> Map.fetch!("columns")
  end

  defp tracks(view) do
    view |> grid() |> LazyHTML.query("#items-content") |> LazyHTML.attribute("style") |> hd()
  end

  test "a column that grows takes its share of the room, from its width up" do
    {:ok, view, _html} = live(build_conn(), "/grow")

    assert [
             %{"key" => "title", "width" => 280, "minWidth" => 280, "grow" => 1},
             %{"key" => "author", "width" => 120, "grow" => 0},
             %{"key" => "comments", "width" => 100, "grow" => 2}
           ] = columns(view)

    # Before the browser takes over, the tracks of the grid share the room.
    assert tracks(view) == "--masu-cols: minmax(280px, 1fr) 120px minmax(100px, 2fr)"
  end

  test "a column the person resizes is their width, and grows no more" do
    {:ok, view, _html} = live(build_conn(), "/grow")

    layout(view, "items", widths: %{title: 320})

    assert [%{"width" => 320, "grow" => 0}, %{"grow" => 0}, %{"grow" => 2}] = columns(view)
  end
end

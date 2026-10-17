defmodule Masu.ThemeTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint MasuTest.Endpoint

  defp grid(html, id) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query("##{id}")
  end

  # A class attribute's classes, as the browser reads them.
  defp classes([class]), do: class |> String.split() |> Enum.join(" ")

  defp row_height(html, id) do
    [json] = html |> grid(id) |> LazyHTML.attribute("data-masu")
    JSON.decode!(json)["rowHeight"]
  end

  test "density sets the rows' height and a class, unless row_height is given" do
    {:ok, _view, html} = live(build_conn(), "/theme")

    assert row_height(html, "compact") == 28
    assert row_height(html, "normal") == 36
    assert row_height(html, "tall") == 60

    assert html |> grid("compact") |> LazyHTML.attribute("class") |> classes() ==
             "masu masu-density-compact"

    assert html |> grid("normal") |> LazyHTML.attribute("class") |> classes() == "masu"
  end

  test "every second row, as :nth-child(even) counts, is marked, from the first render" do
    {:ok, _view, html} = live(build_conn(), "/theme")

    classes =
      html
      |> grid("normal")
      |> LazyHTML.query(".masu-body .masu-row")
      |> Enum.map(&(&1 |> LazyHTML.attribute("class") |> classes()))

    assert Enum.take(classes, 4) == [
             "masu-row",
             "masu-row masu-row-even",
             "masu-row",
             "masu-row masu-row-even"
           ]
  end
end

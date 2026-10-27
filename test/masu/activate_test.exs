defmodule Masu.ActivateTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Masu.Test

  @endpoint MasuTest.Endpoint

  defp text(view, selector) do
    view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()
  end

  defp grid(view, id) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("##{id}")
  end

  describe "opening a row" do
    test "calls the function with the row read from the source" do
      {:ok, view, _html} = live(build_conn(), "/activate")

      assert activate_row(view, "people", 2) == :ok
      assert text(view, "#heard") == "people 2 Grace"
    end

    test "follows the patch the function gives" do
      {:ok, view, _html} = live(build_conn(), "/activate?to=patch")

      assert activate_row(view, "people", 1) == {:patch, "/activate?to=patch&open=1"}
      assert_patch(view, "/activate?to=patch&open=1")
      assert text(view, "#open") == "1"
    end

    test "follows the navigation the function gives" do
      {:ok, view, _html} = live(build_conn(), "/activate?to=navigate")

      assert activate_row(view, "people", 1) == {:navigate, "/people?from=1"}
      assert_redirect(view, "/people?from=1")
    end

    test "tells the browser that a click or Enter opens a row" do
      {:ok, view, _html} = live(build_conn(), "/activate")
      el = grid(view, "people")

      assert el |> LazyHTML.attribute("class") |> hd() =~ "masu-activates"
      assert (el |> LazyHTML.attribute("data-masu") |> hd() |> JSON.decode!())["activates"]

      {:ok, view, _html} = live(build_conn(), "/people")
      el = grid(view, "people")

      refute el |> LazyHTML.attribute("class") |> hd() =~ "masu-activates"
      refute (el |> LazyHTML.attribute("data-masu") |> hd() |> JSON.decode!())["activates"]
    end
  end

  describe "the server refuses" do
    test "a row that is not the grid's" do
      {:ok, view, _html} = live(build_conn(), "/activate")

      assert activate_row(view, "people", 99) == {:error, :refused}
      assert activate_row(view, "people", nil) == {:error, :refused}
      refute has_element?(view, "#heard")
    end

    test "a grid without on_row_activate" do
      {:ok, view, _html} = live(build_conn(), "/people")
      [id | _] = ids(view, "people")

      assert activate_row(view, "people", id) == {:error, :refused}
    end
  end

  describe "declaring" do
    test "on_row_activate is a function of one argument" do
      assert_raise ArgumentError, ~r/on_row_activate is a function of one argument/, fn ->
        render_component(&Masu.Components.data_grid/1,
          id: "g",
          rows: [],
          col: [],
          on_row_activate: "open"
        )
      end
    end

    test "it needs ids that stay" do
      assert_raise ArgumentError, ~r/row_id=\{:position\}, and on_row_activate/, fn ->
        render_component(&Masu.Components.data_grid/1,
          id: "g",
          rows: [],
          col: [],
          row_id: :position,
          on_row_activate: fn _context -> :ok end
        )
      end
    end
  end

  describe "ranges of cells" do
    test "a grid selects them, unless range_select={false}" do
      {:ok, view, _html} = live(build_conn(), "/activate")
      assert config(grid(view, "people"))["rangeSelect"] == true

      {:ok, view, _html} = live(build_conn(), "/activate?range=off")
      assert config(grid(view, "people"))["rangeSelect"] == false
    end
  end

  defp config(el), do: el |> LazyHTML.attribute("data-masu") |> hd() |> JSON.decode!()
end

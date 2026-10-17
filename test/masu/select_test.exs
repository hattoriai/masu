defmodule Masu.SelectTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Masu.Test

  @endpoint MasuTest.Endpoint

  defp read(view) do
    view |> element("#read") |> render_click()
    view |> element("#selected") |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()
  end

  for source <- ["list", "ecto"] do
    describe "selecting #{source} rows" do
      @source source

      test "rows by their ids, and the LiveView hears of it" do
        {:ok, view, _html} = live(build_conn(), "/select?source=#{@source}")
        assert selection(view, "orders") == %{all: false, ids: [], except: [], count: 0}

        select(view, "orders", [1, 3, 4])
        select(view, "orders", [3], false)
        assert %{all: false, count: 2} = selection(view, "orders")
        assert read(view) == "ids 1,4"
        assert render(view) =~ ~s(<p id="summary">2 false</p>)
      end

      test "every row of the query, less some, as the query is when it is read" do
        {:ok, view, _html} = live(build_conn(), "/select?source=#{@source}")
        filter(view, "orders", [{"status", :eq, "paid"}])
        select_all(view, "orders")
        assert %{all: true, count: 3} = selection(view, "orders")

        select(view, "orders", [3], false)
        assert %{all: true, except: [3], count: 2} = selection(view, "orders")

        expected = if @source == "list", do: "ids 1,4", else: "query 1,4"
        assert read(view) == expected

        select_all(view, "orders", false)
        assert read(view) == "ids "
      end
    end
  end
end

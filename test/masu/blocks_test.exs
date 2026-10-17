defmodule Masu.BlocksTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Masu.Test

  @endpoint MasuTest.Endpoint

  # The reads of the source, as they came, until none come.
  defp reads(acc \\ []) do
    receive do
      {:read, offset, limit} -> reads([{offset, limit} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp open do
    conn = build_conn() |> init_test_session(%{"notify" => self()})
    {:ok, view, _html} = live(conn, "/blocks")
    # The first render and the connected one each read their first rows.
    reads()
    view
  end

  test "a grid reads blocks of its block_size, and no more than max_block at once" do
    {:ok, _view, html} =
      build_conn() |> init_test_session(%{"notify" => self()}) |> live("/blocks")

    assert {0, 250} in reads()
    # The server renders a few of the first block's rows; the browser has them all.
    assert html =~ ~s(&quot;blockSize&quot;:250)

    view = open()
    assert length(ids(view, "scroll", from: 250, count: 250)) == 250
    assert reads() == [{250, 250}]

    # A read past max_block (500, the default) is cut to it.
    assert length(ids(view, "scroll", from: 0, count: 2000)) == 500
    assert reads() == [{0, 500}]
  end

  test "a page is one read, however large: a page of 1,000 with max_block={1000}" do
    view = open()
    assert page(view, "report", 2) == Enum.to_list(1001..2000)
    assert reads() == [{1000, 1000}]

    assert length(page(view, "report", 3)) == 500
    assert reads() == [{2000, 1000}]
  end

  test "a block or a page larger than max_block is refused, with what to do" do
    assert_raise ArgumentError,
                 ~r/block_size is 600: it must be from 1 to max_block \(500\)/,
                 fn ->
                   render_component(&Masu.Components.data_grid/1,
                     id: "big",
                     rows: [],
                     col: [],
                     block_size: 600
                   )
                 end

    assert_raise ArgumentError, ~r/page_size is 1000: a page is one read.*raise max_block/, fn ->
      render_component(&Masu.Components.data_grid/1,
        id: "big",
        rows: [],
        col: [],
        paging: :pages,
        page_size: 1000
      )
    end
  end
end

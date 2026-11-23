defmodule MasuE2E.TallTest do
  use MasuE2E.Case, async: true, parameterize: MasuE2E.Case.projects()

  # A grid taller than a browser draws an element: 100,000 rows of 360
  # pixels are 36,000,000 pixels, more than Firefox (17,895,697) and
  # Chromium and WebKit (33,554,428) draw.

  @rows 100_000
  # The header is a row's height too: the box has room for two rows.
  @path "/bench?rows=#{@rows}&row_height=360&height=1200px"

  @moduletag timeout: 120_000

  # The indexes (from 0) of the rows wholly on the screen, once they are real rows.
  defp shown_rows(page) do
    box = grid(page, "bench")
    box |> Locator.locator(".masu-row.masu-loading") |> Expect.to_have_count!(0)

    Locator.evaluate!(box, """
    (el) => {
      const frame = el.getBoundingClientRect();
      const head = el.querySelector(".masu-head").getBoundingClientRect();
      return [...el.querySelectorAll(".masu-body .masu-row")]
        .filter((row) => {
          const rect = row.getBoundingClientRect();
          return rect.top >= head.bottom - 1 && rect.bottom <= frame.bottom + 1;
        })
        .map((row) => Number(row.getAttribute("aria-rowindex")) - 2)
        .sort((a, b) => a - b);
    }
    """)
  end

  test "the scrollbar at its end shows the last row", %{page: page} do
    open_page(page, @path)
    grid(page, "bench") |> Locator.evaluate!("(el) => (el.scrollTop = el.scrollHeight)")
    Expect.poll!(fn -> List.last(shown_rows(page)) end, &assert(&1 == @rows - 1))
  end

  test "the scrollbar in the middle shows the rows of the middle", %{page: page} do
    open_page(page, @path)

    grid(page, "bench")
    |> Locator.evaluate!("(el) => (el.scrollTop = (el.scrollHeight - el.clientHeight) / 2)")

    # An empty list's first is JS's undefined, and NaN < 20 is false: the poll retries.
    Expect.poll!(
      fn -> if first = Enum.at(shown_rows(page), 0), do: abs(first - @rows / 2) end,
      &assert(&1 != nil and &1 < 20)
    )
  end

  test "Ctrl+↓ goes to the last row", %{page: page} do
    open_page(page, @path)

    page
    |> Page.locator("#bench .masu-row[aria-rowindex='2'] .masu-cell")
    |> Locator.first()
    |> Locator.click!()

    page |> Page.keyboard() |> Keyboard.press!("ControlOrMeta+ArrowDown")
    Expect.poll!(fn -> List.last(shown_rows(page)) end, &assert(&1 == @rows - 1))
    Page.locator(page, "#bench .masu-cell.masu-active") |> Expect.to_be_visible!()
  end

  test "a wheel moves the rows by its pixels, not in proportion", %{page: page} do
    open_page(page, @path)
    box = grid(page, "bench")
    Locator.hover!(box)
    page |> Page.mouse() |> Mouse.wheel!(0, 720)
    # 720 pixels are two rows of 360.
    Expect.poll!(fn -> Enum.at(shown_rows(page), 0) end, &assert(&1 == 2))
    page |> Page.mouse() |> Mouse.wheel!(0, -720)
    Expect.poll!(fn -> Enum.at(shown_rows(page), 0) end, &assert(&1 == 0))
  end
end

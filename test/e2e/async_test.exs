defmodule MasuE2E.AsyncTest do
  use MasuE2E.Case, async: true, parameterize: MasuE2E.Case.projects()

  # A slow source read in a task (the Slow page, `load={:async}`), and a
  # controlled grid (the Controlled page, `on_query`): the LiveView runs
  # its query, a thousand rows a page, one sort at a time.

  defp open_grid(page, path, id) do
    Page.goto!(page, path)
    Page.locator(page, "[data-phx-main].phx-connected") |> Expect.to_be_visible!()
    Page.locator(page, "##{id}-state .masu-running") |> Expect.to_have_count!(0, timeout: 10_000)

    page
    |> Page.locator("##{id} .masu-body .masu-row")
    |> Locator.first()
    |> Expect.to_be_visible!()
  end

  describe "a slow source, read in a task" do
    test "a sort runs while the page answers, says so, and shows its rows when they come", %{
      page: page
    } do
      open_grid(page, "/slow?delay=600", "slow")
      before = row_text(page, "slow", 0)

      header(page, "slow", "seats") |> Locator.click!()
      running = Page.locator(page, ~s(#slow-state .masu-running[role="status"]))
      running |> Expect.to_contain_text!("Running…")
      Page.locator(page, "#slow") |> Expect.to_have_class!(~r/masu-busy/)
      # The old rows stay until the new ones come.
      assert row_text(page, "slow", 0) == before

      running |> Expect.to_have_count!(0, timeout: 10_000)
      Page.locator(page, "#slow") |> Expect.not_() |> Expect.to_have_class!(~r/masu-busy/)
      header(page, "slow", "seats") |> Expect.to_have_attribute!("aria-sort", "ascending")
      assert page |> row_text("slow", 0) |> Enum.at(2) |> number() == 1
    end

    test "Stop keeps the rows and the order it had", %{page: page} do
      open_grid(page, "/slow?delay=1500", "slow")
      before = row_text(page, "slow", 0)

      header(page, "slow", "seats") |> Locator.click!()
      Page.locator(page, "#slow-state .masu-state-button", has_text: "Stop") |> Locator.click!()
      Page.locator(page, "#slow-state .masu-running") |> Expect.to_have_count!(0)
      Page.locator(page, "#slow") |> Expect.not_() |> Expect.to_have_class!(~r/masu-busy/)
      header(page, "slow", "seats") |> Expect.to_have_attribute!("aria-sort", "none")
      assert row_text(page, "slow", 0) == before
    end

    test "scrolling far reads the rows it lacks in tasks", %{page: page} do
      open_grid(page, "/slow?delay=100", "slow")
      grid(page, "slow") |> Locator.evaluate!("(el) => (el.scrollTop = 36 * 50_000)")
      row = Page.locator(page, ~s(#slow .masu-body .masu-row[aria-rowindex="50003"]))
      row |> Expect.to_be_visible!(timeout: 10_000)
      row |> Expect.not_() |> Expect.to_have_class!(~r/masu-loading/, timeout: 10_000)
    end
  end

  describe "a controlled grid" do
    test "the person's sort goes to the LiveView, which runs its query once, and the grid shows its rows",
         %{page: page} do
      open_grid(page, "/controlled", "controlled")
      runs = Page.locator(page, "#runs")
      runs |> Expect.to_have_text!("1")
      grid(page, "controlled") |> Expect.to_have_attribute!("aria-rowcount", "100001")

      header(page, "controlled", "seats") |> Locator.click!()
      Page.locator(page, "#controlled-state .masu-running") |> Expect.to_contain_text!("Running…")
      settled(page, "controlled")

      Page.locator(page, "#controlled-state .masu-running")
      |> Expect.to_have_count!(0, timeout: 10_000)

      runs |> Expect.to_have_text!("2")
      header(page, "controlled", "seats") |> Expect.to_have_attribute!("aria-sort", "ascending")
      assert page |> row_text("controlled", 0) |> Enum.at(3) |> number() == 1

      # One sort at a time: Shift adds none.
      header(page, "controlled", "name") |> Locator.click!(modifiers: [:shift])

      Page.locator(page, "#controlled-state .masu-running")
      |> Expect.to_have_count!(0, timeout: 10_000)

      runs |> Expect.to_have_text!("3")
      header(page, "controlled", "name") |> Expect.to_have_attribute!("aria-sort", "ascending")
      header(page, "controlled", "seats") |> Expect.to_have_attribute!("aria-sort", "none")
    end

    test "the pager goes to the LiveView's next page of a thousand", %{page: page} do
      open_grid(page, "/controlled", "controlled")

      Page.locator(page, "#controlled .masu-pager")
      |> Locator.get_by_role(:button, name: "Next")
      |> Locator.click!()

      Page.locator(page, "#controlled-state .masu-running")
      |> Expect.to_have_count!(0, timeout: 10_000)

      Page.locator(page, "#runs") |> Expect.to_have_text!("2")

      Page.locator(page, "#controlled .masu-pager-range")
      |> Expect.to_have_text!("1,001–2,000 of 100,000")

      Page.locator(page, ~s(#controlled .masu-body .masu-row[aria-rowindex="1002"]))
      |> Expect.to_be_visible!()
    end
  end
end

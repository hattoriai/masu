defmodule MasuE2E.HistoryTest do
  use MasuE2E.Case, async: true, parameterize: MasuE2E.Case.projects()

  # The history of cells (Masu.History), on the History page: a budget of
  # item, owner, amount, kept in memory by the server for the whole run;
  # each test edits rows of its own.

  defp popover(page), do: Page.locator(page, ~s(#budget [role="dialog"].masu-history))

  defp type(page, row, col, text, shown) do
    cell(page, "budget", row, col) |> Locator.click!()
    page |> Page.keyboard() |> Keyboard.type!(text)
    page |> Page.keyboard() |> Keyboard.press!("Enter")
    cell(page, "budget", row, col) |> Expect.to_have_text!(shown)
  end

  setup %{page: page} do
    open_page(page, "/history")
    :ok
  end

  test "a cell's history: its values, who and when, from its menu and Ctrl+Alt+H; Restore brings one back",
       %{page: page} do
    before = cell(page, "budget", 0, 2) |> Locator.text_content!() |> String.trim()
    type(page, 0, 2, "1250", "1,250")
    type(page, 0, 2, "1300", "1,300")

    cell(page, "budget", 0, 2) |> Locator.click!(button: :right)

    Page.locator(page, ~s(#budget [role="menu"]))
    |> Locator.get_by_role(:menuitem, name: "History", exact: true)
    |> Locator.click!()

    popover(page) |> Expect.to_have_accessible_name!("Amount: history")
    entries = popover(page) |> Locator.locator(".masu-history-entry")
    entries |> Locator.first() |> Expect.to_contain_text!("1,300")
    entries |> Locator.first() |> Expect.to_contain_text!("was 1,250")
    entries |> Locator.first() |> Expect.to_contain_text!("Ada")
    popover(page) |> Locator.get_by_role(:button) |> Locator.first() |> Expect.to_be_focused!()
    page |> Page.keyboard() |> Keyboard.press!("Escape")
    popover(page) |> Expect.to_have_count!(0)
    grid(page, "budget") |> Expect.to_be_focused!()

    # The value before the first change, from the keyboard.
    page |> Page.keyboard() |> Keyboard.press!("Control+Alt+h")
    # This run's first change (the server's memory keeps the runs before).
    entries
    |> Locator.nth(1)
    |> Locator.get_by_role(:button, name: "Restore #{before}")
    |> Locator.click!()

    cell(page, "budget", 0, 2) |> Expect.to_have_text!(before)

    page |> Page.keyboard() |> Keyboard.press!("Control+Alt+h")
    entries |> Locator.first() |> Expect.to_contain_text!("restored")
  end

  test "a row's history, and a batch undone at once: a fill down of two cells", %{page: page} do
    # Power's amount down over Water and Internet: one write of two cells,
    # with no clipboard (which only Chromium lets a test use).
    amount = cell(page, "budget", 1, 2) |> Locator.text_content!() |> String.trim()
    cell(page, "budget", 1, 2) |> Locator.click!()
    page |> Page.keyboard() |> Keyboard.press!("Shift+ArrowDown")
    page |> Page.keyboard() |> Keyboard.press!("Shift+ArrowDown")
    page |> Page.keyboard() |> Keyboard.press!("ControlOrMeta+d")
    cell(page, "budget", 3, 2) |> Expect.to_have_text!(amount)

    cell(page, "budget", 3, 0) |> Locator.click!(button: :right)

    Page.locator(page, ~s(#budget [role="menu"]))
    |> Locator.get_by_role(:menuitem, name: "Row history")
    |> Locator.click!()

    # The newest first (the memory of the server keeps the entries of runs before).
    latest = popover(page) |> Locator.locator(".masu-history-entry") |> Locator.first()
    latest |> Expect.to_contain_text!("Amount: #{amount}")
    latest |> Expect.to_contain_text!("filled")
    latest |> Locator.get_by_role(:button, name: "Undo all 2") |> Locator.click!()
    cell(page, "budget", 2, 2) |> Expect.to_have_text!("40")
    cell(page, "budget", 3, 2) |> Expect.to_have_text!("35")
  end
end

defmodule MasuE2E.EditorsTest do
  use MasuE2E.Case, async: true, parameterize: MasuE2E.Case.projects()

  # Editors of the app's own, on the Editors page: editors of the browser's
  # given to configure({editors}) (a slider with options, a color), and
  # forms the server renders in a popover (notes in a text area, a window
  # of two days). Its columns: title, score, color, notes, window.

  defp popover(page), do: Page.locator(page, "#editors-cell-editor")

  setup %{page: page} do
    open_page(page, "/editors")
    :ok
  end

  test "an editor of the browser's: Enter opens it with its options, its keys are its own, Enter saves",
       %{page: page} do
    before = cell(page, "editors", 0, 1) |> Locator.text_content!() |> number()
    cell(page, "editors", 0, 1) |> Locator.click!()
    page |> Page.keyboard() |> Keyboard.press!("Enter")
    slider = Page.locator(page, "#editors .masu-own-editor input[type=range]")
    slider |> Expect.to_be_focused!()
    slider |> Expect.to_have_attribute!("step", "5")
    slider |> Expect.to_have_attribute!("aria-label", "Score")
    page |> Page.keyboard() |> Keyboard.press!("ArrowRight")
    page |> Page.keyboard() |> Keyboard.press!("Enter")
    slider |> Expect.to_have_count!(0)
    cell(page, "editors", 0, 1) |> Expect.not_() |> Expect.to_have_text!(to_string(before))
    # Enter moved down, as it does for the grid's own editors.
    grid(page, "editors") |> Expect.to_be_focused!()
    grid(page, "editors") |> Expect.to_have_attribute!("aria-activedescendant", "editors-r1-c1")

    # Escape lets an edit go; undo brings the saved one back.
    cell(page, "editors", 0, 1) |> Locator.click!()
    page |> Page.keyboard() |> Keyboard.press!("Enter")
    page |> Page.keyboard() |> Keyboard.press!("ArrowRight")
    page |> Page.keyboard() |> Keyboard.press!("Escape")
    slider |> Expect.to_have_count!(0)
    page |> Page.keyboard() |> Keyboard.press!("Control+z")
    cell(page, "editors", 0, 1) |> Expect.to_have_text!(to_string(before))
  end

  test "a form the server renders: a popover under the cell, labelled, that keeps Enter, and saves with Ctrl+Enter",
       %{page: page} do
    cell(page, "editors", 0, 3) |> Locator.click!()
    page |> Page.keyboard() |> Keyboard.press!("Enter")
    popover(page) |> Expect.to_have_attribute!("role", "dialog")
    popover(page) |> Expect.to_have_accessible_name!("Notes")
    area = popover(page) |> Locator.locator("textarea")
    area |> Expect.to_be_focused!()
    page |> Page.keyboard() |> Keyboard.type!("Ring Ada")
    page |> Page.keyboard() |> Keyboard.press!("Enter")
    page |> Page.keyboard() |> Keyboard.type!("twice")
    page |> Page.keyboard() |> Keyboard.press!("Control+Enter")
    popover(page) |> Expect.to_have_count!(0)
    cell(page, "editors", 0, 3) |> Expect.to_have_text!("Ring Ada twice")
    grid(page, "editors") |> Expect.to_be_focused!()

    page |> Page.keyboard() |> Keyboard.press!("Control+z")
    cell(page, "editors", 0, 3) |> Expect.to_have_text!("")

    # Escape lets it go.
    page |> Page.keyboard() |> Keyboard.press!("Enter")
    area |> Expect.to_be_focused!()
    page |> Page.keyboard() |> Keyboard.type!("nope")
    page |> Page.keyboard() |> Keyboard.press!("Escape")
    popover(page) |> Expect.to_have_count!(0)
    cell(page, "editors", 0, 3) |> Expect.to_have_text!("")
  end

  test "a form posts params (from and to); the server's error goes on the cell, which keeps its value",
       %{page: page} do
    shown = cell(page, "editors", 1, 4) |> Locator.text_content!() |> String.trim()
    cell(page, "editors", 1, 4) |> Locator.dblclick!()

    popover(page)
    |> Locator.locator("input[type=date]")
    |> Locator.first()
    |> Locator.fill!("2027-04-30")

    popover(page) |> Locator.get_by_role(:button, name: "Save") |> Locator.click!()
    cell(page, "editors", 1, 4) |> Expect.to_have_attribute!("title", "ends before it starts")
    cell(page, "editors", 1, 4) |> Expect.to_have_text!(shown)

    cell(page, "editors", 1, 4) |> Locator.dblclick!()

    popover(page)
    |> Locator.locator("input[type=date]")
    |> Locator.first()
    |> Locator.fill!("2027-03-01")

    popover(page) |> Locator.get_by_role(:button, name: "Save") |> Locator.click!()
    cell(page, "editors", 1, 4) |> Expect.to_have_text!(~r/2027-03-01 → /)
    cell(page, "editors", 1, 4) |> Expect.not_() |> Expect.to_have_attribute!("title", ~r/.+/)
  end

  test "a click away saves a form", %{page: page} do
    cell(page, "editors", 2, 3) |> Locator.click!()
    page |> Page.keyboard() |> Keyboard.press!("Enter")
    popover(page) |> Locator.locator("textarea") |> Locator.fill!("Left by a click")
    cell(page, "editors", 5, 0) |> Locator.click!()
    popover(page) |> Expect.to_have_count!(0)
    cell(page, "editors", 2, 3) |> Expect.to_have_text!("Left by a click")
  end
end

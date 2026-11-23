defmodule MasuE2E.ActionsTest do
  use MasuE2E.Case, async: true, parameterize: MasuE2E.Case.projects()

  # Actions of the app's own (Masu.Action), on the Actions page: on the
  # rows selected (the bar above the grid), and on each row (the menu at
  # its end, and in the menu of its cells). Its columns: name, city, plan,
  # active.

  defp more(page, row),
    do: Page.locator(page, "#actions-r#{row}-actions .masu-row-actions-button")

  defp bar(page), do: Page.locator(page, "#actions .masu-selection-bar")
  defp task(page), do: Page.locator(page, "#actions .masu-task")

  setup %{page: page} do
    open_page(page, "/actions")
    :ok
  end

  test "the button at a row's end opens its actions: a link, an action, one that is not available",
       %{page: page} do
    # The first customer that is active, and the first that is not.
    rows =
      [0, 1, 2, 3, 4]
      |> Enum.map(fn i -> Playwright.Promise.async(fn -> row_text(page, "actions", i) end) end)
      |> Playwright.Promise.all()
      |> Playwright.Promise.await!()

    active = Enum.find_index(rows, &(Enum.at(&1, 3) == "✓"))
    inactive = Enum.find_index(rows, &(Enum.at(&1, 3) == ""))

    more(page, active) |> Locator.click!()
    menu(page, "actions") |> Expect.to_have_attribute!("aria-label", "Row actions")

    menu(page, "actions")
    |> Locator.get_by_role(:menuitem)
    |> Expect.to_have_text!(["Open", "Deactivate", "Remove"])

    item(page, "actions", "Open") |> Expect.to_have_attribute!("href", ~r/\/actions\?open=\d+/)

    item(page, "actions", "Deactivate")
    |> Expect.not_()
    |> Expect.to_have_attribute!("aria-disabled", "true")

    item(page, "actions", "Deactivate") |> Locator.click!()
    task(page) |> Expect.to_have_text!("#{rows |> Enum.at(active) |> Enum.at(0)} deactivated")
    settled(page, "actions")
    Expect.poll!(fn -> Enum.at(row_text(page, "actions", active), 3) end, &assert(&1 == ""))

    more(page, inactive) |> Locator.click!()
    item(page, "actions", "Deactivate") |> Expect.to_have_attribute!("aria-disabled", "true")
    page |> Page.keyboard() |> Keyboard.press!("ArrowDown")
    item(page, "actions", "Deactivate") |> Expect.to_be_focused!()
    page |> Page.keyboard() |> Keyboard.press!("Enter")
    # Not available: the menu stays, and nothing runs.
    menu(page, "actions") |> Expect.to_be_visible!()
    page |> Page.keyboard() |> Keyboard.press!("Escape")
    menu(page, "actions") |> Expect.to_have_count!(0)
    grid(page, "actions") |> Expect.to_be_focused!()
  end

  test "a link patches the LiveView's URL, as a link does", %{page: page} do
    [name | _] = row_text(page, "actions", 0)
    more(page, 0) |> Locator.click!()
    item(page, "actions", "Open") |> Locator.click!()
    Expect.to_have_url!(page, ~r/\/actions\?open=\d+$/)
    Page.locator(page, "#said") |> Expect.to_have_text!("Opened #{name}")
  end

  test "Shift+F10 on a cell opens its menu with the row's actions, and an action asks first",
       %{page: page} do
    [name | _] = row_text(page, "actions", 1)
    Page.locator(page, "#actions-r1-c1") |> Locator.click!()
    page |> Page.keyboard() |> Keyboard.press!("Shift+F10")

    menu(page, "actions")
    |> Locator.get_by_role(:menuitem)
    |> Expect.to_have_text!(["Open", "Deactivate", "Remove"])

    menu(page, "actions") |> Locator.locator(":focus") |> Expect.to_have_text!("Open")
    page |> Page.keyboard() |> Keyboard.press!("End")
    page |> Page.keyboard() |> Keyboard.press!("Enter")

    question = Page.locator(page, "#actions .masu-confirm")
    question |> Expect.to_contain_text!("Remove this customer?")
    question |> Locator.get_by_role(:button, name: "Remove") |> Locator.click!()
    settled(page, "actions")
    Expect.poll!(fn -> Enum.at(row_text(page, "actions", 1), 0) end, &assert(&1 != name))
  end

  test "the bar of the rows selected has the actions; one runs on them, and the selection clears",
       %{page: page} do
    Page.locator(page, "#actions-r0-c0 .masu-select") |> Locator.click!()
    Page.locator(page, "#actions-r1-c0 .masu-select") |> Locator.click!()
    bar(page) |> Expect.to_contain_text!("2 selected")

    bar(page)
    |> Locator.get_by_role(:button)
    |> Expect.to_have_text!(["Deactivate", "Export later", "Remove", "Clear"])

    bar(page) |> Locator.get_by_role(:button, name: "Deactivate") |> Locator.click!()
    task(page) |> Expect.to_have_text!("2 deactivated")
    bar(page) |> Expect.to_have_count!(0)
    Expect.poll!(fn -> Enum.at(row_text(page, "actions", 0), 3) end, &assert(&1 == ""))
  end

  test "an action asks first with the count, and one that goes on later says how far it is",
       %{page: page} do
    Page.locator(page, "#actions-r0-c0 .masu-select") |> Locator.click!()
    Page.locator(page, "#actions-r1-c0 .masu-select") |> Locator.click!()
    Page.locator(page, "#actions-r2-c0 .masu-select") |> Locator.click!()

    bar(page) |> Locator.get_by_role(:button, name: "Remove") |> Locator.click!()
    question = Page.locator(page, "#actions .masu-confirm")
    question |> Expect.to_contain_text!("Remove 3 customers?")
    question |> Locator.get_by_role(:button, name: "Cancel") |> Locator.click!()
    bar(page) |> Expect.to_contain_text!("3 selected")

    bar(page) |> Locator.get_by_role(:button, name: "Export later") |> Locator.click!()
    task(page) |> Expect.to_have_text!(~r/Export later: (running…|\d of 3)/)
    task(page) |> Expect.to_have_text!("3 exported", timeout: 5000)
  end
end

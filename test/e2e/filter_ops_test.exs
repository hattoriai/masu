defmodule MasuE2E.FilterOpsTest do
  use MasuE2E.Case, async: true, parameterize: MasuE2E.Case.projects()

  # A source that runs some filters only (the Some filters page: Lotus
  # Web's = ≠ > < ≥ ≤ LIKE, null and not null): the menus offer those.
  # Its columns: name, city (an enum), seats, signed up.

  setup %{page: page} do
    open_page(page, "/limited")
    :ok
  end

  test "an enum without 'is one of' filters by one of its values", %{page: page} do
    header(page, "limited", "city") |> Locator.hover!()
    header(page, "limited", "city") |> Locator.locator(".masu-filter-button") |> Locator.click!()
    menu = Page.locator(page, "#limited .masu-menu")
    op = menu |> Locator.locator(".masu-menu-op")

    op
    |> Locator.locator("option")
    |> Expect.to_have_text!(["is", "is not", "is empty", "is not empty"])

    menu |> Locator.locator(".masu-menu-value") |> Expect.to_have_count!(0)

    menu |> Locator.locator("select.masu-menu-input") |> Locator.select_option!("Porto")
    menu |> Locator.locator(".masu-menu-apply") |> Locator.click!()
    settled(page, "limited")
    Page.locator(page, "#limited .masu-chip-text") |> Expect.to_have_text!(["City is Porto"])
    assert Enum.at(row_text(page, "limited", 0), 1) == "Porto"
  end

  test "a number still has between, which Masu runs as ≥ and ≤", %{page: page} do
    header(page, "limited", "seats") |> Locator.hover!()
    header(page, "limited", "seats") |> Locator.locator(".masu-filter-button") |> Locator.click!()
    op = Page.locator(page, "#limited .masu-menu-op")

    op
    |> Locator.locator("option")
    |> Expect.to_have_text!([
      "is",
      "is not",
      "greater than",
      "at least",
      "less than",
      "at most",
      "between",
      "is empty",
      "is not empty"
    ])

    op |> Locator.select_option!("between")
    Page.locator(page, "#limited .masu-menu-input") |> Locator.nth(0) |> Locator.fill!("10")
    Page.locator(page, "#limited .masu-menu-input") |> Locator.nth(1) |> Locator.fill!("12")
    Page.locator(page, "#limited .masu-menu-input") |> Locator.nth(1) |> Locator.press!("Enter")
    settled(page, "limited")

    Page.locator(page, "#limited .masu-chip-text")
    |> Expect.to_have_text!(["Seats between 10 and 12"])

    seats = page |> row_text("limited", 0) |> Enum.at(2) |> number()
    assert seats >= 10
    assert seats <= 12
  end

  test "a cell's menu filters an enum by its value with 'is'", %{page: page} do
    [_, city | _] = row_text(page, "limited", 0)
    Page.locator(page, "#limited-r0-c1") |> Locator.click!(button: :right)

    Page.locator(page, ~s(#limited [role="menu"]))
    |> Locator.get_by_role(:menuitem, name: "Filter by #{city}", exact: true)
    |> Locator.click!()

    settled(page, "limited")
    Page.locator(page, "#limited .masu-chip-text") |> Expect.to_have_text!(["City is #{city}"])
  end

  test "a cell's menu compares text when the source runs the comparisons, as a SQL client does",
       %{page: page} do
    name = Enum.at(row_text(page, "limited", 0), 0)

    Page.locator(page, "#limited-r0-c0") |> Locator.click!(button: :right)
    menu = Page.locator(page, ~s(#limited [role="menu"]))

    menu
    |> Locator.get_by_role(:menuitem)
    |> Expect.to_contain_text!([
      "Filter by #{name}",
      "Exclude #{name}",
      "Greater than #{name}",
      "Less than #{name}",
      "At least #{name}",
      "At most #{name}",
      "Contains #{name}"
    ])

    menu
    |> Locator.get_by_role(:menuitem, name: "Greater than #{name}", exact: true)
    |> Locator.click!()

    settled(page, "limited")

    Page.locator(page, "#limited .masu-chip-text")
    |> Expect.to_have_text!(["Name greater than #{name}"])

    for row <- 0..2 do
      text = Enum.at(row_text(page, "limited", row), 0)
      # JS compares strings by UTF-16 code units; the names here are ASCII.
      if text != nil, do: assert(text > name)
    end
  end
end

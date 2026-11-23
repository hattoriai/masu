defmodule MasuE2E.RelatedTest do
  use MasuE2E.Case, async: true, parameterize: MasuE2E.Case.projects()

  # Fields of related rows (the Related page): the customer's name and
  # their company's country, one value each, and the tags, many values.

  setup %{page: page} do
    open_page(page, "/related")
    :ok
  end

  test "a column of a related row's field sorts and filters as any other", %{page: page} do
    header(page, "related", "customer.name") |> Locator.click!()
    settled(page, "related")

    header(page, "related", "customer.name")
    |> Expect.to_have_attribute!("aria-sort", "ascending")

    first = Enum.at(row_text(page, "related", 0), 2)
    second = Enum.at(row_text(page, "related", 1), 2)
    assert locale_compare(page, first, second) <= 0

    header(page, "related", "country") |> Locator.hover!()

    header(page, "related", "country")
    |> Locator.locator(".masu-filter-button")
    |> Locator.click!()

    menu = Page.locator(page, "#related .masu-menu")

    menu
    |> Locator.locator(".masu-menu-value", has_text: "Japan")
    |> Locator.locator("input")
    |> Locator.check!()

    menu |> Locator.locator(".masu-menu-apply") |> Locator.click!()
    settled(page, "related")

    Page.locator(page, "#related .masu-chip-text")
    |> Expect.to_have_text!(["Country is one of Japan"])

    assert Enum.at(row_text(page, "related", 0), 3) == "Japan"
  end

  test "a column of many values shows them apart, filters by has any, all or none of, and does not sort",
       %{page: page} do
    tags = header(page, "related", "tags")
    assert Locator.get_attribute!(tags, "aria-sort") == nil

    Locator.hover!(tags)
    tags |> Locator.locator(".masu-filter-button") |> Locator.click!()
    menu = Page.locator(page, "#related .masu-menu")

    menu
    |> Locator.locator(".masu-menu-op option")
    |> Expect.to_have_text!(["has any of", "has all of", "has none of", "has none", "has some"])

    menu |> Locator.locator(".masu-menu-group") |> Expect.to_have_count!(0)

    menu |> Locator.locator(".masu-menu-op") |> Locator.select_option!("all_of")

    menu
    |> Locator.locator(".masu-menu-value", has_text: "gift")
    |> Locator.locator("input")
    |> Locator.check!()

    menu
    |> Locator.locator(".masu-menu-value", has_text: "bulk")
    |> Locator.locator("input")
    |> Locator.check!()

    menu |> Locator.locator(".masu-menu-apply") |> Locator.click!()
    settled(page, "related")

    chip = Page.locator(page, "#related .masu-chip-text") |> Locator.text_content!()
    assert chip =~ ~r/^Tags has all of (gift, bulk|bulk, gift)$/
    cell = Enum.at(row_text(page, "related", 0), 4)
    assert ["gift", "bulk"] -- String.split(cell, ", ") == []
  end

  test "a cell's menu of many values filters by none or some", %{page: page} do
    Page.locator(page, "#related-r0-c4") |> Locator.click!(button: :right)
    menu = Page.locator(page, ~s(#related [role="menu"]))

    menu
    |> Locator.get_by_role(:menuitem, name: "Filter by none", exact: true)
    |> Expect.to_be_visible!()

    menu
    |> Locator.get_by_role(:menuitem, name: "Filter by none", exact: true)
    |> Locator.click!()

    settled(page, "related")
    Page.locator(page, "#related .masu-chip-text") |> Expect.to_have_text!(["Tags has none"])
    assert Enum.at(row_text(page, "related", 0), 4) == ""
  end

  # JS's String.prototype.localeCompare, which Elixir has not: the browser's.
  defp locale_compare(page, a, b),
    do: Page.evaluate!(page, "([a, b]) => a.localeCompare(b)", [a, b])
end

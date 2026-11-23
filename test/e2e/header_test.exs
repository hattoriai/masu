defmodule MasuE2E.HeaderTest do
  use MasuE2E.Case, async: true, parameterize: MasuE2E.Case.projects()

  # The headers (dev.exs, /header): the filter bar, the default; the
  # filters in the bar alone (header_filters={false}); and the leaner
  # header of filter_bar={false}.

  setup %{page: page} do
    open_page(page, "/header")
    :ok
  end

  test "the filter bar: Add filter lists the columns, and one picked opens its menu", %{
    page: page
  } do
    add = Page.locator(page, "#bar .masu-add-filter")
    add |> Expect.to_have_text!("Add filter")
    add |> Locator.click!()
    panel = Page.locator(page, "#bar .masu-filters-panel")

    panel
    |> Locator.locator(".masu-menu-item")
    |> Expect.to_have_text!(["Handle", "Title", "Slug", "Views", "Visitors"])

    panel
    |> Locator.locator(~s(.masu-menu-item[data-filtered="true"]))
    |> Expect.to_have_text!(["Views"])

    panel |> Locator.locator(".masu-menu-item", has_text: "Title") |> Locator.click!()
    panel |> Expect.to_have_count!(0)
    # The column's filter alone, under Add filter.
    menu = Page.locator(page, "#bar .masu-menu")
    menu |> Expect.to_have_attribute!("aria-label", "Filter Title")
    menu |> Locator.locator(".masu-menu-sort") |> Expect.to_have_count!(0)
    add_box = Locator.bounding_box!(add)
    menu_box = Locator.bounding_box!(menu)
    assert abs(menu_box.y - (add_box.y + add_box.height + 4)) < 2
    menu |> Locator.locator(".masu-menu-input") |> Locator.fill!("tide")
    menu |> Locator.locator(".masu-menu-input") |> Locator.press!("Enter")
    settled(page, "bar")

    Page.locator(page, "#bar .masu-chip-text")
    |> Expect.to_have_text!(["Views at least 50", "Title contains tide"])

    assert "Low Tide" in row_text(page, "bar", 0)
    add |> Expect.to_be_focused!()

    # A chip opens its filter, to change it.
    Page.locator(page, "#bar .masu-chip-text", has_text: "Views") |> Locator.click!()
    menu |> Expect.to_have_attribute!("aria-label", "Filter Views")
    menu |> Locator.locator(".masu-menu-input") |> Expect.to_have_value!("50")
  end

  test "the filter bar: a header's menu sorts, and a chip takes its filter away", %{page: page} do
    header(page, "bar", "visitors") |> Locator.hover!()
    header(page, "bar", "visitors") |> Locator.locator(".masu-filter-button") |> Locator.click!()
    menu = Page.locator(page, "#bar .masu-menu")

    menu
    |> Locator.locator(".masu-menu-sort")
    |> Expect.to_have_text!(["Sort ascending", "Sort descending"])

    menu |> Locator.locator(".masu-menu-sort", has_text: "Sort ascending") |> Locator.click!()
    settled(page, "bar")
    header(page, "bar", "visitors") |> Expect.to_have_attribute!("aria-sort", "ascending")
    assert Enum.at(row_text(page, "bar", 0), 4) == "38"

    Page.locator(page, "#bar .masu-chip-remove") |> Locator.click!()
    settled(page, "bar")
    Page.locator(page, "#bar .masu-chip") |> Expect.to_have_count!(0)
    # The bar stays, with Add filter.
    Page.locator(page, "#bar .masu-add-filter") |> Expect.to_be_visible!()
  end

  test "a header of numbers keeps its label clear of its button, over its values", %{page: page} do
    for id <- ["bar", "bar-only", "lean"] do
      cell = header(page, id, "views")
      Locator.hover!(cell)
      label = cell |> Locator.locator(".masu-label") |> Locator.bounding_box!()
      button = cell |> Locator.locator(".masu-filter-button") |> Locator.bounding_box!()
      assert button.x + button.width <= label.x, id
    end
  end

  test "the leaner header: a funnel on each header that filters, and no Add filter", %{page: page} do
    Page.locator(page, "#lean .masu-add-filter") |> Expect.to_have_count!(0)

    header(page, "lean", "views")
    |> Locator.locator(".masu-filter-button")
    |> Expect.to_have_attribute!("data-active", "true")

    header(page, "lean", "title")
    |> Locator.locator(".masu-filter-button")
    |> Expect.to_have_attribute!("aria-label", "Filter Title")
  end

  test "the filters in the bar alone: a header's menu sorts, and has no filter", %{page: page} do
    header(page, "bar-only", "title") |> Locator.hover!()
    button = header(page, "bar-only", "title") |> Locator.locator(".masu-filter-button")
    button |> Expect.to_have_attribute!("aria-label", "Title menu")
    button |> Locator.click!()
    menu = Page.locator(page, "#bar-only .masu-menu")
    menu |> Expect.to_have_attribute!("aria-label", "Title menu")

    menu
    |> Locator.locator(".masu-menu-sort")
    |> Expect.to_have_text!(["Sort ascending", "Sort descending"])

    menu |> Locator.locator(".masu-menu-form") |> Expect.to_have_count!(0)
    page |> Page.keyboard() |> Keyboard.press!("Escape")

    Page.locator(page, "#bar-only .masu-add-filter") |> Locator.click!()

    Page.locator(page, "#bar-only .masu-filters-panel .masu-menu-item", has_text: "Title")
    |> Locator.click!()

    menu |> Expect.to_have_attribute!("aria-label", "Filter Title")
    menu |> Locator.locator(".masu-menu-form") |> Expect.to_have_count!(1)
  end
end

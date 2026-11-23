defmodule MasuE2E.ResultsTest do
  use MasuE2E.Case, async: true, parameterize: MasuE2E.Case.projects()

  # A query tool's results (the Results page): column names and rows as
  # lists of values, of no types. The grid learns each column's type.

  setup %{page: page} do
    open_page(page, "/results")
    :ok
  end

  test "each column shows as the type of its values", %{page: page} do
    Page.locator(page, "#results .masu-hcell .masu-label")
    |> Expect.to_have_text!([
      "Id",
      "Name",
      "City",
      "Plan",
      "Seats",
      "Revenue",
      "Active",
      "Signed up",
      "Last seen"
    ])

    cells = row_text(page, "results", 13)
    assert Enum.at(cells, 0) == "14"
    assert Enum.at(cells, 5) == "1,108.66"
    assert Enum.at(cells, 6) == "✓"
    assert Enum.at(cells, 7) =~ ~r/^\d{1,2} [A-Z][a-z]{2} \d{4}$/
    header(page, "results", "revenue") |> Expect.to_have_class!(~r/masu-align-end/)

    # A number's filters, not text's.
    header(page, "results", "seats") |> Locator.hover!()
    header(page, "results", "seats") |> Locator.locator(".masu-filter-button") |> Locator.click!()

    Page.locator(page, "#results .masu-menu-op option", has_text: "between")
    |> Expect.to_have_count!(1)

    Page.locator(page, "#results .masu-menu-op option", has_text: "contains")
    |> Expect.to_have_count!(0)
  end

  test "another query brings other columns; the view keeps what is of those there still", %{
    page: page
  } do
    header(page, "results", "seats") |> Locator.click!()
    settled(page, "results")
    header(page, "results", "city") |> Locator.hover!()
    header(page, "results", "city") |> Locator.locator(".masu-filter-button") |> Locator.click!()
    Page.locator(page, "#results .masu-menu-input") |> Locator.fill!("o")
    Page.locator(page, "#results .masu-menu-input") |> Locator.press!("Enter")
    settled(page, "results")
    Page.locator(page, "#results .masu-chip-text") |> Expect.to_have_text!(["City contains o"])

    Page.locator(page, "#run select") |> Locator.select_option!("plans")

    Page.locator(page, "#results .masu-hcell .masu-label")
    |> Expect.to_have_text!(["Plan", "Customers", "Revenue", "Seats"])

    Page.locator(page, "#results .masu-chip") |> Expect.to_have_count!(0)

    Page.locator(page, "#results .masu-status")
    |> Expect.to_have_text!("Part of this view no longer applies: city")

    header(page, "results", "seats") |> Expect.to_have_attribute!("aria-sort", "ascending")
    first = page |> row_text("results", 0) |> Enum.at(3) |> number()
    second = page |> row_text("results", 1) |> Enum.at(3) |> number()
    assert first <= second
  end

  describe "in a browser far from UTC" do
    @describetag Test.use(timezone_id: "Asia/Tokyo")

    test "a datetime without a zone filters as the cells show it, not moved to the browser's time",
         %{page: page} do
      Page.locator(page, "#run select") |> Locator.select_option!("logins")

      Page.locator(page, "#results .masu-hcell .masu-label")
      |> Expect.to_have_text!(["Id", "Name", "Logged in at"])

      # "14 Mar 2026, 05:12": as written, in no zone.
      [id, _, shown | _] = row_text(page, "results", 0)

      [_, day, mon, year, hour, minute] =
        Regex.run(~r/^(\d{1,2}) ([A-Z][a-z]{2}) (\d{4}), (\d{2}):(\d{2})$/, shown)

      months = ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

      date =
        "#{year}-#{String.pad_leading(to_string(Enum.find_index(months, &(&1 == mon)) + 1), 2, "0")}-#{String.pad_leading(day, 2, "0")}T#{hour}:#{minute}"

      header(page, "results", "logged_in_at") |> Locator.hover!()

      header(page, "results", "logged_in_at")
      |> Locator.locator(".masu-filter-button")
      |> Locator.click!()

      menu = Page.locator(page, "#results .masu-menu")
      menu |> Locator.locator(".masu-menu-op") |> Locator.select_option!("between")

      next =
        NaiveDateTime.from_iso8601!(date <> ":00")
        |> NaiveDateTime.add(60)
        |> NaiveDateTime.to_iso8601()
        |> String.slice(0, 16)

      menu |> Locator.locator(".masu-menu-input") |> Locator.nth(0) |> Locator.fill!(date)
      menu |> Locator.locator(".masu-menu-input") |> Locator.nth(1) |> Locator.fill!(next)
      menu |> Locator.locator(".masu-menu-apply") |> Locator.click!()
      settled(page, "results")

      assert Enum.at(row_text(page, "results", 0), 0) == id
      assert Enum.at(row_text(page, "results", 0), 2) == shown
    end
  end
end

# ExUnit runs a module's tests one after another: each describe is a
# module of its own, so that they run at once.

defmodule MasuE2E.GridTest do
  use MasuE2E.Case, async: true, parameterize: MasuE2E.Case.projects()

  describe "a grid of a hundred thousand rows" do
    setup %{page: page} do
      open_page(page, "/")
      :ok
    end

    test "draws only the rows on the screen, with the count for a screen reader", %{page: page} do
      grid(page, "customers") |> Expect.to_have_attribute!("aria-rowcount", "100001")
      drawn = Page.locator(page, "#customers .masu-body .masu-row") |> Locator.count!()
      assert drawn > 10
      assert drawn < 60
      assert page |> row_text("customers", 0) |> Enum.take(2) == ["1", "Ken Torvalds"]
    end

    test "scrolls to any row, and asks the server for the rows it lacks", %{page: page} do
      grid(page, "customers") |> Locator.evaluate!("(el) => (el.scrollTop = el.scrollHeight)")
      assert Enum.at(row_text(page, "customers", 99_999), 0) == "100,000"

      grid(page, "customers") |> Locator.evaluate!("(el) => (el.scrollTop = 36 * 50_000)")
      assert Enum.at(row_text(page, "customers", 50_005), 0) == "50,006"
    end

    test "formats numbers, decimals, dates and booleans in the locale", %{page: page} do
      cells = row_text(page, "customers", 13)
      assert Enum.at(cells, 5) == "19"
      assert Enum.at(cells, 6) == "1,108.66"
      assert Enum.at(cells, 7) == "✓"
      assert Enum.at(cells, 8) =~ ~r/^\d{1,2} [A-Z][a-z]{2} \d{4}$/
    end

    test "a click on a header sorts, a second click turns the order, Shift adds a column", %{
      page: page
    } do
      revenue = header(page, "customers", "revenue")
      Locator.click!(revenue)
      Locator.click!(revenue)
      settled(page, "customers")
      revenue |> Expect.to_have_attribute!("aria-sort", "descending")
      assert Enum.at(row_text(page, "customers", 0), 6) == "9,999.49"

      header(page, "customers", "plan") |> Locator.click!()
      header(page, "customers", "seats") |> Locator.click!(modifiers: [:shift])
      settled(page, "customers")
      header(page, "customers", "plan") |> Expect.to_have_attribute!("aria-sort", "ascending")

      header(page, "customers", "seats")
      |> Locator.locator(".masu-sort")
      |> Expect.to_have_text!("2")

      [first, second] = [row_text(page, "customers", 0), row_text(page, "customers", 1)]
      assert [Enum.at(first, 4), Enum.at(second, 4)] == ["business", "business"]
      assert number(Enum.at(first, 5)) <= number(Enum.at(second, 5))
    end

    test "searches as the person types, and says how many rows it found", %{page: page} do
      Page.locator(page, "#customers .masu-search") |> Locator.fill!("kraków")
      grid(page, "customers") |> Expect.to_have_attribute!("aria-rowcount", "9413")
      Page.locator(page, "#customers .masu-status") |> Expect.to_have_text!("9,412 rows")
      assert Enum.at(row_text(page, "customers", 0), 3) == "Kraków"

      Page.locator(page, "#customers .masu-search") |> Locator.fill!("no such customer")
      Page.locator(page, "#customers .masu-empty") |> Expect.to_be_visible!()
      Page.locator(page, "#customers .masu-empty") |> Expect.to_have_text!("No rows")
    end

    test "the keyboard moves the active cell, which a screen reader follows", %{page: page} do
      keyboard = Page.keyboard(page)
      grid(page, "customers") |> Locator.focus!()
      Keyboard.press!(keyboard, "ArrowRight")
      Keyboard.press!(keyboard, "ArrowDown")

      grid(page, "customers")
      |> Expect.to_have_attribute!("aria-activedescendant", "customers-r1-c1")

      Page.locator(page, "#customers-r1-c1") |> Expect.to_have_class!(~r/masu-active/)

      Keyboard.press!(keyboard, "Control+End")

      grid(page, "customers")
      |> Expect.to_have_attribute!("aria-activedescendant", "customers-r99999-c9")

      Keyboard.press!(keyboard, "Control+Home")
      Keyboard.press!(keyboard, "ArrowUp")

      grid(page, "customers")
      |> Expect.to_have_attribute!("aria-activedescendant", "customers-h0")

      Keyboard.press!(keyboard, "Enter")
      settled(page, "customers")
      header(page, "customers", "id") |> Expect.to_have_attribute!("aria-sort", "ascending")
    end

    test "dragging the edge of a header resizes its column, a double click fits it", %{page: page} do
      mouse = Page.mouse(page)
      resizer = header(page, "customers", "name") |> Locator.locator(".masu-resizer")
      box = Locator.bounding_box!(resizer)
      Mouse.move!(mouse, box.x + 4, box.y + box.height / 2)
      Mouse.down!(mouse)
      Mouse.move!(mouse, box.x + 104, box.y + box.height / 2, steps: 4)
      Mouse.up!(mouse)

      cols = fn ->
        Page.locator(page, "#customers-content")
        |> Locator.evaluate!(~s|(el) => el.style.getPropertyValue("--masu-cols").split(" ")|)
      end

      assert Enum.at(cols.(), 1) == "290px"

      Locator.dblclick!(resizer)
      {fitted, _} = Integer.parse(Enum.at(cols.(), 1))
      assert fitted > 100
      assert fitted < 290
    end
  end

  test "a small grid takes the place of a plain table", %{page: page} do
    open_page(page, "/small")
    grid(page, "small") |> Expect.to_have_attribute!("aria-rowcount", "9")
    Page.locator(page, "#small .masu-body .masu-row") |> Expect.to_have_count!(8)
    assert row_text(page, "small", 7) == ["Anita Liskov", "anita.liskov8@example.com"]
  end

  test "an undo right after an edit waits for the edit's save", %{page: page} do
    # A slow network: the server's messages come half a second late.
    set_delay = slow_live_socket(page)
    open_page(page, "/")
    name = Page.locator(page, "#customers-r2-c1")
    Locator.click!(name)
    set_delay.(500)
    page |> Page.keyboard() |> Keyboard.type!("Grace")
    page |> Page.keyboard() |> Keyboard.press!("Tab")
    page |> Page.keyboard() |> Keyboard.press!("ControlOrMeta+z")
    name |> Expect.to_have_text!("Alan Matsumoto")
    page |> Page.keyboard() |> Keyboard.press!("ControlOrMeta+Shift+z")
    name |> Expect.to_have_text!("Grace")
  end

  test "two changes of a cell, the second before the first's save, both save", %{page: page} do
    set_delay = slow_live_socket(page)
    open_page(page, "/")
    active = Page.locator(page, "#customers-r0-c7")
    Locator.click!(active)
    set_delay.(500)
    page |> Page.keyboard() |> Keyboard.press!("Space")
    page |> Page.keyboard() |> Keyboard.press!("Space")
    # Both saves answered, half a second each: the cell is back as it was.
    Page.wait_for_timeout!(page, 2000)
    active |> Expect.to_have_text!("✓")
  end

  # Issho's pointers, by the symbols the grid sets on its element: a person's
  # pointer over a cell is that cell (its row's id and its column's key, and
  # where in it), which another page, in another order, finds where it is there.
  test "a pointer over a cell is the row and the column, found again in another order", %{
    page: page
  } do
    open_page(page, "/small")

    cell =
      page
      |> Page.locator(~s(#small .masu-body .masu-row[aria-rowindex="3"] .masu-cell))
      |> Locator.first()

    name = cell |> Locator.text_content!() |> String.trim()
    box = Locator.bounding_box!(cell)

    at =
      Page.locator(page, "#small")
      |> Locator.evaluate!(
        ~s|(el, [x, y]) => el[Symbol.for("issho.point")](x, y)|,
        [box.x + box.width / 4, box.y + box.height / 2]
      )

    assert Enum.at(at["cell"], 1) == "name"
    assert_close(at["x"], 0.25, 1)
    assert_close(at["y"], 0.5, 1)

    # In another order, the place is where that row is now.
    sort = header(page, "small", "name")
    Locator.click!(sort)
    Locator.click!(sort)
    settled(page, "small")

    now =
      page
      |> Page.locator("#small .masu-body .masu-row .masu-cell", has_text: name)
      |> Locator.first()

    there = Locator.bounding_box!(now)

    located =
      Page.locator(page, "#small")
      |> Locator.evaluate!(
        """
        (el, at) => {
          const rect = el[Symbol.for("issho.locator")](at);
          return rect && { x: rect.x, y: rect.y, width: rect.width };
        }
        """,
        at
      )

    assert located != :null
    assert abs(located["y"] - there.y) < 2
    assert abs(located["x"] - there.x) < 2
    # not.toBeCloseTo(box.y, 0)
    refute abs(there.y - box.y) < 0.5
  end

  # Jest's toBeCloseTo(expected, digits).
  defp assert_close(actual, expected, digits) do
    assert abs(actual - expected) < :math.pow(10, -digits) / 2
  end
end

# Chromium only, as only Chromium lets a test read or write the clipboard:
# a module of the Chromium project alone, so the other engines don't run it.
defmodule MasuE2E.GridChromiumTest do
  use MasuE2E.Case, async: true, parameterize: MasuE2E.Case.chromium_projects()

  describe "a grid of a hundred thousand rows" do
    setup %{page: page} do
      open_page(page, "/")
      :ok
    end

    test "Shift with the arrows selects a range, and copy gives tab-separated values",
         %{page: page, context: context} do
      BrowserContext.grant_permissions!(context, ["clipboard-read", "clipboard-write"])
      keyboard = Page.keyboard(page)
      grid(page, "customers") |> Locator.focus!()
      Keyboard.press!(keyboard, "ArrowRight")
      Keyboard.press!(keyboard, "Shift+ArrowRight")
      Keyboard.press!(keyboard, "Shift+ArrowDown")
      Page.locator(page, "#customers .masu-selected") |> Expect.to_have_count!(4)

      Keyboard.press!(keyboard, "ControlOrMeta+c")

      Expect.poll!(
        fn -> Page.evaluate!(page, "() => navigator.clipboard.readText()") end,
        &assert(
          &1 ==
            "Ken Torvalds\tken.torvalds1@example.com\nKatherine Hamilton\tkatherine.hamilton2@example.com"
        )
      )

      Page.locator(page, "#customers .masu-status") |> Expect.to_have_text!("2 rows copied")
    end
  end
end

defmodule MasuE2E.GridLiveRowsTest do
  use MasuE2E.Case, async: true, parameterize: MasuE2E.Case.projects()

  describe "live rows" do
    test "a row that changes on the topic flashes, and the person keeps their place", %{
      page: page
    } do
      open_page(page, "/live")
      grid(page, "quotes") |> Expect.to_have_attribute!("aria-rowcount", "2001")

      page
      |> Page.locator("#quotes .masu-changed")
      |> Locator.first()
      |> Expect.to_be_attached!(timeout: 10_000)

      grid(page, "quotes") |> Locator.evaluate!("(el) => (el.scrollTop = 36 * 600)")
      before = grid(page, "quotes") |> Locator.evaluate!("(el) => el.scrollTop")

      page
      |> Page.locator("#quotes .masu-changed")
      |> Locator.first()
      |> Expect.to_be_attached!(timeout: 10_000)

      assert grid(page, "quotes") |> Locator.evaluate!("(el) => el.scrollTop") == before
      grid(page, "quotes") |> Expect.to_have_attribute!("aria-rowcount", "2001")
    end

    test "a sorted grid stays sorted as the rows change", %{page: page} do
      open_page(page, "/live")
      price = header(page, "quotes", "price")
      Locator.click!(price)
      Locator.click!(price)
      settled(page, "quotes")

      page
      |> Page.locator("#quotes .masu-changed")
      |> Locator.first()
      |> Expect.to_be_attached!(timeout: 10_000)

      top =
        [0, 1, 2, 3, 4]
        |> Enum.map(fn i ->
          Playwright.Promise.async(fn ->
            page |> row_text("quotes", i) |> Enum.at(1) |> String.replace(",", "") |> number()
          end)
        end)
        |> Playwright.Promise.all()
        |> Playwright.Promise.await!()

      assert Enum.sort(top, :desc) == top
    end
  end
end

defmodule MasuE2E.GridFilterMenuTest do
  use MasuE2E.Case, async: true, parameterize: MasuE2E.Case.projects()

  describe "the filter menu" do
    setup %{page: page} do
      open_page(page, "/")
      :ok
    end

    test "an enum lists its values with their counts, and filters by the ones ticked", %{
      page: page
    } do
      header(page, "customers", "plan") |> Locator.hover!()

      header(page, "customers", "plan")
      |> Locator.locator(".masu-filter-button")
      |> Locator.click!()

      menu = Page.locator(page, "#customers .masu-menu")
      menu |> Expect.to_have_attribute!("role", "dialog")
      menu |> Locator.locator(".masu-menu-value") |> Expect.to_have_count!(5)

      menu
      |> Locator.locator(".masu-menu-value", has_text: "team")
      |> Locator.locator(".masu-menu-count")
      |> Expect.to_have_text!("20,000")

      menu |> Locator.locator(".masu-menu-value", has_text: "team") |> Locator.click!()
      menu |> Locator.locator(".masu-menu-value", has_text: "free") |> Locator.click!()
      menu |> Locator.locator(".masu-menu-apply") |> Locator.click!()
      settled(page, "customers")

      menu |> Expect.to_have_count!(0)
      grid(page, "customers") |> Expect.to_have_attribute!("aria-rowcount", "40001")

      Page.locator(page, "#customers .masu-chip-text")
      |> Expect.to_have_text!(["Plan is one of team, free"])
    end

    test "a number takes a range, and the chips take the filters away", %{page: page} do
      header(page, "customers", "seats") |> Locator.hover!()

      header(page, "customers", "seats")
      |> Locator.locator(".masu-filter-button")
      |> Locator.click!()

      Page.locator(page, "#customers .masu-menu-op") |> Locator.select_option!("between")
      Page.locator(page, "#customers .masu-menu-input") |> Locator.nth(0) |> Locator.fill!("10")
      Page.locator(page, "#customers .masu-menu-input") |> Locator.nth(1) |> Locator.fill!("20")

      Page.locator(page, "#customers .masu-menu-input")
      |> Locator.nth(1)
      |> Locator.press!("Enter")

      settled(page, "customers")

      Page.locator(page, "#customers .masu-chip-text")
      |> Expect.to_have_text!(["Seats between 10 and 20"])

      seats = page |> row_text("customers", 0) |> Enum.at(5) |> number()
      assert seats >= 10
      assert seats <= 20

      Page.locator(page, "#customers .masu-chip-remove") |> Locator.click!()
      settled(page, "customers")
      Page.locator(page, "#customers .masu-chip") |> Expect.to_have_count!(0)
      grid(page, "customers") |> Expect.to_have_attribute!("aria-rowcount", "100001")
    end

    test "Alt+↓ on a header opens its menu, Escape gives the focus back", %{page: page} do
      keyboard = Page.keyboard(page)
      grid(page, "customers") |> Locator.focus!()
      Keyboard.press!(keyboard, "ArrowUp")
      Keyboard.press!(keyboard, "ArrowRight")
      Keyboard.press!(keyboard, "ArrowRight")
      Keyboard.press!(keyboard, "ArrowRight")
      Keyboard.press!(keyboard, "Alt+ArrowDown")

      Page.locator(page, "#customers .masu-menu")
      |> Expect.to_have_attribute!("aria-label", "Filter City")

      Page.locator(page, "#customers .masu-menu-op") |> Expect.to_be_focused!()

      Page.locator(page, "#customers .masu-menu-op") |> Locator.select_option!("is_nil")
      Page.locator(page, "#customers .masu-menu-apply") |> Locator.press!("Enter")
      settled(page, "customers")
      Page.locator(page, "#customers .masu-chip-text") |> Expect.to_have_text!(["City is empty"])
      grid(page, "customers") |> Expect.to_have_attribute!("aria-rowcount", "5883")

      Keyboard.press!(keyboard, "Alt+ArrowDown")
      Keyboard.press!(keyboard, "Escape")
      Page.locator(page, "#customers .masu-menu") |> Expect.to_have_count!(0)
      grid(page, "customers") |> Expect.to_be_focused!()
    end
  end
end

defmodule MasuE2E.GridEditingTest do
  use MasuE2E.Case, async: true, parameterize: MasuE2E.Case.projects()

  describe "editing" do
    setup %{page: page} do
      open_page(page, "/")
      :ok
    end

    test "typing on a cell edits it, Enter saves and moves down", %{page: page} do
      cell(page, "customers", 0, 1) |> Locator.click!()
      page |> Page.keyboard() |> Keyboard.type!("Rui Freitas")
      Page.locator(page, "#customers .masu-editor") |> Expect.to_have_value!("Rui Freitas")
      page |> Page.keyboard() |> Keyboard.press!("Enter")

      cell(page, "customers", 0, 1) |> Expect.to_have_text!("Rui Freitas")
      Page.locator(page, "#customers .masu-editor") |> Expect.to_have_count!(0)

      grid(page, "customers")
      |> Expect.to_have_attribute!("aria-activedescendant", "customers-r1-c1")

      grid(page, "customers") |> Expect.to_be_focused!()
    end

    test "the changeset's error goes on the cell, with the old value", %{page: page} do
      cell(page, "customers", 1, 5) |> Locator.click!()
      page |> Page.keyboard() |> Keyboard.press!("Enter")
      Page.locator(page, "#customers .masu-editor") |> Locator.fill!("0")
      page |> Page.keyboard() |> Keyboard.press!("Enter")

      cell(page, "customers", 1, 5) |> Expect.to_have_attribute!("aria-invalid", "true")

      cell(page, "customers", 1, 5)
      |> Expect.to_have_attribute!("title", "must be greater than 0")

      cell(page, "customers", 1, 5) |> Expect.to_have_text!("75")

      Page.locator(page, "#customers .masu-status")
      |> Expect.to_have_text!("Seats: must be greater than 0")
    end

    test "Escape gives up, and undo and redo take an edit back and again", %{page: page} do
      keyboard = Page.keyboard(page)
      cell(page, "customers", 2, 1) |> Locator.dblclick!()
      Keyboard.type!(keyboard, " Jr")
      Keyboard.press!(keyboard, "Escape")
      cell(page, "customers", 2, 1) |> Expect.to_have_text!("Alan Matsumoto")

      cell(page, "customers", 2, 1) |> Locator.click!()
      Keyboard.type!(keyboard, "Grace")
      Keyboard.press!(keyboard, "Tab")
      cell(page, "customers", 2, 1) |> Expect.to_have_text!("Grace")

      grid(page, "customers")
      |> Expect.to_have_attribute!("aria-activedescendant", "customers-r2-c2")

      Keyboard.press!(keyboard, "ControlOrMeta+z")
      cell(page, "customers", 2, 1) |> Expect.to_have_text!("Alan Matsumoto")
      Keyboard.press!(keyboard, "ControlOrMeta+Shift+z")
      cell(page, "customers", 2, 1) |> Expect.to_have_text!("Grace")
    end

    test "Space turns a boolean, and Delete empties the cells of a range", %{page: page} do
      keyboard = Page.keyboard(page)
      cell(page, "customers", 0, 7) |> Locator.click!()
      Keyboard.press!(keyboard, "Space")
      cell(page, "customers", 0, 7) |> Expect.to_have_text!("")
      Keyboard.press!(keyboard, "Space")
      cell(page, "customers", 0, 7) |> Expect.to_have_text!("✓")

      cell(page, "customers", 0, 3) |> Locator.click!()
      Keyboard.press!(keyboard, "Shift+ArrowDown")
      Keyboard.press!(keyboard, "Delete")
      cell(page, "customers", 0, 3) |> Expect.to_have_text!("")
      cell(page, "customers", 1, 3) |> Expect.to_have_text!("")
    end

    test "Ctrl+D fills a range down with its first row", %{page: page} do
      cell(page, "customers", 5, 5) |> Locator.click!()
      page |> Page.keyboard() |> Keyboard.press!("Shift+ArrowDown")
      page |> Page.keyboard() |> Keyboard.press!("Shift+ArrowDown")
      page |> Page.keyboard() |> Keyboard.press!("ControlOrMeta+d")
      cell(page, "customers", 6, 5) |> Expect.to_have_text!("223")
      cell(page, "customers", 7, 5) |> Expect.to_have_text!("223")
    end

    test "a row or a cell that its state makes read-only does not edit", %{page: page} do
      # Row 4 (Radia) is on the enterprise plan: the whole row is read-only.
      cell(page, "customers", 3, 1) |> Expect.to_have_class!(~r/masu-locked/)
      cell(page, "customers", 3, 1) |> Locator.click!()
      page |> Page.keyboard() |> Keyboard.type!("X")
      Page.locator(page, "#customers .masu-editor") |> Expect.to_have_count!(0)
      cell(page, "customers", 3, 1) |> Expect.to_have_text!("Radia Berners-Lee")

      # Row 5 (Dennis) is not active: his revenue is read-only, his name is not.
      cell(page, "customers", 4, 6) |> Expect.to_have_attribute!("aria-readonly", "true")
      cell(page, "customers", 4, 1) |> Expect.to_have_attribute!("aria-readonly", "false")
      cell(page, "customers", 4, 6) |> Locator.dblclick!()
      Page.locator(page, "#customers .masu-editor") |> Expect.to_have_count!(0)
    end

    test "a column with editable={false} does not edit", %{page: page} do
      cell(page, "customers", 0, 0) |> Locator.click!()
      page |> Page.keyboard() |> Keyboard.type!("9")
      Page.locator(page, "#customers .masu-editor") |> Expect.to_have_count!(0)
      cell(page, "customers", 0, 0) |> Expect.to_have_text!("1")
    end
  end
end

# Chromium only, as only Chromium lets a test read or write the clipboard:
# a module of the Chromium project alone, so the other engines don't run it.
defmodule MasuE2E.GridEditingChromiumTest do
  use MasuE2E.Case, async: true, parameterize: MasuE2E.Case.chromium_projects()

  describe "editing" do
    setup %{page: page} do
      open_page(page, "/")
      :ok
    end

    test "a paste from a spreadsheet fills the cells from the active one",
         %{page: page, context: context} do
      BrowserContext.grant_permissions!(context, ["clipboard-read", "clipboard-write"])
      cell(page, "customers", 5, 3) |> Locator.click!()

      Page.evaluate!(
        page,
        ~s|() => navigator.clipboard.writeText("Porto\\tteam\\nFaro\\tnot a plan")|
      )

      page |> Page.keyboard() |> Keyboard.press!("ControlOrMeta+v")

      cell(page, "customers", 5, 3) |> Expect.to_have_text!("Porto")
      cell(page, "customers", 5, 4) |> Expect.to_have_text!("team")
      cell(page, "customers", 6, 4) |> Expect.to_have_attribute!("aria-invalid", "true")

      cell(page, "customers", 6, 3)
      |> Expect.to_have_attribute!("title", "Not saved: the row has an error.")

      cell(page, "customers", 6, 3) |> Expect.to_have_text!("Porto")
    end
  end
end

defmodule MasuE2E.GridTwoPeopleTest do
  use MasuE2E.Case, async: true, parameterize: MasuE2E.Case.projects()

  describe "two people" do
    # A shared grid lets its room go when it goes: on a navigation away its
    # LiveView is gone too, which is no error of the page.
    test "a shared grid that goes with its page, by a navigation, throws nothing", %{page: page} do
      errors = collector()
      Page.on(page, :page_error, &push(errors, Exception.message(&1)))
      room = room_name("leave")
      open_page(page, "/together?as=Ada&room=#{room}")
      Page.locator(page, "#together[data-issho-doc]") |> Expect.to_be_attached!()
      Page.evaluate!(page, ~s|() => window.liveSocket.js().navigate("/small")|)
      Expect.to_have_url!(page, ~r/\/small$/)
      Page.locator(page, "[data-phx-main].phx-connected") |> Expect.to_be_visible!()
      Page.wait_for_timeout!(page, 300)
      assert items(errors) == []
    end

    # Without presence, nothing stops Ada from editing the cell Alan types
    # in: the server's compare-and-swap is what refuses his stale edit.
    test "an edit shows in the other browser, and an edit of a cell changed meanwhile is refused",
         ctx do
      room = room_name("conflict")
      ada = ctx.browser |> Browser.new_context!(locale: "en-GB") |> BrowserContext.new_page!()
      alan = ctx.browser |> Browser.new_context!(locale: "en-GB") |> BrowserContext.new_page!()
      open_page(ada, "/together?as=Ada&room=#{room}&presence=0")
      open_page(alan, "/together?as=Alan&room=#{room}&presence=0")
      cell = fn page, row, col -> Page.locator(page, "#together-r#{row}-c#{col}") end

      # Alan starts to type in Ken's name; Ada saves it first.
      cell.(alan, 0, 1) |> Locator.click!()
      alan |> Page.keyboard() |> Keyboard.type!("Alan's Ken")
      cell.(ada, 0, 1) |> Locator.click!()
      ada |> Page.keyboard() |> Keyboard.type!("Ada's Ken")
      ada |> Page.keyboard() |> Keyboard.press!("Enter")
      cell.(ada, 0, 1) |> Expect.to_have_text!("Ada's Ken")

      alan |> Page.keyboard() |> Keyboard.press!("Enter")
      cell.(alan, 0, 1) |> Expect.to_have_attribute!("title", "Changed by Ada meanwhile.")
      cell.(alan, 0, 1) |> Expect.to_have_text!("Ada's Ken")

      # A cell of the same row that no one else changed is saved, and shows
      # in Ada's browser.
      cell.(alan, 0, 2) |> Locator.click!()
      alan |> Page.keyboard() |> Keyboard.type!("Faro")
      alan |> Page.keyboard() |> Keyboard.press!("Enter")
      cell.(ada, 0, 2) |> Expect.to_have_text!("Faro")
      cell.(ada, 0, 1) |> Expect.to_have_text!("Ada's Ken")

      ada |> Page.context() |> BrowserContext.close!()
      alan |> Page.context() |> BrowserContext.close!()
    end
  end
end

defmodule MasuE2E.GridPresenceTest do
  use MasuE2E.Case, async: true, parameterize: MasuE2E.Case.projects()

  defp two_people(ctx, prefix, alan_params \\ "") do
    room = room_name(prefix)

    open = fn name, params ->
      page = ctx.browser |> Browser.new_context!(locale: "en-GB") |> BrowserContext.new_page!()
      open_page(page, "/together?as=#{name}&room=#{room}&rows=300#{params}")
      page
    end

    %{ada: open.("Ada", ""), alan: open.("Alan", alan_params)}
  end

  defp scroll_top(page), do: grid(page, "together") |> Locator.evaluate!("(el) => el.scrollTop")

  describe "presence" do
    test "each person sees the others, where they are, what they type, and what they save", ctx do
      room = room_name("presence")

      open = fn name ->
        page = ctx.browser |> Browser.new_context!(locale: "en-GB") |> BrowserContext.new_page!()
        open_page(page, "/together?as=#{name}&room=#{room}")
        page
      end

      ada = open.("Ada")
      alan = open.("Alan")

      Page.locator(ada, "#together .masu-person") |> Expect.to_have_attribute!("title", "Alan")
      Page.locator(alan, "#together .masu-person") |> Expect.to_have_attribute!("title", "Ada")

      Page.locator(alan, "#together-r2-c1") |> Locator.click!()
      Page.locator(ada, "#together .masu-peer .masu-peer-label") |> Expect.to_have_text!("Alan")

      # To the next cell, the same mark glides there, rather than one drawn anew.
      y =
        Page.locator(ada, "#together .masu-peer")
        |> Locator.evaluate!("(el) => { el.dataset.seen = \"1\"; return Number(el.dataset.y); }")

      alan |> Page.keyboard() |> Keyboard.press!("ArrowDown")

      Expect.poll!(
        fn ->
          Page.locator(ada, "#together .masu-peer")
          |> Locator.evaluate!("(el) => Number(el.dataset.y)")
        end,
        &assert(&1 > y)
      )

      Page.locator(ada, ~s(#together .masu-peer[data-seen="1"])) |> Expect.to_have_count!(1)
      alan |> Page.keyboard() |> Keyboard.press!("ArrowUp")

      alan |> Page.keyboard() |> Keyboard.type!("Al")

      Page.locator(ada, "#together .masu-peer-editing .masu-peer-label")
      |> Expect.to_have_text!("Alan is typing")

      Page.locator(ada, "#together-r2-c1") |> Locator.dblclick!()
      Page.locator(ada, "#together .masu-editor") |> Expect.to_have_count!(0)

      Page.locator(ada, "#together .masu-status")
      |> Expect.to_have_text!("Alan is editing this cell")

      alan |> Page.keyboard() |> Keyboard.press!("Enter")

      color =
        Page.locator(ada, "#together .masu-person")
        |> Locator.evaluate!(~s|(el) => el.style.getPropertyValue("--masu-peer-color")|)

      flashed = Page.locator(ada, "#together .masu-changed")
      flashed |> Locator.first() |> Expect.to_be_attached!()

      assert flashed
             |> Locator.first()
             |> Locator.evaluate!(~s|(el) => el.style.getPropertyValue("--masu-flash")|) ==
               color

      alan |> Page.context() |> BrowserContext.close!()
      Page.locator(ada, "#together .masu-person") |> Expect.to_have_count!(0)
      ada |> Page.context() |> BrowserContext.close!()
    end

    test "a click on an avatar shows that person's view and place; Stop brings back one's own",
         ctx do
      %{ada: ada, alan: alan} = two_people(ctx, "follow")

      # Ada reads a little way down, in her own order.
      Page.locator(ada, "#together-r0-c1") |> Locator.click!()
      ada |> Page.keyboard() |> Keyboard.press!("PageDown")
      ada |> Page.keyboard() |> Keyboard.press!("PageDown")
      ada_top = scroll_top(ada)
      assert ada_top > 0

      # Alan turns the order and reads further down.
      header(alan, "together", "id") |> Locator.click!()
      header(alan, "together", "id") |> Locator.click!()
      settled(alan, "together")
      Page.locator(alan, "#together-r0-c1") |> Locator.click!()
      for _ <- 1..5, do: alan |> Page.keyboard() |> Keyboard.press!("PageDown")

      avatar = Page.locator(ada, "#together .masu-person")
      Locator.click!(avatar)
      avatar |> Expect.to_have_attribute!("aria-pressed", "true")
      Page.locator(ada, "#together .masu-following") |> Expect.to_contain_text!("Following Alan")
      # Following is the room's (Issho's): the page says whom, for every block of the room.
      followed = fn ->
        Page.evaluate!(
          ada,
          ~s|() => Object.values(JSON.parse(document.documentElement.dataset.isshoFollowing ?? "{}"))|
        )
      end

      Expect.poll!(followed, &assert(length(&1) == 1))
      header(ada, "together", "id") |> Expect.to_have_attribute!("aria-sort", "descending")
      Expect.poll!(fn -> abs(scroll_top(ada) - scroll_top(alan)) end, &assert(&1 < 40))
      Page.locator(ada, "#together .masu-peer .masu-peer-label") |> Expect.to_have_text!("Alan")

      # Alan moves on; Ada's grid goes with him.
      alan |> Page.keyboard() |> Keyboard.press!("Control+Home")
      Expect.poll!(fn -> scroll_top(ada) end, &assert(&1 == 0))

      Page.locator(ada, "#together .masu-following-stop") |> Locator.click!()
      Page.locator(ada, "#together .masu-following") |> Expect.to_have_count!(0)
      header(ada, "together", "id") |> Expect.to_have_attribute!("aria-sort", "none")
      Expect.poll!(fn -> scroll_top(ada) end, &assert(&1 == ada_top))
      avatar |> Expect.to_have_attribute!("aria-pressed", "false")
      Expect.poll!(followed, &assert(&1 == []))

      ada |> Page.context() |> BrowserContext.close!()
      alan |> Page.context() |> BrowserContext.close!()
    end

    test "scrolling while following keeps that person's view, with a way back", ctx do
      %{ada: ada, alan: alan} = two_people(ctx, "takeover")
      Page.locator(alan, ".masu-search") |> Locator.fill!("an")
      settled(alan, "together")
      Page.locator(alan, "#together-r0-c1") |> Locator.click!()

      Page.locator(ada, "#together .masu-person") |> Locator.click!()
      Page.locator(ada, ".masu-search") |> Expect.to_have_value!("an")

      grid(ada, "together") |> Locator.hover!()
      ada |> Page.mouse() |> Mouse.wheel!(0, 300)
      Page.locator(ada, "#together .masu-following") |> Expect.to_contain_text!("Alan's view")
      Page.locator(ada, ".masu-search") |> Expect.to_have_value!("an")

      Page.locator(ada, "#together .masu-person")
      |> Expect.to_have_attribute!("aria-pressed", "false")

      Page.get_by_role(ada, :button, name: "Back to your view") |> Locator.click!()
      Page.locator(ada, ".masu-search") |> Expect.to_have_value!("")
      Page.locator(ada, "#together .masu-following") |> Expect.to_have_count!(0)

      ada |> Page.context() |> BrowserContext.close!()
      alan |> Page.context() |> BrowserContext.close!()
    end

    test "a person whose grid keeps its view is followed in one's own order", ctx do
      %{ada: ada, alan: alan} = two_people(ctx, "private", "&share=0")

      # Alan turns the order: his first row is the last of Ada's.
      header(alan, "together", "id") |> Locator.click!()
      header(alan, "together", "id") |> Locator.click!()
      settled(alan, "together")
      Page.locator(alan, "#together-r0-c1") |> Locator.click!()

      Page.locator(ada, "#together .masu-person") |> Locator.click!()
      Page.locator(ada, "#together .masu-following") |> Expect.to_contain_text!("Following Alan")
      header(ada, "together", "id") |> Expect.to_have_attribute!("aria-sort", "none")
      Page.locator(ada, "#together-r299-c1") |> Expect.to_be_in_viewport!()

      alan |> Page.keyboard() |> Keyboard.press!("Control+End")
      Page.locator(ada, "#together-r0-c5") |> Expect.to_be_in_viewport!()

      ada |> Page.context() |> BrowserContext.close!()
      alan |> Page.context() |> BrowserContext.close!()
    end

    test "each person sees the range the others selected", ctx do
      room = room_name("range")

      open = fn name ->
        page = ctx.browser |> Browser.new_context!(locale: "en-GB") |> BrowserContext.new_page!()
        open_page(page, "/together?as=#{name}&room=#{room}")
        page
      end

      ada = open.("Ada")
      alan = open.("Alan")

      Page.locator(alan, "#together-r1-c1") |> Locator.click!()
      alan |> Page.keyboard() |> Keyboard.press!("Shift+ArrowDown")
      alan |> Page.keyboard() |> Keyboard.press!("Shift+ArrowDown")
      alan |> Page.keyboard() |> Keyboard.press!("Shift+ArrowRight")
      Page.locator(ada, "#together .masu-peer-range") |> Expect.to_have_count!(3)

      alan |> Page.keyboard() |> Keyboard.press!("ArrowUp")
      Page.locator(ada, "#together .masu-peer-range") |> Expect.to_have_count!(0)

      ada |> Page.context() |> BrowserContext.close!()
      alan |> Page.context() |> BrowserContext.close!()
    end
  end
end

defmodule MasuE2E.GridLayoutTest do
  use MasuE2E.Case, async: true, parameterize: MasuE2E.Case.projects()

  defp person(name), do: room_name(name)

  defp headers(page),
    do: Page.locator(page, "#views .masu-hcell .masu-label") |> Locator.all_text_contents!()

  describe "layout and views" do
    test "pinned columns stay in place while the others scroll sideways", %{page: page} do
      Page.set_viewport_size!(page, %{width: 900, height: 760})
      open_page(page, "/views?as=#{person("ada")}")
      id = Page.locator(page, "#views-r0-c0")
      city = Page.locator(page, "#views-r0-c2")
      revenue = Page.locator(page, ~s(#views .masu-hcell[data-key="revenue"]))
      before = Locator.bounding_box!(id).x
      city_before = Locator.bounding_box!(city).x
      grid_box = grid(page, "views") |> Locator.bounding_box!()

      grid(page, "views") |> Locator.evaluate!("(el) => (el.scrollLeft = 300)")
      Expect.poll!(fn -> Locator.bounding_box!(city).x end, &assert(&1 < city_before - 200))
      assert Locator.bounding_box!(id).x == before
      end_box = Locator.bounding_box!(revenue)
      assert abs(end_box.x + end_box.width - (grid_box.x + grid_box.width)) < 4
      id |> Expect.to_have_class!(~r/masu-pinned-start/)
    end

    test "a selected cell of a pinned column shows the selection on every second row too", %{
      page: page
    } do
      open_page(page, "/views?as=#{person("ada")}")
      odd = Page.locator(page, "#views-r0-c0")
      even = Page.locator(page, "#views-r1-c0")
      Locator.click!(odd)
      page |> Page.keyboard() |> Keyboard.press!("Shift+ArrowDown")
      even |> Expect.to_have_class!(~r/masu-selected/)
      page |> Page.mouse() |> Mouse.move!(0, 0)

      image = fn cell ->
        Locator.evaluate!(cell, "(el) => getComputedStyle(el).backgroundImage")
      end

      assert image.(even) == image.(odd)
    end

    test "a drag on a header moves its column, and Alt+Shift+→ on a header too", %{page: page} do
      open_page(page, "/views?as=#{person("ada")}")

      plan =
        Page.locator(page, ~s(#views .masu-hcell[data-key="plan"] .masu-label))
        |> Locator.bounding_box!()

      city = header(page, "views", "city") |> Locator.bounding_box!()
      mouse = Page.mouse(page)
      Mouse.move!(mouse, plan.x + 5, plan.y + 5)
      Mouse.down!(mouse)
      Mouse.move!(mouse, city.x + 10, city.y + 10, steps: 6)
      Page.locator(page, "#views .masu-drop") |> Expect.to_be_visible!()
      Mouse.up!(mouse)

      Expect.poll!(
        fn -> headers(page) end,
        &assert(
          &1 == [
            "ID",
            "Name",
            "Plan",
            "City",
            "Seats",
            "Active",
            "Signed up",
            "Last seen",
            "Revenue"
          ]
        )
      )

      assert ["1", "Ken Torvalds"] -- row_text(page, "views", 0) == []
      # The drag did not sort.
      header(page, "views", "plan") |> Expect.to_have_attribute!("aria-sort", "none")

      Page.locator(page, "#views-r0-c2") |> Locator.click!()
      page |> Page.keyboard() |> Keyboard.press!("ArrowUp")
      page |> Page.keyboard() |> Keyboard.press!("Alt+Shift+ArrowRight")

      Expect.poll!(
        fn -> headers(page) end,
        &assert(
          &1 == [
            "ID",
            "Name",
            "City",
            "Plan",
            "Seats",
            "Active",
            "Signed up",
            "Last seen",
            "Revenue"
          ]
        )
      )

      Page.locator(page, "#views .masu-status") |> Expect.to_have_text!("Plan moved")
    end

    test "the columns menu hides, shows, pins and moves columns", %{page: page} do
      open_page(page, "/views?as=#{person("ada")}")
      Page.get_by_role(page, :button, name: "Columns") |> Locator.click!()
      menu = Page.get_by_role(page, :dialog, name: "Columns")

      menu |> Locator.get_by_role(:checkbox, name: "Seats") |> Locator.uncheck!()
      menu |> Locator.get_by_role(:checkbox, name: "Email") |> Locator.check!()

      Expect.poll!(
        fn -> headers(page) end,
        &assert(
          &1 == [
            "ID",
            "Name",
            "Email",
            "City",
            "Plan",
            "Active",
            "Signed up",
            "Last seen",
            "Revenue"
          ]
        )
      )

      menu |> Locator.get_by_role(:combobox, name: "Pin City") |> Locator.select_option!("start")
      header(page, "views", "city") |> Expect.to_have_class!(~r/masu-pinned-start/)

      Expect.poll!(
        fn -> headers(page) end,
        &assert(
          &1 == [
            "ID",
            "Name",
            "City",
            "Email",
            "Plan",
            "Active",
            "Signed up",
            "Last seen",
            "Revenue"
          ]
        )
      )

      menu |> Locator.get_by_role(:button, name: "Move Active up") |> Locator.click!()

      Expect.poll!(
        fn -> headers(page) end,
        &assert(
          &1 == [
            "ID",
            "Name",
            "City",
            "Email",
            "Active",
            "Plan",
            "Signed up",
            "Last seen",
            "Revenue"
          ]
        )
      )

      # The focus stays on the button, for the next move.
      menu |> Locator.get_by_role(:button, name: "Move Active up") |> Expect.to_be_focused!()

      page |> Page.keyboard() |> Keyboard.press!("Escape")
      menu |> Expect.to_have_count!(0)
      Page.get_by_role(page, :button, name: "Columns") |> Expect.to_be_focused!()
    end

    test "a filter on a column that the person hides keeps its chip", %{page: page} do
      open_page(page, "/views?as=#{person("ada")}")
      header(page, "views", "plan") |> Locator.locator(".masu-filter-button") |> Locator.click!()
      Page.get_by_role(page, :checkbox, name: ~r/^team/) |> Locator.check!()
      Page.locator(page, "#views .masu-menu-apply") |> Locator.click!()
      settled(page, "views")
      chip = Page.locator(page, "#views .masu-chip:not(.masu-chip-group) .masu-chip-text")
      chip |> Expect.to_have_text!("Plan is one of team")

      Page.get_by_role(page, :button, name: "Columns") |> Locator.click!()
      Page.get_by_role(page, :checkbox, name: "Plan") |> Locator.uncheck!()
      Expect.poll!(fn -> headers(page) end, &refute("Plan" in &1))
      chip |> Expect.to_have_text!("Plan is one of team")
      chip |> Expect.to_be_disabled!()
    end

    test "the view goes into the URL, and the link opens it in another browser",
         %{page: page} = ctx do
      open_page(page, "/views?as=#{person("ada")}")
      Page.locator(page, ".masu-search") |> Locator.fill!("Oslo")
      # The search applies after a pause in the typing.
      grid(page, "views") |> Expect.not_() |> Expect.to_have_attribute!("aria-rowcount", "10001")
      settled(page, "views")
      header(page, "views", "revenue") |> Locator.click!()
      header(page, "views", "revenue") |> Locator.click!()
      Page.get_by_role(page, :button, name: "Columns") |> Locator.click!()
      Page.get_by_role(page, :checkbox, name: "Seats") |> Locator.uncheck!()
      Expect.to_have_url!(page, ~r/views\[hide\]=email%2Cseats/)
      Expect.to_have_url!(page, ~r/views\[sort\]=-revenue/)

      other = ctx.browser |> Browser.new_context!(locale: "en-GB") |> BrowserContext.new_page!()

      open_page(
        other,
        Regex.replace(~r/as=[^&]+/, Page.url(page), "as=#{person("alan")}", global: false)
      )

      Expect.poll!(
        fn -> headers(other) end,
        &assert(
          &1 == ["ID", "Name", "City", "Plan", "Active", "Signed up", "Last seen", "Revenue"]
        )
      )

      header(other, "views", "revenue") |> Expect.to_have_attribute!("aria-sort", "descending")
      Page.locator(other, ".masu-search") |> Expect.to_have_value!("Oslo")
      assert row_text(other, "views", 0) == row_text(page, "views", 0)
      other |> Page.context() |> BrowserContext.close!()
    end

    test "a saved view comes back, and a shared one is in the others' views menu",
         %{page: page} = ctx do
      ada = person("ada")
      open_page(page, "/views?as=#{ada}")
      header(page, "views", "seats") |> Locator.click!()
      Page.get_by_role(page, :button, name: "Columns") |> Locator.click!()
      Page.get_by_role(page, :checkbox, name: "City") |> Locator.uncheck!()
      page |> Page.keyboard() |> Keyboard.press!("Escape")

      name =
        "Seats #{Base.encode32(:crypto.strong_rand_bytes(3), case: :lower, padding: false) |> String.slice(0, 4)}"

      Page.get_by_role(page, :button, name: "Views") |> Locator.click!()
      Page.get_by_placeholder(page, "Name this view") |> Locator.fill!(name)
      Page.get_by_role(page, :checkbox, name: "Share with everyone") |> Locator.check!()
      Page.get_by_role(page, :button, name: "Save view") |> Locator.click!()

      Page.get_by_role(page, :dialog, name: "Views")
      |> Locator.get_by_role(:status)
      |> Expect.to_have_text!("View saved")

      Page.locator(page, ".masu-views-button") |> Expect.to_contain_text!(name)

      # The last view of the person comes back, without the URL.
      open_page(page, "/views?as=#{ada}")
      Expect.poll!(fn -> headers(page) end, &refute("City" in &1))
      header(page, "views", "seats") |> Expect.to_have_attribute!("aria-sort", "ascending")

      alan = ctx.browser |> Browser.new_context!(locale: "en-GB") |> BrowserContext.new_page!()
      open_page(alan, "/views?as=#{person("alan")}")
      Expect.poll!(fn -> headers(alan) end, &assert("City" in &1))
      Page.get_by_role(alan, :button, name: "Views") |> Locator.click!()
      Page.get_by_role(alan, :button, name: name, exact: true) |> Locator.click!()
      Expect.poll!(fn -> headers(alan) end, &refute("City" in &1))
      header(alan, "views", "seats") |> Expect.to_have_attribute!("aria-sort", "ascending")
      Page.get_by_role(alan, :button, name: "Delete #{name}") |> Expect.to_have_count!(0)

      Page.get_by_role(alan, :button, name: "The grid's own view") |> Locator.click!()
      Expect.poll!(fn -> headers(alan) end, &assert("City" in &1))
      alan |> Page.context() |> BrowserContext.close!()
    end
  end
end

defmodule MasuE2E.GridTreesTest do
  use MasuE2E.Case, async: true, parameterize: MasuE2E.Case.projects()

  defp row(page, index),
    do: Page.locator(page, ~s(#files .masu-body .masu-row[aria-rowindex="#{index + 2}"]))

  describe "trees" do
    test "→ opens a row, ← closes it or goes to its parent, and * opens a level", %{page: page} do
      keyboard = Page.keyboard(page)
      open_page(page, "/tree")
      Page.locator(page, "#files-grid") |> Expect.to_have_attribute!("role", "treegrid")
      Page.locator(page, "#files-grid") |> Expect.to_have_attribute!("aria-rowcount", "201")
      row(page, 0) |> Expect.to_have_attribute!("aria-level", "1")
      row(page, 0) |> Expect.to_have_attribute!("aria-expanded", "false")
      row(page, 0) |> Expect.to_have_attribute!("aria-setsize", "200")

      Page.locator(page, "#files-r0-c0") |> Locator.click!()
      Keyboard.press!(keyboard, "ArrowRight")
      row(page, 0) |> Expect.to_have_attribute!("aria-expanded", "true")
      Page.locator(page, "#files-r1-c0") |> Expect.to_have_text!("Part 1")
      row(page, 1) |> Expect.to_have_attribute!("aria-level", "2")

      Keyboard.press!(keyboard, "ArrowDown")
      Keyboard.press!(keyboard, "ArrowRight")
      Page.locator(page, "#files-r2-c0") |> Expect.to_have_text!("File 1.txt")
      row(page, 2) |> Expect.not_() |> Expect.to_have_attribute!("aria-expanded")

      # ← on a file goes to its folder, then closes it.
      Keyboard.press!(keyboard, "ArrowDown")
      Keyboard.press!(keyboard, "ArrowLeft")

      Page.locator(page, "#files-grid")
      |> Expect.to_have_attribute!("aria-activedescendant", "files-r1-c0")

      Keyboard.press!(keyboard, "ArrowLeft")
      Page.locator(page, "#files-r2-c0") |> Expect.to_have_text!("Part 2")

      # The arrow closes the project; * opens every project.
      Page.locator(page, "#files-r0-c0 .masu-twisty") |> Locator.click!()
      Page.locator(page, "#files-grid") |> Expect.to_have_attribute!("aria-rowcount", "201")
      Keyboard.press!(keyboard, "*")
      Page.locator(page, "#files-grid") |> Expect.to_have_attribute!("aria-rowcount", "2201")
      Page.locator(page, "#files-r11-c0") |> Expect.to_have_text!("Project 2")
    end

    test "a search keeps the rows that match and their folders, and a deep tree scrolls", %{
      page: page
    } do
      open_page(page, "/tree")
      Page.locator(page, ".masu-search") |> Locator.fill!("Part 10")
      settled(page, "files")
      Page.locator(page, "#files-grid") |> Expect.to_have_attribute!("aria-rowcount", "401")
      Page.locator(page, "#files-r0-c0") |> Expect.to_have_text!("Project 1")
      Page.locator(page, "#files-r1-c0") |> Expect.to_have_text!("Part 10")
      # The project is open on what matches; the part has none of its files.
      row(page, 0) |> Expect.to_have_attribute!("aria-expanded", "true")
      row(page, 1) |> Expect.not_() |> Expect.to_have_attribute!("aria-expanded")

      Page.locator(page, ".masu-search") |> Locator.fill!("")
      Page.locator(page, "#files-grid") |> Expect.to_have_attribute!("aria-rowcount", "201")
      Page.locator(page, "#files-r0-c0") |> Locator.click!()
      page |> Page.keyboard() |> Keyboard.press!("Shift+*")
      Page.locator(page, "#files-grid") |> Expect.to_have_attribute!("aria-rowcount", "2201")
      page |> Page.keyboard() |> Keyboard.press!("Control+End")
      Page.locator(page, "#files-r2199-c0") |> Expect.to_have_text!("Part 10")
    end
  end
end

defmodule MasuE2E.GridDetailsTest do
  use MasuE2E.Case, async: true, parameterize: MasuE2E.Case.projects()

  describe "details" do
    test "Alt+→ opens a row's detail under it, Alt+↓ goes into it, Escape comes back", %{
      page: page
    } do
      keyboard = Page.keyboard(page)
      open_page(page, "/details")
      below = Page.locator(page, "#orders-r2-c0")
      before = Locator.bounding_box!(below).y

      Page.locator(page, "#orders-r1-c1") |> Locator.click!()
      Keyboard.press!(keyboard, "Alt+ArrowRight")
      detail = Page.locator(page, "#orders .masu-detail")
      detail |> Expect.to_be_visible!()
      detail |> Expect.to_contain_text!("Alan Matsumoto ordered 5 lines.")
      Page.locator(page, "#orders > .masu-status") |> Expect.to_have_text!("Details shown")

      # The rows under it move down by its height.
      box = Locator.bounding_box!(detail)

      Expect.poll!(
        fn -> Locator.bounding_box!(below).y end,
        &assert(&1 > before + box.height - 2)
      )

      assert abs(box.y - before) < 2

      Keyboard.press!(keyboard, "Alt+ArrowDown")
      Page.locator(page, "#lines-2-grid") |> Expect.to_be_focused!()
      Keyboard.press!(keyboard, "ArrowDown")
      Keyboard.press!(keyboard, "ArrowDown")

      Page.locator(page, "#lines-2-grid")
      |> Expect.to_have_attribute!("aria-activedescendant", "lines-2-r2-c0")

      # The outer grid did not move.
      Page.locator(page, "#orders-grid")
      |> Expect.to_have_attribute!("aria-activedescendant", "orders-r1-c1")

      Keyboard.press!(keyboard, "Escape")
      Page.locator(page, "#orders-grid") |> Expect.to_be_focused!()
      Keyboard.press!(keyboard, "Alt+ArrowLeft")
      detail |> Expect.to_have_count!(0)
      Expect.poll!(fn -> Locator.bounding_box!(below).y end, &assert(&1 == before))
    end

    test "a detail stays under its row as the grid scrolls and sorts", %{page: page} do
      open_page(page, "/details")
      Page.locator(page, "#orders-r0-c0 .masu-detail-toggle") |> Locator.click!()
      detail = Page.locator(page, "#orders .masu-detail")
      detail |> Expect.to_contain_text!("Katherine Hamilton ordered")

      header(page, "orders", "number") |> Locator.click!()
      header(page, "orders", "number") |> Locator.click!()
      settled(page, "orders")
      # SO-10001 is last now: the detail goes with it.
      Page.locator(page, "#orders-r0-c0") |> Locator.click!()
      grid(page, "orders") |> Locator.evaluate!("(el) => (el.scrollTop = el.scrollHeight)")
      Page.locator(page, "#orders-r1999-c0") |> Expect.to_contain_text!("SO-10001")
      detail |> Expect.to_be_in_viewport!()
      row_box = Page.locator(page, "#orders-r1999-c0") |> Locator.bounding_box!()
      box = Locator.bounding_box!(detail)
      assert abs(box.y - (row_box.y + row_box.height)) < 3
    end
  end
end

defmodule MasuE2E.GridGroupsTest do
  use MasuE2E.Case, async: true, parameterize: MasuE2E.Case.projects()

  defp row(page, index),
    do: Page.locator(page, ~s(#groups .masu-body .masu-row[aria-rowindex="#{index + 2}"]))

  describe "groups" do
    test "groups open on their groups and their rows, with their counts and totals", %{page: page} do
      keyboard = Page.keyboard(page)
      open_page(page, "/groups")
      Page.locator(page, "#groups-grid") |> Expect.to_have_attribute!("role", "treegrid")

      Page.locator(page, "#groups-r0-c0 .masu-group-label")
      |> Expect.to_have_text!("Plan: business")

      Page.locator(page, "#groups-r0-c0 .masu-group-count") |> Expect.to_have_text!("20,000")
      row(page, 0) |> Expect.to_have_class!(~r/masu-group-row/)
      row(page, 0) |> Expect.to_have_attribute!("aria-expanded", "false")
      Page.locator(page, "#groups-r0-c3") |> Expect.to_have_text!("2,490,000")

      # The totals of every row, at the bottom.
      totals = Page.locator(page, "#groups .masu-totals")
      totals |> Locator.locator(".masu-cell") |> Locator.first() |> Expect.to_have_text!("Total")

      totals
      |> Locator.locator(".masu-cell")
      |> Locator.nth(3)
      |> Expect.to_have_text!("12,550,000")

      Page.locator(page, "#groups-r0-c0") |> Locator.click!()
      Keyboard.press!(keyboard, "ArrowRight")
      Page.locator(page, "#groups-r1-c0 .masu-group-label") |> Expect.to_have_text!(~r/^City: /)
      row(page, 1) |> Expect.to_have_attribute!("aria-level", "2")
      Keyboard.press!(keyboard, "ArrowDown")
      Keyboard.press!(keyboard, "ArrowRight")
      row(page, 2) |> Expect.to_have_attribute!("aria-level", "3")
      row(page, 2) |> Expect.not_() |> Expect.to_have_class!(~r/masu-group-row/)
      Page.locator(page, "#groups-r2-c1") |> Expect.to_have_text!("business")

      # ← on the group's row closes it.
      Keyboard.press!(keyboard, "ArrowUp")
      Keyboard.press!(keyboard, "ArrowLeft")
      row(page, 2) |> Expect.to_have_class!(~r/masu-group-row/)
    end

    test "the header menu groups by a column, a chip stops it, and a total sorts the groups", %{
      page: page
    } do
      open_page(page, "/groups")

      Page.locator(page, "#groups .masu-chip-group")
      |> Expect.to_have_text!(["Grouped by Plan", "Grouped by City"])

      Page.get_by_role(page, :button, name: "Stop grouping by Plan") |> Locator.click!()
      Page.locator(page, "#groups-r0-c0 .masu-group-label") |> Expect.to_have_text!(~r/^City: /)

      header(page, "groups", "active")
      |> Locator.locator(".masu-filter-button")
      |> Locator.click!()

      Page.get_by_role(page, :button, name: "Group by Active") |> Locator.click!()

      Page.locator(page, "#groups .masu-chip-group")
      |> Expect.to_have_text!(["Grouped by City", "Grouped by Active"])

      Page.get_by_role(page, :button, name: "Stop grouping by City") |> Locator.click!()
      Page.locator(page, "#groups-r0-c0 .masu-group-label") |> Expect.to_have_text!(~r/^Active: /)
      Page.locator(page, "#groups .masu-body .masu-group-row") |> Expect.to_have_count!(2)

      Page.get_by_role(page, :button, name: "Stop grouping by Active") |> Locator.click!()
      Page.locator(page, "#groups-r0-c0") |> Locator.click!()
      page |> Page.keyboard() |> Keyboard.press!("ArrowUp")
      # Grouped by plan again, sorted by the groups' revenue.
      header(page, "groups", "plan") |> Locator.locator(".masu-filter-button") |> Locator.click!()
      Page.get_by_role(page, :button, name: "Group by Plan") |> Locator.click!()
      header(page, "groups", "revenue") |> Locator.click!()
      settled(page, "groups")
      ascending = Page.locator(page, "#groups-r0-c0 .masu-group-label") |> Locator.text_content!()
      header(page, "groups", "revenue") |> Locator.click!()
      settled(page, "groups")

      Page.locator(page, "#groups-r0-c0 .masu-group-label")
      |> Expect.not_()
      |> Expect.to_have_text!(ascending)
    end

    test "with no more groups, no first cell keeps a group's indent", %{page: page} do
      keyboard = Page.keyboard(page)
      open_page(page, "/groups")
      Page.locator(page, "#groups-r0-c0") |> Locator.click!()
      Keyboard.press!(keyboard, "ArrowRight")
      row(page, 1) |> Expect.to_have_attribute!("aria-level", "2")
      Keyboard.press!(keyboard, "ArrowDown")
      Keyboard.press!(keyboard, "ArrowRight")
      row(page, 2) |> Expect.to_have_attribute!("aria-level", "3")

      Page.get_by_role(page, :button, name: "Stop grouping by Plan") |> Locator.click!()
      Page.get_by_role(page, :button, name: "Stop grouping by City") |> Locator.click!()
      Page.locator(page, "#groups-grid") |> Expect.to_have_attribute!("role", "grid")
      settled(page, "groups")
      Page.locator(page, "#groups .masu-body .masu-tree-cell") |> Expect.to_have_count!(0)

      indents =
        Page.locator(page, "#groups .masu-body .masu-row > .masu-cell:first-child")
        |> Locator.evaluate_all!(
          "(cells) => new Set(cells.map((cell) => getComputedStyle(cell).paddingInlineStart)).size"
        )

      assert indents == 1
    end
  end
end

defmodule MasuE2E.GridSelectionTest do
  use MasuE2E.Case, async: true, parameterize: MasuE2E.Case.projects()

  alias Playwright.Download

  defp person, do: room_name("sel")
  defp box(page, row), do: Page.locator(page, "#views-r#{row}-c0 .masu-select")

  describe "selection and export" do
    test "boxes select rows, Shift a range, Space and Ctrl too; the header's box every row of the query",
         %{page: page} do
      open_page(page, "/views?as=#{person()}")
      bar = Page.locator(page, "#views .masu-selection-bar")
      all = Page.locator(page, "#views .masu-select-all")

      box(page, 1) |> Locator.click!()
      box(page, 4) |> Locator.click!(modifiers: [:shift])
      bar |> Expect.to_contain_text!("4 selected")
      box(page, 2) |> Expect.to_be_checked!()
      Page.locator(page, "#views .masu-body .masu-row-chosen") |> Expect.to_have_count!(4)
      all |> Expect.to_have_js_property!("indeterminate", true)

      # Space on the first column, and Ctrl and a click, take a row out.
      Page.locator(page, "#views-r2-c1") |> Locator.click!()
      page |> Page.keyboard() |> Keyboard.press!("ArrowLeft")
      page |> Page.keyboard() |> Keyboard.press!("Space")
      box(page, 2) |> Expect.not_() |> Expect.to_be_checked!()
      Page.locator(page, "#views-r3-c2") |> Locator.click!(modifiers: [:control_or_meta])
      bar |> Expect.to_contain_text!("2 selected")

      # Every row of the query: a search, then the header's box.
      Page.locator(page, ".masu-search") |> Locator.fill!("Oslo")
      grid(page, "views") |> Expect.not_() |> Expect.to_have_attribute!("aria-rowcount", "10001")
      Locator.click!(all)
      bar |> Expect.to_contain_text!(~r/^All [\d,]+ selected/)
      all |> Expect.to_be_checked!()
      box(page, 0) |> Expect.to_be_checked!()
      box(page, 0) |> Locator.click!()
      bar |> Expect.not_() |> Expect.to_contain_text!("All")

      bar |> Locator.get_by_role(:button, name: "Clear") |> Locator.click!()
      bar |> Expect.to_have_count!(0)
      box(page, 1) |> Expect.not_() |> Expect.to_be_checked!()
    end

    test "the Export menu downloads the rows of the query, as CSV and as XLSX", %{page: page} do
      open_page(page, "/views?as=#{person()}")
      Page.locator(page, ".masu-search") |> Locator.fill!("Oslo")
      # The search applies after a pause in the typing.
      grid(page, "views") |> Expect.not_() |> Expect.to_have_attribute!("aria-rowcount", "10001")

      count =
        (grid(page, "views") |> Locator.get_attribute!("aria-rowcount") |> String.to_integer()) -
          1

      csv = Page.wait_for_event(page, :download)
      Page.get_by_role(page, :button, name: "Export") |> Locator.click!()

      Page.get_by_role(page, :dialog, name: "Export")
      |> Locator.get_by_role(:button, name: "CSV")
      |> Locator.click!()

      file = Playwright.Promise.await!(csv)
      assert Download.suggested_filename(file) =~ ~r/^views-\d{4}-\d{2}-\d{2}\.csv$/
      text = File.read!(Download.path!(file))
      lines = text |> String.trim() |> String.split("\r\n")
      assert hd(lines) == "ID,Name,City,Plan,Seats,Active,Signed up,Last seen,Revenue"
      assert length(lines) == count + 1
      # The search's rows (it reads every text column).
      assert lines |> tl() |> Enum.all?(&String.contains?(&1, "Oslo"))

      Page.locator(page, "#views > .masu-status")
      |> Expect.to_have_text!("The export is downloading")

      Page.get_by_role(page, :button, name: "Export")
      |> Expect.not_()
      |> Expect.to_have_attribute!("aria-busy")

      xlsx = Page.wait_for_event(page, :download)
      Page.get_by_role(page, :button, name: "Export") |> Locator.click!()
      Page.get_by_role(page, :button, name: "Excel (XLSX)") |> Locator.click!()
      workbook = Playwright.Promise.await!(xlsx)
      assert Download.suggested_filename(workbook) =~ ~r/\.xlsx$/
      bytes = File.read!(Download.path!(workbook))
      # A zip: "PK" first.
      assert binary_part(bytes, 0, 2) == "PK"
    end
  end
end

defmodule MasuE2E.GridNewRowsTest do
  use MasuE2E.Case, async: true, parameterize: MasuE2E.Case.projects()

  describe "new and deleted rows, and editors" do
    setup %{page: page} do
      open_page(page, "/tasks")
      :ok
    end

    test "a new row is a draft until the person leaves it; its errors stay on its cells", %{
      page: page
    } do
      keyboard = Page.keyboard(page)
      grid(page, "tasks") |> Expect.to_have_attribute!("aria-rowcount", "32")
      grid(page, "tasks") |> Locator.evaluate!("(el) => (el.scrollTop = el.scrollHeight)")
      cell(page, "tasks", 30, 0) |> Expect.to_have_text!("+ New row")

      grid(page, "tasks") |> Locator.focus!()
      Keyboard.press!(keyboard, "Control+Enter")
      status(page, "tasks") |> Expect.to_have_text!("New row")
      Page.locator(page, "#tasks .masu-draft") |> Expect.to_have_count!(1)
      Keyboard.type!(keyboard, "Write the guide")
      Keyboard.press!(keyboard, "Enter")
      # Enter goes to the row below: "+ New row". The draft saves.
      status(page, "tasks") |> Expect.to_have_text!("Row added")
      Page.locator(page, "#tasks .masu-draft") |> Expect.to_have_count!(0)
      grid(page, "tasks") |> Expect.to_have_attribute!("aria-rowcount", "33")
      cell(page, "tasks", 30, 0) |> Expect.to_have_text!("Write the guide")
      cell(page, "tasks", 30, 1) |> Expect.to_have_text!("todo")

      # A draft with no title: refused, it stays, with the error on its cell.
      cell(page, "tasks", 31, 0) |> Locator.click!()
      Page.locator(page, "#tasks .masu-draft") |> Expect.to_have_count!(1)
      Keyboard.press!(keyboard, "ArrowRight")
      Keyboard.press!(keyboard, "ArrowRight")
      Keyboard.type!(keyboard, "2")
      Keyboard.press!(keyboard, "Enter")
      status(page, "tasks") |> Expect.to_have_text!("Title: can't be blank")
      Page.locator(page, "#tasks .masu-draft .masu-invalid") |> Expect.to_have_count!(1)
      grid(page, "tasks") |> Expect.to_have_attribute!("aria-rowcount", "34")

      # Escape lets it go.
      Keyboard.press!(keyboard, "ArrowUp")
      Keyboard.press!(keyboard, "Escape")
      status(page, "tasks") |> Expect.to_have_text!("New row discarded")
      Page.locator(page, "#tasks .masu-draft") |> Expect.to_have_count!(0)
      grid(page, "tasks") |> Expect.to_have_attribute!("aria-rowcount", "33")
    end

    test "Ctrl+Delete deletes rows after a question, Ctrl+Z brings them back, and the bar deletes those selected",
         %{page: page} do
      keyboard = Page.keyboard(page)
      cell(page, "tasks", 0, 0) |> Locator.click!()
      Keyboard.press!(keyboard, "Shift+ArrowDown")
      Keyboard.press!(keyboard, "Control+Delete")
      question = Page.get_by_role(page, :alertdialog)
      question |> Expect.to_contain_text!("Delete 2 rows?")
      question |> Locator.get_by_role(:button, name: "Delete") |> Expect.to_be_focused!()
      Keyboard.press!(keyboard, "Escape")
      question |> Expect.to_have_count!(0)
      grid(page, "tasks") |> Expect.to_be_focused!()

      Keyboard.press!(keyboard, "Control+Delete")

      Page.get_by_role(page, :alertdialog)
      |> Locator.get_by_role(:button, name: "Delete")
      |> Locator.click!()

      status(page, "tasks") |> Expect.to_have_text!("2 rows deleted")
      cell(page, "tasks", 0, 0) |> Expect.to_have_text!("Task 3")

      Keyboard.press!(keyboard, "Control+z")
      status(page, "tasks") |> Expect.to_have_text!("2 rows brought back")
      cell(page, "tasks", 0, 0) |> Expect.to_have_text!("Task 1")
      cell(page, "tasks", 1, 0) |> Expect.to_have_text!("Task 2")

      # A row that is done does not delete (deletable); the others do.
      Page.locator(page, "#tasks-r2-c0 .masu-select") |> Locator.click!()
      Page.locator(page, "#tasks-r3-c0 .masu-select") |> Locator.click!()
      bar = Page.locator(page, "#tasks .masu-selection-bar")
      bar |> Locator.get_by_role(:button, name: "Delete") |> Locator.click!()

      Page.get_by_role(page, :alertdialog)
      |> Locator.get_by_role(:button, name: "Delete")
      |> Locator.click!()

      status(page, "tasks") |> Expect.to_have_text!("Row deleted This row cannot be deleted.")
      cell(page, "tasks", 2, 0) |> Expect.to_have_text!("Task 3")
      cell(page, "tasks", 3, 0) |> Expect.to_have_text!("Task 5")
    end

    test "an enum edits with its values, a number with one decimal, and a value the server would refuse stays in the editor",
         %{page: page} do
      keyboard = Page.keyboard(page)
      cell(page, "tasks", 0, 2) |> Expect.to_have_text!("3.5")
      cell(page, "tasks", 3, 2) |> Expect.to_have_text!("1.0")

      cell(page, "tasks", 0, 1) |> Locator.click!()
      Keyboard.type!(keyboard, "re")
      Page.locator(page, "#tasks .masu-choice") |> Expect.to_have_text!(["review"])
      Keyboard.press!(keyboard, "Enter")
      cell(page, "tasks", 0, 1) |> Expect.to_have_text!("review")

      Keyboard.press!(keyboard, "ArrowUp")
      Keyboard.press!(keyboard, "F2")

      Page.locator(page, "#tasks .masu-choice")
      |> Expect.to_have_text!(["todo", "doing", "review", "done"])

      Page.locator(page, "#tasks .masu-choice[aria-selected=true]")
      |> Expect.to_have_text!("review")

      Keyboard.press!(keyboard, "ArrowDown")
      Keyboard.press!(keyboard, "Enter")
      cell(page, "tasks", 0, 1) |> Expect.to_have_text!("done")

      cell(page, "tasks", 0, 2) |> Locator.click!()
      Keyboard.type!(keyboard, "lots")
      Keyboard.press!(keyboard, "Enter")
      status(page, "tasks") |> Expect.to_have_text!("Estimate: Not a number")

      Page.locator(page, "#tasks .masu-editor")
      |> Expect.to_have_attribute!("aria-invalid", "true")

      Keyboard.press!(keyboard, "Escape")
      cell(page, "tasks", 0, 2) |> Expect.to_have_text!("3.5")
    end
  end
end

# Chromium only, as only Chromium lets a test read or write the clipboard:
# a module of the Chromium project alone, so the other engines don't run it.
defmodule MasuE2E.GridNewRowsChromiumTest do
  use MasuE2E.Case, async: true, parameterize: MasuE2E.Case.chromium_projects()

  describe "new and deleted rows, and editors" do
    setup %{page: page} do
      open_page(page, "/tasks")
      :ok
    end

    test "a paste past the last row adds the rest as new rows, and shows the one refused",
         %{page: page, context: context} do
      BrowserContext.grant_permissions!(context, ["clipboard-read", "clipboard-write"])
      grid(page, "tasks") |> Locator.evaluate!("(el) => (el.scrollTop = el.scrollHeight)")
      cell(page, "tasks", 29, 0) |> Locator.click!()

      Page.evaluate!(
        page,
        ~s|() => navigator.clipboard.writeText("Alpha\\ttodo\\nBeta\\tdoing\\n\\tdone")|
      )

      page |> Page.keyboard() |> Keyboard.press!("ControlOrMeta+v")
      question = Page.get_by_role(page, :alertdialog)
      question |> Expect.to_contain_text!("Add 2 new rows for the rest of the paste?")
      question |> Locator.get_by_role(:button, name: "Add rows") |> Locator.click!()
      status(page, "tasks") |> Expect.to_have_text!("Title: can't be blank")
      cell(page, "tasks", 29, 0) |> Expect.to_have_text!("Alpha")
      cell(page, "tasks", 30, 0) |> Expect.to_have_text!("Beta")
      Page.locator(page, "#tasks .masu-draft") |> Expect.to_have_count!(1)
      grid(page, "tasks") |> Expect.to_have_attribute!("aria-activedescendant", "tasks-r31-c0")
    end
  end
end

defmodule MasuE2E.GridPagesTest do
  use MasuE2E.Case, async: true, parameterize: MasuE2E.Case.projects()

  alias Playwright.WebSocket

  describe "rows without a count, and pages" do
    setup %{page: page} do
      open_page(page, "/pages")
      :ok
    end

    test "a source that does not count: the grid scrolls over the rows it read, and grows", %{
      page: page
    } do
      engine = grid(page, "engine")
      engine |> Expect.to_have_attribute!("aria-rowcount", "-1")

      height = fn ->
        Page.locator(page, "#engine .masu-body")
        |> Locator.evaluate!("(el) => parseFloat(el.style.height)")
      end

      # The rows read (a block, read ahead), and a block more.
      Expect.poll!(height, &assert(&1 == 36 * 200))

      Locator.evaluate!(engine, "(el) => (el.scrollTop = el.scrollHeight)")
      Expect.poll!(height, &assert(&1 > 36 * 200))

      Page.locator(page, ~s(#engine .masu-row[aria-rowindex="201"]))
      |> Expect.to_contain_text!("200")

      engine |> Expect.to_have_attribute!("aria-rowcount", "-1")
    end

    test "a grid of pages: the pager goes from page to page, and the page goes into the URL", %{
      page: page
    } do
      pager = Page.locator(page, "#report .masu-pager")
      pager |> Locator.locator(".masu-pager-range") |> Expect.to_have_text!("1–25 of 100,000")
      pager |> Locator.get_by_role(:button, name: "Previous") |> Expect.to_be_disabled!()
      # The page's rows, and no more: its last is the 25th.
      grid(page, "report") |> Locator.evaluate!("(el) => (el.scrollTop = el.scrollHeight)")

      Page.locator(page, ~s(#report .masu-row[aria-rowindex="26"]))
      |> Expect.to_contain_text!("25")

      Page.locator(page, ~s(#report .masu-row[aria-rowindex="27"])) |> Expect.to_have_count!(0)

      pager |> Locator.get_by_role(:button, name: "Next") |> Locator.click!()
      pager |> Locator.locator(".masu-pager-range") |> Expect.to_have_text!("26–50 of 100,000")
      Expect.to_have_url!(page, ~r/report%5Bpage%5D=2|report\[page\]=2/)

      Page.locator(page, ~s(#report .masu-row[aria-rowindex="27"]))
      |> Expect.to_contain_text!("26")

      grid(page, "report") |> Expect.to_have_js_property!("scrollTop", 0)

      pager |> Locator.get_by_label("Page") |> Locator.fill!("4000")
      pager |> Locator.get_by_label("Page") |> Locator.press!("Enter")

      pager
      |> Locator.locator(".masu-pager-range")
      |> Expect.to_have_text!("99,976–100,000 of 100,000")

      pager |> Locator.get_by_role(:button, name: "Next") |> Expect.to_be_disabled!()

      # The keys stay on the page: ↑ from its first row goes to the header.
      page
      |> Page.locator(~s(#report .masu-row[aria-rowindex="99977"] .masu-cell))
      |> Locator.first()
      |> Locator.click!()

      page |> Page.keyboard() |> Keyboard.press!("ArrowUp")
      grid(page, "report") |> Expect.to_have_attribute!("aria-activedescendant", "report-h0")

      Page.reload!(page)

      Page.locator(page, "#report .masu-pager-range")
      |> Expect.to_have_text!("99,976–100,000 of 100,000")
    end

    test "a page is one read of the source, and the next page is not read ahead", %{page: page} do
      reads = collector()

      Page.on(page, :web_socket, fn ws ->
        WebSocket.on(ws, :frame_sent, fn %{payload: payload} ->
          text = if is_binary(payload), do: payload, else: inspect(payload)
          # The report's reads: blocks of its page size, 25.
          if text =~ ~s("masu:rows") and text =~ ~s("count":25), do: push(reads, text)
        end)
      end)

      Page.reload!(page)
      Page.locator(page, "#report .masu-pager-range") |> Expect.to_have_text!("1–25 of 100,000")
      # The first page came with the grid: nothing to read.
      Page.wait_for_timeout!(page, 300)
      assert items(reads) == []

      Page.locator(page, "#report .masu-pager")
      |> Locator.get_by_role(:button, name: "Next")
      |> Locator.click!()

      Page.locator(page, ~s(#report .masu-row[aria-rowindex="27"]))
      |> Expect.to_contain_text!("26")

      Page.wait_for_timeout!(page, 300)
      assert length(items(reads)) == 1
      assert hd(items(reads)) =~ ~s("from":25)
    end

    test "in a grid of pages, a new row goes on the last page", %{page: page} do
      range = Page.locator(page, "#notes .masu-pager-range")
      range |> Expect.to_have_text!("1–5 of 12")
      Page.locator(page, "#notes-r0-c0") |> Locator.click!()
      page |> Page.keyboard() |> Keyboard.press!("Control+Enter")
      range |> Expect.to_have_text!("11–12 of 12")
      Page.locator(page, "#notes .masu-draft") |> Expect.to_have_count!(1)
      page |> Page.keyboard() |> Keyboard.type!("Thirteen")
      page |> Page.keyboard() |> Keyboard.press!("Enter")
      Page.locator(page, "#notes > .masu-status") |> Expect.to_have_text!("Row added")
      range |> Expect.to_have_text!("11–13 of 13")
      Page.locator(page, "#notes-r12-c0") |> Expect.to_have_text!("Thirteen")
    end
  end
end

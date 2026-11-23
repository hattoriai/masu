defmodule MasuE2E.MenusTest do
  use MasuE2E.Case, async: true, parameterize: MasuE2E.Case.projects()

  # Menus of the app's own (Masu.Action), on the Menus page: the menu of a
  # cell, with the grid's items and the app's, and the app's items in a
  # header menu. Its columns: name, city, plan, revenue, active.

  setup %{page: page} do
    open_page(page, "/menus")
    :ok
  end

  test "a right click opens a cell's menu, whose items filter and sort by the cell", %{page: page} do
    [_, city, plan | _] = row_text(page, "menus", 0)

    cell(page, "menus", 0, 2) |> Locator.click!(button: :right)
    menu(page, "menus") |> Expect.to_have_attribute!("aria-label", "Plan: actions")

    menu(page, "menus")
    |> Locator.get_by_role(:menuitem)
    |> Expect.to_have_text!([
      "Copy",
      "Copy with headers",
      "Filter by #{plan}",
      "Exclude #{plan}",
      "Filter by empty",
      "Filter by not empty",
      "Sort ascending",
      "Sort descending",
      "Open",
      "Mark"
    ])

    menu(page, "menus") |> Locator.get_by_role(:separator) |> Expect.to_have_count!(3)
    item(page, "menus", "Filter by #{plan}") |> Locator.click!()
    settled(page, "menus")
    menu(page, "menus") |> Expect.to_have_count!(0)

    Page.locator(page, "#menus .masu-chip-text")
    |> Expect.to_have_text!(["Plan is one of #{plan}"])

    cell(page, "menus", 0, 1) |> Locator.click!(button: :right)
    item(page, "menus", "Exclude #{city}") |> Locator.click!()
    settled(page, "menus")

    Page.locator(page, "#menus .masu-chip-text")
    |> Expect.to_have_text!(["Plan is one of #{plan}", "City is not #{city}"])

    assert Enum.at(row_text(page, "menus", 0), 1) != city

    cell(page, "menus", 0, 3) |> Locator.click!(button: :right)
    item(page, "menus", "Sort descending") |> Locator.click!()
    settled(page, "menus")
    header(page, "menus", "revenue") |> Expect.to_have_attribute!("aria-sort", "descending")
    first = page |> row_text("menus", 0) |> Enum.at(3) |> String.replace(",", "") |> number()
    second = page |> row_text("menus", 1) |> Enum.at(3) |> String.replace(",", "") |> number()
    assert first >= second
  end

  test "Shift+F10 opens the menu of the active cell: the arrows move, Escape gives the focus back",
       %{page: page} do
    keyboard = Page.keyboard(page)
    cell(page, "menus", 2, 0) |> Locator.click!()
    Keyboard.press!(keyboard, "Shift+F10")
    menu(page, "menus") |> Expect.to_be_visible!()
    item(page, "menus", "Copy") |> Expect.to_be_focused!()

    Keyboard.press!(keyboard, "ArrowDown")
    item(page, "menus", "Copy with headers") |> Expect.to_be_focused!()
    Keyboard.press!(keyboard, "End")
    item(page, "menus", "Card") |> Expect.to_be_focused!()
    Keyboard.press!(keyboard, "ArrowDown")
    item(page, "menus", "Copy") |> Expect.to_be_focused!()
    Keyboard.press!(keyboard, "s")
    item(page, "menus", "Sort ascending") |> Expect.to_be_focused!()

    Keyboard.press!(keyboard, "Escape")
    menu(page, "menus") |> Expect.to_have_count!(0)
    grid(page, "menus") |> Expect.to_be_focused!()
    grid(page, "menus") |> Expect.to_have_attribute!("aria-activedescendant", "menus-r2-c0")

    # Enter runs the item, and the focus comes back too.
    Keyboard.press!(keyboard, "Shift+F10")
    Keyboard.press!(keyboard, "End")
    Keyboard.press!(keyboard, "ArrowUp")
    Keyboard.press!(keyboard, "ArrowUp")
    item(page, "menus", "Open") |> Expect.to_be_focused!()
    Keyboard.press!(keyboard, "Enter")
    [name | _] = row_text(page, "menus", 2)
    Page.locator(page, "#said") |> Expect.to_have_text!("Opened #{name}")
    grid(page, "menus") |> Expect.to_be_focused!()
  end

  test "the app's items: a JS command, with the cell in the event before it, and a panel the server renders",
       %{page: page} do
    [name | _] = row_text(page, "menus", 1)

    heard =
      Playwright.Promise.async(fn ->
        Page.evaluate!(page, """
        () =>
          new Promise((resolve) =>
            document.getElementById("menus").addEventListener("masu:action", (event) => resolve(event.detail), { once: true }),
          )
        """)
      end)

    cell(page, "menus", 1, 0) |> Locator.click!(button: :right)
    item(page, "menus", "Mark") |> Locator.click!()
    Page.locator(page, "#js-mark") |> Expect.to_have_attribute!("data-marked", "yes")

    assert Playwright.Promise.await!(heard) == %{
             "grid" => "menus",
             "kind" => "cell",
             "action" => "Mark",
             "column" => "name",
             "id" => 2,
             "value" => name
           }

    cell(page, "menus", 1, 0) |> Locator.click!(button: :right)
    item(page, "menus", "Card") |> Locator.click!()
    panel = Page.locator(page, "#menus-action-panel")
    panel |> Expect.to_be_visible!()
    panel |> Expect.to_have_attribute!("role", "dialog")
    panel |> Locator.locator("#card strong") |> Expect.to_have_text!(name)
    panel |> Expect.to_be_focused!()
    # Under the cell.
    cell_box = cell(page, "menus", 1, 0) |> Locator.bounding_box!()
    panel_box = Locator.bounding_box!(panel)
    assert abs(panel_box.y - (cell_box.y + cell_box.height + 4)) < 2

    page |> Page.keyboard() |> Keyboard.press!("Escape")
    panel |> Expect.to_have_count!(0)
    grid(page, "menus") |> Expect.to_be_focused!()
  end

  test "a header menu has the app's items for the column, and a panel goes under its header", %{
    page: page
  } do
    header(page, "menus", "name") |> Locator.hover!()
    header(page, "menus", "name") |> Locator.locator(".masu-filter-button") |> Locator.click!()
    dialog = Page.locator(page, ~s(#menus .masu-menu[role="dialog"]))

    dialog
    |> Locator.locator(".masu-menu-item")
    |> Expect.to_have_text!(["Sort ascending", "Sort descending", "Explain"])

    dialog |> Locator.locator(".masu-menu-item", has_text: "Explain") |> Locator.click!()
    Page.locator(page, "#said") |> Expect.to_have_text!("About name")
    dialog |> Expect.to_have_count!(0)

    # A right click on a header opens its menu too.
    header(page, "menus", "revenue") |> Locator.click!(button: :right)

    dialog
    |> Locator.locator(".masu-menu-item")
    |> Expect.to_have_text!(["Sort ascending", "Sort descending", "Explain", "Column stats"])

    dialog |> Locator.locator(".masu-menu-item", has_text: "Column stats") |> Locator.click!()
    panel = Page.locator(page, "#menus-action-panel")

    panel
    |> Locator.locator("#stats dt")
    |> Expect.to_have_text!(["Lowest", "Highest", "Average"])

    header_box = header(page, "menus", "revenue") |> Locator.bounding_box!()
    panel_box = Locator.bounding_box!(panel)
    assert abs(panel_box.y - (header_box.y + header_box.height + 4)) < 2

    # A click away closes it.
    Page.locator(page, "#menus-label") |> Locator.click!()
    panel |> Expect.to_have_count!(0)
  end

  test "a grid with no menu of its cells leaves the browser's own", %{page: page} do
    open_page(page, "/small")

    prevented =
      Playwright.Promise.async(fn ->
        Page.evaluate!(page, """
        () =>
          new Promise((resolve) =>
            document.addEventListener("contextmenu", (event) => resolve(event.defaultPrevented), { once: true }),
          )
        """)
      end)

    Page.locator(page, "#small-r0-c0") |> Locator.click!(button: :right)
    assert Playwright.Promise.await!(prevented) == false
    Page.locator(page, ~s(#small [role="menu"])) |> Expect.to_have_count!(0)
  end

  test "in a short box that cuts its overflow, a menu and a panel float above the page, whole", %{
    page: page
  } do
    # The grid in a box as short as Lotus Web's results, which hides what
    # overflows it.
    Page.locator(page, "#menus")
    |> Locator.evaluate!("""
    (el) => {
      const box = document.createElement("div");
      Object.assign(box.style, { height: "140px", overflow: "hidden" });
      el.replaceWith(box);
      box.appendChild(el);
      el.style.height = "100%";
    }
    """)

    whole = fn selector ->
      shown =
        Page.locator(page, selector)
        |> Locator.evaluate!("""
        (el) => {
          const r = el.getBoundingClientRect();
          const x = Math.min(Math.max(r.left + 8, 0), innerWidth - 1);
          // The element is what the page shows at its corners: no box clips it.
          const at = (y) => el.contains(document.elementFromPoint(x, y));
          return {
            open: el.matches(":popover-open"),
            inside: r.top >= 0 && r.bottom <= innerHeight,
            top: at(r.top + 4),
            bottom: at(r.bottom - 4),
          };
        }
        """)

      assert shown == %{"open" => true, "inside" => true, "top" => true, "bottom" => true}
    end

    header(page, "menus", "name") |> Locator.hover!()
    header(page, "menus", "name") |> Locator.locator(".masu-filter-button") |> Locator.click!()
    whole.(~s(#menus .masu-menu[role="dialog"]))
    page |> Page.keyboard() |> Keyboard.press!("Escape")

    header(page, "menus", "revenue") |> Locator.click!(button: :right)

    Page.locator(page, ~s(#menus .masu-menu[role="dialog"] .masu-menu-item),
      has_text: "Column stats"
    )
    |> Locator.click!()

    Page.locator(page, "#stats dt") |> Expect.to_have_text!(["Lowest", "Highest", "Average"])
    whole.("#menus-action-panel")
  end

  test "a cell of numbers filters by its value as a bound, and one of text by a part", %{
    page: page
  } do
    [name, _, _, revenue | _] = row_text(page, "menus", 0)

    cell(page, "menus", 0, 3) |> Locator.click!(button: :right)

    menu(page, "menus")
    |> Locator.get_by_role(:menuitem)
    |> Expect.to_contain_text!([
      "Filter by #{revenue}",
      "Exclude #{revenue}",
      "Greater than #{revenue}",
      "Less than #{revenue}",
      "At least #{revenue}",
      "At most #{revenue}",
      "Filter by empty"
    ])

    item(page, "menus", "At least #{revenue}") |> Locator.click!()
    settled(page, "menus")

    Page.locator(page, "#menus .masu-chip-text")
    |> Expect.to_have_text!(["Revenue at least #{revenue}"])

    bound = revenue |> String.replace(",", "") |> number()

    for row <- 0..2 do
      text = Enum.at(row_text(page, "menus", row), 3)
      if text != nil, do: assert(text |> String.replace(",", "") |> number() >= bound)
    end

    cell(page, "menus", 0, 0) |> Locator.click!(button: :right)
    item(page, "menus", "Greater than #{name}") |> Expect.to_have_count!(0)
    [first | _] = row_text(page, "menus", 0)
    item(page, "menus", "Contains #{first}") |> Locator.click!()
    settled(page, "menus")

    Page.locator(page, "#menus .masu-chip-text")
    |> Expect.to_contain_text!(["Name contains #{first}"])
  end

  test "a cell's menu is as tall as its items, whatever height the app's styles give popovers", %{
    page: page
  } do
    height = fn ->
      cell(page, "menus", 0, 2) |> Locator.click!(button: :right)
      menu(page, "menus") |> Expect.to_be_visible!()
      box = menu(page, "menus") |> Locator.bounding_box!()
      page |> Page.keyboard() |> Keyboard.press!("Escape")
      menu(page, "menus") |> Expect.to_have_count!(0)
      box.height
    end

    own = height.()
    Page.add_style_tag!(page, content: "[popover] { height: 100%; }")
    assert height.() == own
  end
end

# Chromium only, as only Chromium lets a test read or write the clipboard:
# a module of the Chromium project alone, so the other engines don't run it.
defmodule MasuE2E.MenusChromiumTest do
  use MasuE2E.Case, async: true, parameterize: MasuE2E.Case.chromium_projects()

  setup %{page: page} do
    open_page(page, "/menus")
    :ok
  end

  test "Copy with headers copies the cell, or the range it is in, with the columns' labels",
       %{page: page, context: context} do
    BrowserContext.grant_permissions!(context, ["clipboard-read", "clipboard-write"])
    rows = [row_text(page, "menus", 0), row_text(page, "menus", 1)]
    [[a0, a1 | _], [b0, b1 | _]] = rows

    cell(page, "menus", 0, 0) |> Locator.click!()
    cell(page, "menus", 1, 1) |> Locator.click!(modifiers: [:shift])
    cell(page, "menus", 1, 0) |> Locator.click!(button: :right)
    item(page, "menus", "Copy with headers") |> Locator.click!()

    Expect.poll!(
      fn -> Page.evaluate!(page, "() => navigator.clipboard.readText()") end,
      &assert(&1 == "Name\tCity\n#{a0}\t#{a1}\n#{b0}\t#{b1}")
    )

    # A right click out of the range: the cell alone.
    cell(page, "menus", 3, 2) |> Locator.click!(button: :right)
    item(page, "menus", "Copy") |> Locator.click!()
    expected = page |> row_text("menus", 3) |> Enum.at(2)

    Expect.poll!(
      fn -> Page.evaluate!(page, "() => navigator.clipboard.readText()") end,
      &assert(&1 == expected)
    )
  end
end

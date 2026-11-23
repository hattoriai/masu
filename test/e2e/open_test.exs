defmodule MasuE2E.OpenTest do
  use MasuE2E.Case, async: true, parameterize: MasuE2E.Case.projects()

  # Rows that open (`on_row_activate`), on the Open a row page: a click on a
  # row, or Enter on it, patches the URL to the row, and the page shows it
  # in a panel. Its columns: name, city (read-only), seats (edits), and a
  # link.

  defp cell(row, col), do: "#open-r#{row}-c#{col}"

  setup %{page: page} do
    open_page(page, "/open")
    :ok
  end

  test "a click on a row opens it", %{page: page} do
    [name | _] = row_text(page, "open", 2)
    Page.locator(page, cell(2, 1)) |> Locator.click!()
    Expect.to_have_url!(page, ~r/\/open\?open=\d+$/)
    Page.locator(page, "#opened") |> Expect.to_have_text!("Opened #{name}")
    # The grid keeps the focus, on the cell clicked.
    grid(page, "open") |> Expect.to_be_focused!()
    grid(page, "open") |> Expect.to_have_attribute!("aria-activedescendant", "open-r2-c1")
  end

  test "Enter on a row's active cell opens it", %{page: page} do
    [name | _] = row_text(page, "open", 1)
    grid(page, "open") |> Locator.focus!()
    page |> Page.keyboard() |> Keyboard.press!("ArrowDown")
    page |> Page.keyboard() |> Keyboard.press!("Enter")
    Page.locator(page, "#opened") |> Expect.to_have_text!("Opened #{name}")
  end

  test "a cell that edits is the editor's: a click and Enter do not open its row", %{page: page} do
    Page.locator(page, cell(0, 2)) |> Locator.click!()
    page |> Page.keyboard() |> Keyboard.press!("Enter")
    Page.locator(page, "#open .masu-editor") |> Expect.to_be_visible!()
    page |> Page.keyboard() |> Keyboard.press!("Escape")
    Page.locator(page, "#open .masu-editor") |> Expect.to_have_count!(0)
    Page.locator(page, "#opened") |> Expect.to_have_count!(0)
    Expect.to_have_url!(page, ~r/\/open$/)
  end

  test "a click that ends an editor does not open a row", %{page: page} do
    Page.locator(page, cell(0, 2)) |> Locator.dblclick!()
    Page.locator(page, "#open .masu-editor") |> Expect.to_be_visible!()
    Page.locator(page, cell(1, 0)) |> Locator.click!()
    Page.locator(page, "#open .masu-editor") |> Expect.to_have_count!(0)
    Page.locator(page, "#opened") |> Expect.to_have_count!(0)
  end

  test "a link in a cell is a link", %{page: page} do
    Page.locator(page, "#{cell(0, 3)} a") |> Locator.click!()
    Expect.to_have_url!(page, ~r/\/open\?site=\d+$/)
    Page.locator(page, "#site") |> Expect.to_have_text!(~r/Site of \d+/)
    Page.locator(page, "#opened") |> Expect.to_have_count!(0)
  end

  test "selecting a range, by a drag or Shift and a click, opens no row", %{page: page} do
    Page.locator(page, cell(0, 0)) |> Locator.click!(modifiers: [:shift])
    Page.locator(page, cell(2, 1)) |> Locator.click!(modifiers: [:shift])
    page |> Page.locator("#open .masu-selected") |> Locator.first() |> Expect.to_be_visible!()

    from = Page.locator(page, cell(3, 0)) |> Locator.bounding_box!()
    to = Page.locator(page, cell(5, 1)) |> Locator.bounding_box!()
    mouse = Page.mouse(page)
    Mouse.move!(mouse, from.x + 10, from.y + 10)
    Mouse.down!(mouse)
    Mouse.move!(mouse, to.x + 10, to.y + 10, steps: 5)
    Mouse.up!(mouse)
    Page.locator(page, "#opened") |> Expect.to_have_count!(0)
    Expect.to_have_url!(page, ~r/\/open$/)
  end

  # With no ranges (`range_select={false}`, `?range=off`), a cell is selected
  # alone: a drag, Shift and a click, Shift and a move, and Ctrl+A select no
  # range, and a click on a row still opens it.
  describe "with no ranges" do
    setup %{page: page} do
      open_page(page, "/open?range=off")
      :ok
    end

    test "a drag and Shift with a click select no range", %{page: page} do
      Page.locator(page, cell(0, 0)) |> Locator.click!(modifiers: [:shift])
      Page.locator(page, cell(2, 1)) |> Locator.click!(modifiers: [:shift])
      Page.locator(page, "#open .masu-selected") |> Expect.to_have_count!(0)

      from = Page.locator(page, cell(3, 0)) |> Locator.bounding_box!()
      to = Page.locator(page, cell(5, 1)) |> Locator.bounding_box!()
      mouse = Page.mouse(page)
      Mouse.move!(mouse, from.x + 10, from.y + 10)
      Mouse.down!(mouse)
      Mouse.move!(mouse, to.x + 10, to.y + 10, steps: 5)
      Mouse.up!(mouse)
      Page.locator(page, "#open .masu-selected") |> Expect.to_have_count!(0)
      # The cell pressed stays the active one, and no row opens.
      grid(page, "open") |> Expect.to_have_attribute!("aria-activedescendant", "open-r3-c0")
      Page.locator(page, "#opened") |> Expect.to_have_count!(0)
    end

    test "Shift with a move, and Ctrl+A, select no range", %{page: page} do
      Page.locator(page, cell(1, 0)) |> Locator.click!(modifiers: [:alt])
      grid(page, "open") |> Locator.focus!()
      page |> Page.keyboard() |> Keyboard.press!("Shift+ArrowDown")
      page |> Page.keyboard() |> Keyboard.press!("Shift+ArrowRight")
      Page.locator(page, "#open .masu-selected") |> Expect.to_have_count!(0)
      grid(page, "open") |> Expect.to_have_attribute!("aria-activedescendant", "open-r2-c1")

      page |> Page.keyboard() |> Keyboard.press!("ControlOrMeta+a")
      Page.locator(page, "#open .masu-selected") |> Expect.to_have_count!(0)
    end

    test "a click on a row still opens it", %{page: page} do
      [name | _] = row_text(page, "open", 2)
      Page.locator(page, cell(2, 1)) |> Locator.click!()
      Page.locator(page, "#opened") |> Expect.to_have_text!("Opened #{name}")
    end
  end
end

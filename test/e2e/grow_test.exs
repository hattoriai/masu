defmodule MasuE2E.GrowTest do
  use MasuE2E.Case, async: true, parameterize: MasuE2E.Case.projects()

  # A column that grows (`grow`), on the Grow page: the name (200px and
  # grow) takes the room that city (130), plan (120), seats (100) and active
  # (90, pinned to the end) leave.

  @base 200 + 130 + 120 + 100 + 90

  # The tracks the grid draws its columns at, in pixels.
  defp cols(page) do
    Page.locator(page, "#grow-content")
    |> Locator.evaluate!(
      ~s|(el) => el.style.getPropertyValue("--masu-cols").split(" ").map((track) => parseFloat(track))|
    )
  end

  # The room of the grid's box: its width, without a scrollbar.
  defp room(page), do: grid(page, "grow") |> Locator.evaluate!("(el) => el.clientWidth")

  setup %{page: page} do
    open_page(page, "/grow")
    :ok
  end

  test "the column that grows takes the room the others leave: no empty room after the last", %{
    page: page
  } do
    width = room(page)
    assert width > @base
    Expect.poll!(fn -> Enum.sum(cols(page)) end, &assert(&1 == width))
    [name | others] = cols(page)
    assert name == width - (@base - 200)
    assert others == [130, 120, 100, 90]

    # The column pinned to the end is at the grid's end; the header and the rows have the same tracks.
    box = grid(page, "grow") |> Locator.bounding_box!()
    active = header(page, "grow", "active") |> Locator.bounding_box!()
    assert abs(active.x + active.width - (box.x + width)) <= 1
    cell = Page.locator(page, "#grow-r0-c0") |> Locator.bounding_box!()
    assert round(cell.width) == name
    grid(page, "grow") |> Expect.to_have_js_property!("scrollWidth", width)
  end

  test "it follows the width of the window, down to its own width; then the grid scrolls sideways",
       %{page: page} do
    wide = room(page)
    Page.set_viewport_size!(page, %{width: 900, height: 720})
    Expect.poll!(fn -> room(page) end, &assert(&1 < wide))
    width = room(page)
    Expect.poll!(fn -> Enum.at(cols(page), 0) end, &assert(&1 == width - (@base - 200)))

    Page.set_viewport_size!(page, %{width: 500, height: 720})
    Expect.poll!(fn -> Enum.at(cols(page), 0) end, &assert(&1 == 200))

    assert grid(page, "grow") |> Locator.evaluate!("(el) => el.scrollWidth > el.clientWidth") ==
             true
  end

  test "a person who resizes it gives it their width: it grows no more", %{page: page} do
    mouse = Page.mouse(page)
    resizer = header(page, "grow", "name") |> Locator.locator(".masu-resizer")
    box = Locator.bounding_box!(resizer)
    before = Enum.at(cols(page), 0)
    Mouse.move!(mouse, box.x + 4, box.y + box.height / 2)
    Mouse.down!(mouse)
    Mouse.move!(mouse, box.x + 4 - 100, box.y + box.height / 2, steps: 4)
    Mouse.up!(mouse)
    Expect.poll!(fn -> Enum.at(cols(page), 0) end, &assert(&1 == before - 100))

    # The room it left stays empty, and a wider window does not grow it.
    Page.set_viewport_size!(page, %{width: 1400, height: 720})
    Expect.poll!(fn -> room(page) end, &assert(&1 > @base + 400))
    assert Enum.at(cols(page), 0) == before - 100

    # Another column's width: the others keep theirs.
    city = header(page, "grow", "city") |> Locator.locator(".masu-resizer")
    city_box = Locator.bounding_box!(city)
    Mouse.move!(mouse, city_box.x + 4, city_box.y + city_box.height / 2)
    Mouse.down!(mouse)
    Mouse.move!(mouse, city_box.x + 54, city_box.y + city_box.height / 2, steps: 4)
    Mouse.up!(mouse)
    Expect.poll!(fn -> Enum.take(cols(page), 2) end, &assert(&1 == [before - 100, 180]))
  end

  test "another column's resize takes its room from the column that grows", %{page: page} do
    mouse = Page.mouse(page)
    width = room(page)
    city = header(page, "grow", "city") |> Locator.locator(".masu-resizer")
    box = Locator.bounding_box!(city)
    Mouse.move!(mouse, box.x + 4, box.y + box.height / 2)
    Mouse.down!(mouse)
    Mouse.move!(mouse, box.x + 54, box.y + box.height / 2, steps: 4)
    Mouse.up!(mouse)

    Expect.poll!(
      fn -> Enum.take(cols(page), 2) end,
      &assert(&1 == [width - (@base - 200) - 50, 180])
    )

    grid(page, "grow") |> Expect.to_have_js_property!("scrollWidth", width)
  end
end

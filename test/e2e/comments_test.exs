defmodule MasuE2E.CommentsTest do
  use MasuE2E.Case, async: true, parameterize: MasuE2E.Case.projects()

  # Issho's comments on a shared grid (dev.exs, /comments): a thread on a
  # cell, said in words, and its mark on that cell on each person's screen,
  # whatever their order.

  # The top right corner of a box, where a thread's mark goes.
  defp corner(locator) do
    box = Locator.bounding_box!(locator)
    %{x: box.x + box.width, y: box.y}
  end

  # The cell of a column in the row whose Name is `name`, as this page shows it.
  defp cell_of(page, name, col) do
    page
    |> Page.locator("#customers .masu-body .masu-row",
      has: Page.locator(page, ".masu-cell", has_text: name)
    )
    |> Locator.locator(~s(.masu-cell[aria-colindex="#{col + 1}"]))
  end

  # The page's one mark, over the top right corner of the cell.
  defp expect_mark_on(page, cell) do
    mark = Page.locator(page, ".issho-comment-mark")
    Expect.to_be_visible!(mark)

    Expect.poll!(
      fn ->
        {box, at} = {Locator.bounding_box!(mark), corner(cell)}

        at.x >= box.x and at.x <= box.x + box.width and at.y >= box.y and
          at.y <= box.y + box.height
      end,
      &assert(&1 == true)
    )
  end

  test "a thread on a cell: its place in words, and its mark on the cell, in each person's order",
       ctx do
    room = room_name("comments")
    ada = ctx.browser |> Browser.new_context!(locale: "en-GB") |> BrowserContext.new_page!()
    alan = ctx.browser |> Browser.new_context!(locale: "en-GB") |> BrowserContext.new_page!()
    errors = collector()
    Page.on(ada, :page_error, &push(errors, Exception.message(&1)))
    open_page(ada, "/comments?as=Ada&room=#{room}")
    open_page(alan, "/comments?as=Alan&room=#{room}")

    # Ada selects the City of the third row, and comments on it.
    name = ada |> Page.locator("#customers-r2-c1") |> Locator.text_content!() |> String.trim()
    Page.locator(ada, "#customers-r2-c2") |> Locator.click!()
    where = Page.locator(ada, "#threads .issho-where-label")
    where |> Expect.to_have_text!("City of #{name}")

    Page.locator(ada, "#threads .issho-composer textarea")
    |> Locator.fill!("Is this the right city?")

    Page.locator(ada, "#threads .issho-composer")
    |> Locator.get_by_role(:button, name: "Comment")
    |> Locator.click!()

    place = Page.locator(ada, "#threads .issho-thread .issho-thread-place-label")
    place |> Expect.to_have_text!("City of #{name}")
    expect_mark_on(ada, cell_of(ada, name, 2))

    # Alan, in another order, sees the thread; its mark is on the same
    # cell, once its row is on his screen.
    expect_mark_on(alan, cell_of(alan, name, 2))
    header(alan, "customers", "name") |> Locator.click!()
    header(alan, "customers", "name") |> Locator.click!()
    header(alan, "customers", "name") |> Expect.to_have_attribute!("aria-sort", "descending")

    Page.locator(alan, "#threads .issho-thread .issho-thread-place-label")
    |> Expect.to_have_text!("City of #{name}")

    Page.locator(alan, "#threads .issho-comment")
    |> Expect.to_contain_text!("Is this the right city?")

    Page.locator(alan, ".issho-comment-mark") |> Expect.to_be_hidden!()
    grid(alan, "customers") |> Locator.evaluate!("(el) => el.scrollTo(0, el.scrollHeight)")
    expect_mark_on(alan, cell_of(alan, name, 2))

    # A click on the mark opens the thread.
    Page.locator(alan, ".issho-comment-mark") |> Locator.click!()
    Page.locator(alan, "#threads .issho-thread[data-focused]") |> Expect.to_have_count!(1)
    assert items(errors) == []
  end
end

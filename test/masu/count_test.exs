defmodule Masu.CountTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Masu.Test

  @endpoint MasuTest.Endpoint

  defp open(query \\ "") do
    {:ok, view, _html} = live(build_conn(), "/counts" <> query)
    view
  end

  defp aria_rowcount(view, id) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("##{id}-grid")
    |> LazyHTML.attribute("aria-rowcount")
    |> hd()
  end

  describe "a source that does not know its count" do
    test "knows the rows it read, and more as it reads; a short block says where they end" do
      view = open("?mode=unknown")
      assert count(view, "engine") == {:at_least, 60}
      assert aria_rowcount(view, "engine") == "-1"

      assert length(ids(view, "engine", from: 100, count: 100)) == 100
      assert count(view, "engine") == {:at_least, 200}

      assert length(ids(view, "engine", from: 200, count: 100)) == 50
      assert count(view, "engine") == {:exact, 250}
      assert aria_rowcount(view, "engine") == "251"
    end

    test "a block past the end asks the source; one that says at least is taken as such" do
      view = open("?mode=at_least")
      assert count(view, "engine") == {:at_least, 100}
      assert ids(view, "engine", from: 400, count: 100) == []
      assert count(view, "engine") == {:at_least, 100}
    end

    test "a count that comes with the rows is taken" do
      view = open("?mode=inline")
      assert count(view, "engine") == {:exact, 250}
    end
  end

  test "count={:deferred} shows the rows first, and the count when it comes" do
    view = open()
    render_async(view)
    assert count(view, "late") == {:exact, 237}
  end

  test "count={:none} counts when the person goes to the end" do
    view = open()
    assert count(view, "never") == {:at_least, 60}
    assert ask_count(view, "never") == {:exact, 237}
    assert aria_rowcount(view, "never") == "238"

    # A new query does not know its count again, unless its first block
    # is short.
    search(view, "never", "item")
    assert count(view, "never") == {:at_least, 100}
    search(view, "never", "item 1")
    assert {:exact, n} = count(view, "never")
    assert n < 100
  end

  describe "paging={:pages}" do
    test "a page at a time, the page in the URL, and a new query from the first" do
      view = open()
      assert ids(view, "pages", count: 0) == []
      assert page(view, "pages", 2) == Enum.to_list(51..100)
      assert_patch(view)
      assert view(view, "pages")["page"] == "2"

      # Past the last page: the last.
      assert page(view, "pages", 99) == Enum.to_list(201..237)
      assert view(view, "pages")["page"] == "5"

      sort(view, "pages", {"id", :desc})
      assert view(view, "pages")["page"] == nil
    end

    test "the pager says where the page is, and goes to another" do
      view = open()
      assert view |> element("#pages .masu-pager-range") |> render() =~ "1–50 of 237"
      assert view |> element("#pages .masu-pager-form") |> render() =~ "of 5"
      assert view |> element("#pages .masu-pager-previous[disabled]") |> has_element?()

      view |> element("#pages .masu-pager-next") |> render_click()
      assert view |> element("#pages .masu-pager-range") |> render() =~ "51–100 of 237"
      assert view(view, "pages")["page"] == "2"

      view |> element("#pages .masu-pager-form") |> render_submit(%{"page" => "5"})
      assert view |> element("#pages .masu-pager-range") |> render() =~ "201–237 of 237"
      assert view |> element("#pages .masu-pager-next[disabled]") |> has_element?()
    end

    test "a link opens its page" do
      {:ok, view, html} = live(build_conn(), "/counts?pages[page]=3")
      assert html =~ ~s(&quot;page&quot;:2)
      assert html =~ ~s(&quot;from&quot;:100)
      assert view(view, "pages")["page"] == "3"
    end
  end

  test "View params: the page, from 1" do
    default = %Masu.View{}
    assert Masu.View.to_params(%Masu.View{page: 2}, default) == %{"page" => "3"}
    assert {%Masu.View{page: 2}, []} = Masu.View.from_params(%{"page" => "3"}, [], default)
    assert {%Masu.View{page: 0}, []} = Masu.View.from_params(%{"page" => "0"}, [], default)
  end
end

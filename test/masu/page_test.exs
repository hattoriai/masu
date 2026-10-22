defmodule Masu.PageTest do
  # A grid in a page (a Kotoba document): it opens with a saved view, is as
  # tall as its rows, leaves the wheel to the page, and reads as a table
  # without the grid (Masu.Snapshot).
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Masu.Test

  alias Masu.{Sheet, Snapshot}

  @endpoint MasuTest.Endpoint

  defp open(view \\ nil) do
    {:ok, live, _html} =
      live_isolated(build_conn(), MasuTest.PageLive, session: %{"view" => view})

    live
  end

  defp config(live) do
    live
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#page")
    |> LazyHTML.attribute("data-masu")
    |> hd()
    |> JSON.decode!()
  end

  test "it opens with the view it is given: its order, filters and columns" do
    live =
      open(%{
        "sort" => "-age",
        "hide" => "city",
        "filter" => %{"0" => %{"key" => "age", "op" => "gte", "value" => 30}}
      })

    assert columns(live, "page") == ["Id", "Name", "Age"]
    ages = live |> rows("page") |> Enum.map(& &1["age"])
    assert ages == Enum.sort(ages, :desc)
    assert Enum.all?(ages, &(&1 >= 30))
  end

  test "it is as tall as its rows, up to its most, and the wheel is the page's" do
    live = open()
    assert %{"autoHeight" => "20rem", "wheel" => "page"} = config(live)

    [style] =
      live
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#page-grid")
      |> LazyHTML.attribute("style")

    assert style =~ ~r/height: min\(20rem, \d+px\)/
  end

  describe "a snapshot" do
    defp sheet do
      Sheet.new(
        id: "people",
        rows: MasuTest.People.all(),
        columns: [
          [field: :name, label: "Name | full"],
          [field: :age, type: :integer],
          [field: :city]
        ]
      )
    end

    test "Markdown: a table of the view's rows and columns, and how many more" do
      total = length(MasuTest.People.all())
      markdown = Snapshot.markdown(sheet(), view: %{"sort" => "age", "hide" => "city"}, rows: 2)

      assert [head, rule, _one, _two, "", more] = String.split(markdown, "\n")
      assert head == "| Name \\| full | Age |"
      assert rule == "| :--- | ---: |"
      assert more == "_And #{total - 2} more rows._"
    end

    test "every row, and no line of more" do
      markdown = Snapshot.markdown(sheet(), rows: 500)
      refute markdown =~ "more"
      assert length(String.split(markdown, "\n")) == length(MasuTest.People.all()) + 2
    end

    test "HTML: the same table, escaped" do
      html =
        sheet() |> Snapshot.html(rows: 1, more: &"#{&1} others") |> Phoenix.HTML.safe_to_string()

      assert html =~
               ~s(<table class="masu-snapshot"><thead><tr><th class="masu-align-start">Name | full</th>)

      assert html =~ ~s(<th class="masu-align-end">Age</th>)
      assert html =~ ~s(<p class="masu-snapshot-more">)
      assert html =~ "others</p>"
    end
  end
end

defmodule Masu.DetailTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Masu.Test

  @endpoint MasuTest.Endpoint

  defp details(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#people > .masu-grid > .masu-details > .masu-detail")
  end

  defp config(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#people")
    |> LazyHTML.attribute("data-masu")
    |> hd()
    |> JSON.decode!()
  end

  test "a row opens on its detail, rendered by the server, with a grid of its own" do
    {:ok, view, _html} = live(build_conn(), "/details")
    assert Enum.empty?(details(view))

    detail(view, "people", 3)
    [detail] = Enum.to_list(details(view))
    assert LazyHTML.text(LazyHTML.query(detail, ".bio")) == "Grace Hopper lives in Arlington."
    assert LazyHTML.attribute(detail, "data-id") == ["3"]
    assert LazyHTML.attribute(detail, "role") == ["region"]
    assert config(view)["details"] == [[3, 2]]
    assert config(view)["detail"]

    # The grid in the detail is a grid like any other.
    assert rows(view, "skills-3") |> Enum.map(& &1["skill"]) == ["Math", "Logic", "Code"]

    assert sort(view, "skills-3", {"years", :asc}) |> rows("skills-3") |> hd() == %{
             "skill" => "Code",
             "years" => 82
           }

    detail(view, "people", 1)
    assert config(view)["details"] == [[3, 2], [1, 0]]

    detail(view, "people", 3, false)
    assert config(view)["details"] == [[1, 0]]
  end

  test "a detail follows its row: its place in the order, and none when a filter leaves it out" do
    {:ok, view, _html} = live(build_conn(), "/details")
    detail(view, "people", 3)

    sort(view, "people", {"name", :desc})
    assert config(view)["details"] == [[3, 0]]

    filter(view, "people", [{"name", :contains, "ada"}])
    assert config(view)["details"] == []
    assert Enum.empty?(details(view))

    filter(view, "people", [])
    assert config(view)["details"] == [[3, 0]]
  end
end

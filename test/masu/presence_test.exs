defmodule Masu.PresenceTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Masu.Test

  @endpoint MasuTest.Endpoint

  defp open(user, params \\ "") do
    {:ok, view, _html} = live(build_conn(), "/presence?user=#{user}#{params}")
    view
  end

  defp people(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".masu-person")
    |> LazyHTML.attribute("title")
  end

  test "each person sees the others who have the grid open, not themselves" do
    ada = open("ada")
    alan = open("alan")

    assert_eventually(fn -> people(ada) == ["Alan"] end)
    assert_eventually(fn -> people(alan) == ["Ada"] end)
    assert render(ada) =~ ~s(class="masu-initials" aria-label="Alan">)

    GenServer.stop(alan.pid)
    assert_eventually(fn -> people(ada) == [] end)
  end

  test "a person's place goes to the others: a row's id and a column's key, and whether they edit" do
    ada = open("ada")
    alan = open("alan")
    assert_eventually(fn -> people(ada) == ["Alan"] end)

    render_hook(element(alan, "#people"), "masu:cursor", %{
      "cell" => [3, "name"],
      "editing" => true
    })

    assert_push_event(
      ada,
      "masu:people",
      %{"id" => "people", "people" => [%{name: "Alan", cell: [3, "name"], editing: true}]},
      1000
    )
  end

  test "a saved row flashes in the color of the person who saved it" do
    ada = open("ada")
    alan = open("alan", "&color=%23ff0000")
    assert_eventually(fn -> people(ada) == ["Alan"] end)

    assert :ok = edit(alan, "people", [{2, "name", "Alan"}])

    assert_eventually(fn ->
      render(ada) =~ "&quot;changedBy&quot;:{&quot;2&quot;:&quot;#ff0000&quot;}"
    end)
  end

  test "the :person slot draws the people" do
    ada = open("ada", "&slot=1")
    _alan = open("alan")
    assert_eventually(fn -> render(ada) =~ ~s[<b class="mine">Alan (A)</b>] end)
  end

  test "a person's color is a color of their own, a plain CSS color, or one of the palette" do
    assert Masu.Presence.color(%{id: 1, color: "#2563eb"}) == "#2563eb"
    assert Masu.Presence.color(%{id: 1, color: "oklch(60% 0.2 30)"}) == "oklch(60% 0.2 30)"

    assert Masu.Presence.color(%{id: 1, color: "red; background: url(x)"}) ==
             Masu.Presence.color(%{id: 1})

    assert Masu.Presence.color(%{id: "ada"}) == Masu.Presence.color(%{id: "ada"})
    assert Masu.Presence.color(%{id: "ada"}) =~ ~r/^#[0-9a-f]{6}$/
  end

  test "a grid with presence needs live and a user" do
    assert_raise ArgumentError, ~r/with presence needs live and user/, fn ->
      render_component(&Masu.Components.data_grid/1,
        id: "x",
        rows: [],
        presence: MasuTest.Presence,
        col: [%{field: :name, __slot__: :col, inner_block: nil}]
      )
    end
  end

  defp assert_eventually(fun, tries \\ 50) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("never true")

      true ->
        Process.sleep(20)
        assert_eventually(fun, tries - 1)
    end
  end
end

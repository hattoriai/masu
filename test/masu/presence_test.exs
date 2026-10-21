defmodule Masu.PresenceTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Masu.Test

  @endpoint MasuTest.Endpoint

  setup do
    %{room: "presence:#{System.unique_integer([:positive])}"}
  end

  defp open(room, user, params \\ "") do
    {:ok, view, _html} = live(build_conn(), "/presence?room=#{room}&user=#{user}#{params}")
    view
  end

  defp people(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".masu-person")
    |> LazyHTML.attribute("title")
  end

  test "each person sees the others who have the grid open, not themselves", %{room: room} do
    ada = open(room, "ada")
    alan = open(room, "alan")

    assert_eventually(fn -> people(ada) == ["Alan"] end)
    assert_eventually(fn -> people(alan) == ["Ada"] end)
    assert render(ada) =~ ~s(aria-label="Follow Alan")

    GenServer.stop(alan.pid)
    assert_eventually(fn -> people(ada) == [] end)
  end

  test "a person's place goes to the others: a row's id and a column's key, and whether they edit",
       %{room: room} do
    ada = open(room, "ada")
    alan = open(room, "alan")
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

  test "a refusal names who changed the cell meanwhile", %{room: room} do
    ada = open(room, "ada")
    alan = open(room, "alan")
    assert_eventually(fn -> people(ada) == ["Alan"] end)

    assert :ok = edit(ada, "people", [{2, "name", "Alan T.", "alan Turing"}])

    assert {:error, [{2, "name", "Changed by Ada meanwhile."}]} =
             edit(alan, "people", [{2, "name", "A. Turing", "alan Turing"}])
  end

  test "a person's view and the first row on their screen go to the others", %{room: room} do
    ada = open(room, "ada")
    alan = open(room, "alan")
    assert_eventually(fn -> people(ada) == ["Alan"] end)

    assert_push_event(ada, "masu:people", %{"people" => [%{name: "Alan", view: view}]}, 1000)
    assert view == %{"sorts" => [], "filters" => [], "search" => nil, "groups" => []}

    render_hook(element(alan, "#people"), "masu:query", %{
      "sorts" => [%{"key" => "name", "dir" => "desc"}],
      "filters" => [],
      "search" => "a"
    })

    assert_push_event(
      ada,
      "masu:people",
      %{
        "people" => [
          %{view: %{"sorts" => [%{"key" => "name", "dir" => "desc"}], "search" => "a"}}
        ]
      },
      1000
    )

    render_hook(element(alan, "#people"), "masu:cursor", %{
      "cell" => [3, "name"],
      "editing" => false,
      "top" => 3
    })

    assert_push_event(ada, "masu:people", %{"people" => [%{top: 3}]}, 1000)
  end

  test "a grid with share_view={false} keeps its view from the others", %{room: room} do
    ada = open(room, "ada")
    alan = open(room, "alan", "&share=0")
    assert_eventually(fn -> people(ada) == ["Alan"] end)

    render_hook(element(alan, "#people"), "masu:query", %{
      "sorts" => [%{"key" => "name", "dir" => "desc"}],
      "filters" => [],
      "search" => nil
    })

    render_hook(element(alan, "#people"), "masu:cursor", %{
      "cell" => [3, "name"],
      "editing" => false
    })

    assert_push_event(ada, "masu:people", %{"people" => [%{cell: [3, "name"], view: nil}]}, 1000)
  end

  test "a person's selected range goes to the others as row ids and column keys", %{room: room} do
    ada = open(room, "ada")
    alan = open(room, "alan")
    assert_eventually(fn -> people(ada) == ["Alan"] end)

    render_hook(element(alan, "#people"), "masu:cursor", %{
      "cell" => [3, "name"],
      "editing" => false,
      "range" => %{"rows" => [1, 3, 4], "keys" => ["name"]}
    })

    assert_push_event(
      ada,
      "masu:people",
      %{"people" => [%{name: "Alan", range: %{"rows" => [1, 3, 4], "keys" => ["name"]}}]},
      1000
    )
  end

  test "a saved row flashes in the color of the person who saved it", %{room: room} do
    ada = open(room, "ada")
    alan = open(room, "alan", "&color=%23ff0000")
    assert_eventually(fn -> people(ada) == ["Alan"] end)

    assert :ok = edit(alan, "people", [{2, "name", "Alan"}])

    assert_eventually(fn ->
      render(ada) =~ "&quot;changedBy&quot;:{&quot;2&quot;:&quot;#ff0000&quot;}"
    end)
  end

  test "the :person slot draws the people", %{room: room} do
    ada = open(room, "ada", "&slot=1")
    _alan = open(room, "alan")
    assert_eventually(fn -> render(ada) =~ ~s[<b class="mine">Alan (A)</b>] end)
  end

  test "a grid with presence says it moved to issho" do
    assert_raise ArgumentError, ~r/presence, which Masu 0.4 removed/, fn ->
      render_component(&Masu.Components.data_grid/1,
        id: "x",
        rows: [],
        presence: SomePresence,
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

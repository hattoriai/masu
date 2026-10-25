defmodule Masu.Issho.PeopleTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Issho.Participant
  alias Issho.Tool.Context

  @endpoint MasuTest.Endpoint

  setup do
    instance = MasuTest.Issho
    topic = "people-#{System.unique_integer([:positive])}"
    room = "notebook:#{System.unique_integer([:positive])}"
    grid = room <> "/people"

    Application.put_env(:masu, Masu.Issho,
      pace: 0,
      grids: fn ^grid, _ctx -> {:ok, MasuTest.SheetLive.grid(topic)} end
    )

    on_exit(fn -> Application.delete_env(:masu, Masu.Issho) end)

    session = %{
      "instance" => instance,
      "room" => room,
      "topic" => topic,
      "user" => "bob",
      "name" => "Bob"
    }

    {:ok, bob, _html} = live_isolated(build_conn(), MasuTest.IsshoGridLive, session: session)

    ctx = Context.new(instance, %{id: "assistant", name: "Assistant", kind: :agent})
    %{instance: instance, room: room, grid: grid, bob: bob, ctx: ctx}
  end

  # Waits for an awareness frame of the room that passes `check`.
  defp assert_aware(participant, check) do
    receive do
      {Participant, ^participant, "aware", %{"states" => states}} ->
        if check.(states), do: :ok, else: assert_aware(participant, check)
    after
      1_000 -> flunk("no awareness frame passed")
    end
  end

  defp call(name, args, ctx), do: Issho.Tools.call(Masu.Issho.tools(), name, args, ctx)

  test "a person's grid shows where an agent of the room is, and its avatar",
       %{grid: grid, bob: bob, ctx: ctx} do
    {:ok, _} = call("select_cells", %{"grid" => grid, "row" => 2, "key" => "name"}, ctx)

    assert_push_event(
      bob,
      "masu:people",
      %{"people" => [%{name: "Assistant", cell: [2, "name"]}]},
      1_000
    )

    assert render(bob) =~ ~s(title="Assistant")
  end

  test "an agent sees the cell a person edits in their grid, and leaves it",
       %{instance: instance, room: room, grid: grid, bob: bob, ctx: ctx} do
    {:ok, watcher} = Issho.join_as(instance, %{id: "watcher", name: "Watcher"}, room)

    render_hook(element(bob, "#people"), "masu:cursor", %{
      "cell" => [1, "name"],
      "editing" => true
    })

    # The frames come as the room's awareness sends them: Bob's join, then his cell.
    assert_aware(watcher, fn states ->
      Enum.any?(Map.values(states), fn %{"key" => key, "state" => state} ->
        key == "bob" and
          state["place"] == %{
            "doc" => grid,
            "at" => %{"cell" => [1, "name"]},
            "label" => "Name of “Ada Lovelace”"
          }
      end)
    end)

    assert {:error, "Nothing saved: Row 1, name: Bob is editing this cell."} =
             call(
               "edit_cells",
               %{"grid" => grid, "edits" => [%{"row" => 1, "key" => "name", "value" => "X"}]},
               ctx
             )

    render_hook(element(bob, "#people"), "masu:cursor", %{
      "cell" => [1, "name"],
      "editing" => false
    })

    Participant.leave(watcher)

    assert {:ok, %{"saved" => 1}} =
             call(
               "edit_cells",
               %{
                 "grid" => grid,
                 "edits" => [%{"row" => 1, "key" => "name", "value" => "Ada King"}]
               },
               ctx
             )
  end

  test "an agent reads and edits the cells a person selected in their grid", %{
    grid: grid,
    bob: bob,
    ctx: ctx
  } do
    render_hook(element(bob, "#people"), "masu:cursor", %{
      "cell" => [1, "name"],
      "editing" => false,
      "range" => %{"rows" => [1, 2], "keys" => ["city"]}
    })

    assert {:ok, %{"of" => %{"name" => "Bob", "range" => %{"rows" => [1, 2]}, "rows" => rows}}} =
             call("read_grid", %{"grid" => grid, "of" => "Bob"}, ctx)

    assert Enum.map(rows, & &1["id"]) == [1, 2]

    # The city column does not edit: the grid's rules answer the agent as anyone.
    assert {:error, "Nothing saved: " <> _} =
             call("edit_cells", %{"grid" => grid, "of" => "bob", "value" => "Paris"}, ctx)

    render_hook(element(bob, "#people"), "masu:cursor", %{
      "cell" => [2, "age"],
      "editing" => false
    })

    assert {:ok, %{"saved" => 1}} =
             call("edit_cells", %{"grid" => grid, "of" => "Bob", "value" => 42}, ctx)
  end

  test "a person's place says what they selected, in words",
       %{instance: instance, room: room, grid: grid, bob: bob} do
    {:ok, watcher} = Issho.join_as(instance, %{id: "watcher", name: "Watcher"}, room)

    render_hook(element(bob, "#people"), "masu:cursor", %{
      "cell" => [1, "age"],
      "editing" => false,
      "range" => %{"rows" => [1, 2, 3], "keys" => ["age"]}
    })

    assert_aware(watcher, fn states ->
      Enum.any?(Map.values(states), fn %{"key" => key, "state" => state} ->
        key == "bob" and match?(%{"doc" => ^grid, "label" => "Age, 3 rows"}, state["place"])
      end)
    end)

    render_hook(element(bob, "#people"), "masu:cursor", %{
      "cell" => [2, "city"],
      "editing" => true
    })

    assert_aware(watcher, fn states ->
      Enum.any?(Map.values(states), fn %{"key" => key, "state" => state} ->
        # The lock is the place alone, as the others compare it.
        key == "bob" and match?(%{"label" => "City of “" <> _}, state["place"]) and
          state["locks"] == [%{"doc" => grid, "at" => %{"cell" => [2, "city"]}}]
      end)
    end)
  end

  test "an agent's places say what it goes to, in words", %{grid: grid, ctx: ctx} do
    {:ok, open} = Masu.Issho.open(ctx, grid)
    name = Masu.Issho.row_name(open, 1)
    assert name == "Ada Lovelace"

    assert %{"doc" => ^grid, "at" => %{"cell" => [1, "age"]}, "label" => "Age of “Ada Lovelace”"} =
             Masu.Issho.labeled(open, {1, "age"}, name)

    assert %{"label" => "2 rows × 2 columns"} =
             Masu.Issho.labeled(open, {[1, 2], ["name", "age"]}, name)

    assert Masu.Issho.row_name(open, 404) == nil
  end
end

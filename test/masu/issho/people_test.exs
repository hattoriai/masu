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

    assert_receive {Participant, ^watcher, "aware", %{"states" => states}}, 1_000

    assert Enum.any?(Map.values(states), fn %{"key" => key, "state" => state} ->
             key == "bob" and state["place"] == %{"doc" => grid, "at" => %{"cell" => [1, "name"]}}
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
end

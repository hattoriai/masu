defmodule Masu.Issho.ToolsTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Masu.Test

  alias Issho.Participant
  alias Issho.Tool.Context

  @endpoint MasuTest.Endpoint

  setup do
    instance = MasuTest.Issho
    topic = "agents-#{System.unique_integer([:positive])}"
    room = "notebook:#{System.unique_integer([:positive])}"
    grid = room <> "/people"

    Application.put_env(:masu, Masu.Issho,
      pace: 0,
      grids: fn
        ^grid, _ctx ->
          {:ok, MasuTest.SheetLive.grid(topic)}

        "notebook:" <> _ = name, _ctx ->
          if String.ends_with?(name, "/open"), do: {:ok, open_grid()}

        _other, _ctx ->
          nil
      end
    )

    on_exit(fn -> Application.delete_env(:masu, Masu.Issho) end)

    {:ok, ada} = Issho.join_as(instance, %{id: "ada", name: "Ada"}, room)

    ctx =
      Context.new(instance, %{id: "assistant:ada", name: "Assistant", kind: :agent},
        on_behalf_of: %{id: "ada", name: "Ada"}
      )

    %{instance: instance, topic: topic, room: room, grid: grid, ada: ada, ctx: ctx}
  end

  # A grid of a list that adds and deletes rows.
  defp open_grid do
    MasuTest.SheetLive.grid("open")
    |> Keyword.merge(
      id: "open",
      struct: fn -> %{id: System.unique_integer([:positive])} end,
      deletable: true
    )
  end

  defp call(name, args, ctx), do: Issho.Tools.call(Masu.Issho.tools(), name, args, ctx)

  test "reads a grid's columns and rows, in an order, filtered", %{grid: grid, ctx: ctx} do
    assert {:ok, %{"columns" => columns, "rows" => rows, "total" => 2, "can" => can}} =
             call(
               "read_grid",
               %{
                 "grid" => grid,
                 "sort" => [%{"key" => "age", "dir" => "desc"}],
                 "filters" => [%{"key" => "age", "op" => "gte", "value" => 80}]
               },
               ctx
             )

    assert [
             %{"key" => "name", "editable" => true},
             %{"key" => "age", "type" => "integer"},
             %{"key" => "city", "editable" => false}
           ] =
             columns

    assert [%{"age" => age1}, %{"age" => age2}] = rows
    assert age1 >= age2
    assert can == %{"edit" => true, "create" => false, "delete" => false}

    assert {:error, "There is no filter \"near\"."} =
             call(
               "read_grid",
               %{"grid" => grid, "filters" => [%{"key" => "age", "op" => "near"}]},
               ctx
             )

    assert {:error, "There is no grid notebook:" <> _} =
             call("read_grid", %{"grid" => grid <> "x"}, ctx)
  end

  test "selects cells, and the people see where the agent is", %{grid: grid, ada: ada, ctx: ctx} do
    assert {:ok, "Selected."} =
             call("select_cells", %{"grid" => grid, "row" => 2, "key" => "name"}, ctx)

    assert_receive {Participant, ^ada, "aware", %{"states" => states}}, 1_000

    assert [%{"state" => %{"place" => %{"doc" => ^grid, "at" => %{"cell" => [2, "name"]}}}}] =
             Map.values(states)
  end

  # The agent's places in the grid that Ada was shown, in order, each once.
  defp places(ada, grid, acc \\ []) do
    receive do
      {Participant, ^ada, "aware", %{"states" => states}} ->
        at =
          Enum.find_value(Map.values(states), fn
            %{"state" => %{"place" => %{"doc" => ^grid, "at" => at}}} -> at
            _ -> nil
          end)

        places(ada, grid, if(at && at != List.first(acc), do: [at | acc], else: acc))
    after
      100 -> Enum.reverse(acc)
    end
  end

  test "selects a range as a drag does: only where it presses and lets go is sent",
       %{grid: grid, ada: ada, ctx: ctx} do
    range = %{"grid" => grid, "rows" => [1, 2], "keys" => ["name", "age"]}

    {:ok, _} = call("select_cells", range, ctx)

    assert places(ada, grid) == [
             %{"cell" => [1, "name"]},
             %{"range" => %{"rows" => [1, 2], "keys" => ["name", "age"]}}
           ]

    Application.put_env(
      :masu,
      Masu.Issho,
      Keyword.put(Application.get_env(:masu, Masu.Issho), :travel, false)
    )

    {:ok, _} = call("select_cells", %{range | "keys" => ["name"]}, ctx)
    assert places(ada, grid) == [%{"range" => %{"rows" => [1, 2], "keys" => ["name"]}}]
  end

  test "edits cells: a grid open in a LiveView shows them, and the grid's rules hold",
       %{grid: grid, topic: topic, ctx: ctx} do
    {:ok, view, _html} = live(build_conn(), "/sheet/#{topic}")

    assert {:ok,
            %{
              "saved" => 1,
              "errors" => [
                %{"row" => 1, "key" => "city", "error" => "This cell cannot be edited."}
              ]
            }} =
             call(
               "edit_cells",
               %{
                 "grid" => grid,
                 "edits" => [
                   %{"row" => 1, "key" => "name", "value" => "Ada King"},
                   %{"row" => 1, "key" => "city", "value" => "Paris"}
                 ]
               },
               ctx
             )

    assert view |> rows("people") |> hd() |> Map.fetch!("name") == "Ada King"

    assert {:error, "Nothing saved: Row 2, age: must be less than 150"} =
             call(
               "edit_cells",
               %{"grid" => grid, "edits" => [%{"row" => 2, "key" => "age", "value" => 900}]},
               ctx
             )

    assert {:error, "Nothing saved: Row 1, name: " <> rest} =
             call(
               "edit_cells",
               %{
                 "grid" => grid,
                 "edits" => [
                   %{"row" => 1, "key" => "name", "value" => "Ada", "before" => "Countess"}
                 ]
               },
               ctx
             )

    assert rest =~ ~s(now "Ada Lovelace")
  end

  test "leaves a cell someone is editing", %{grid: grid, ada: ada, ctx: ctx} do
    :ok = Participant.lock(ada, [Masu.Issho.place(grid, {1, "name"})])

    assert {:error, "Nothing saved: Row 1, name: Ada is editing this cell."} =
             call(
               "edit_cells",
               %{"grid" => grid, "edits" => [%{"row" => 1, "key" => "name", "value" => "X"}]},
               ctx
             )
  end

  test "writes only where the room's policy lets the agent write", %{
    instance: instance,
    grid: grid
  } do
    reader = Context.new(instance, %{id: "agent:reader", name: "Reader", kind: :agent})
    assert {:ok, _} = call("read_grid", %{"grid" => grid}, reader)

    assert {:error, "The room's policy does not allow this."} =
             call(
               "edit_cells",
               %{"grid" => grid, "edits" => [%{"row" => 1, "key" => "name", "value" => "X"}]},
               reader
             )
  end

  test "a grid that neither adds nor deletes says so", %{grid: grid, ctx: ctx} do
    assert {:error, "This grid does not add rows."} =
             call("add_rows", %{"grid" => grid, "rows" => [%{"name" => "Grace"}]}, ctx)

    assert {:error, "Row 1: This grid does not delete rows."} =
             call("delete_rows", %{"grid" => grid, "rows" => [1]}, ctx)
  end

  test "a grid is named in its room", %{room: room, ctx: ctx} do
    assert {:error, "Name a grid as room/grid" <> _} = call("read_grid", %{"grid" => room}, ctx)
  end

  test "adds and deletes rows", %{room: room, ctx: ctx} do
    grid = room <> "/open"

    assert {:ok,
            %{
              "rows" => [
                %{"id" => id},
                %{"errors" => [%{"key" => "name", "error" => "can't be blank"}]}
              ]
            }} =
             call(
               "add_rows",
               %{"grid" => grid, "rows" => [%{"name" => "Grace", "age" => 85}, %{"age" => 3}]},
               ctx
             )

    assert is_integer(id)

    assert {:ok, %{"deleted" => 1, "errors" => []}} =
             call("delete_rows", %{"grid" => grid, "rows" => [1]}, ctx)
  end
end

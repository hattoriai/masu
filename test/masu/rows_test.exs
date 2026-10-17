defmodule Masu.RowsTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Masu.Test

  alias MasuTest.{Repo, Task}

  @endpoint MasuTest.Endpoint

  setup do
    Repo.delete_all(Task)
    {:ok, conn: build_conn()}
  end

  defp config_of(view, id) do
    [json] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("##{id}")
      |> LazyHTML.attribute("data-masu")

    JSON.decode!(json)
  end

  describe "a grid of an Ecto schema" do
    test "says what it does, and an Ecto.Enum's values", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/rows/tasks")
      config = config_of(view, "tasks")
      assert %{"creates" => true, "deletes" => true, "restores" => true} = config

      [title, status, points] = config["columns"]
      assert title["creatable"]
      assert status["values"] == ["todo", "doing", "done"]
      assert points["decimals"] == 1
    end

    test "adds a row through its changeset of its struct", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/rows/tasks")

      assert {:ok, [id]} = add_rows(view, "tasks", %{title: "Write", points: "3"})
      assert [%{"title" => "Write", "status" => "todo", "points" => "3"}] = rows(view, "tasks")
      assert ids(view, "tasks") == [id]
      assert %Task{title: "Write", status: :todo} = Repo.get!(Task, id)
      assert view |> element("#log") |> render() =~ "saved Write"
    end

    test "puts a new row's errors on its cells, and saves the others", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/rows/tasks")

      assert {:error, [{:error, errors}, {:ok, _id}]} =
               add_rows(view, "tasks", [%{points: "-1"}, %{title: "Fine"}])

      assert {"title", "can't be blank"} in errors
      assert {"points", "must be greater than or equal to 0"} in errors
      assert total(view, "tasks") == 1
    end

    test "deletes rows, and brings them back", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/rows/tasks")
      {:ok, [a, b]} = add_rows(view, "tasks", [%{title: "A"}, %{title: "B"}])

      assert {:ok, undo} = delete_rows(view, "tasks", [a])
      assert ids(view, "tasks") == [b]
      assert Repo.get(Task, a) == nil
      assert view |> element("#log") |> render() =~ "deleted A"

      assert {:ok, [^a]} = restore_rows(view, "tasks", undo)
      assert ids(view, "tasks") == [a, b]
      assert %Task{title: "A"} = Repo.get!(Task, a)
      assert {:error, _gone} = restore_rows(view, "tasks", undo)
    end

    test "deletes only the rows it may", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/rows/tasks")
      {:ok, [a, b]} = add_rows(view, "tasks", [%{title: "A", status: "done"}, %{title: "B"}])

      assert {:error, [{^a, "This row cannot be deleted."}], undo} =
               delete_rows(view, "tasks", [a, b])

      assert is_binary(undo)
      assert ids(view, "tasks") == [a]

      assert {:error, [{999_999, "This row is not in the grid."}], nil} =
               delete_rows(view, "tasks", [999_999])
    end

    test "deletes the rows selected, and they leave the selection", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/rows/tasks")
      {:ok, [a, b, c]} = add_rows(view, "tasks", [%{title: "A"}, %{title: "B"}, %{title: "C"}])

      select(view, "tasks", [a, c])
      assert {:ok, _undo} = delete_rows(view, "tasks", :selection)
      assert ids(view, "tasks") == [b]
      assert selection(view, "tasks").count == 0

      select_all(view, "tasks")
      assert {:ok, _undo} = delete_rows(view, "tasks", :selection)
      assert total(view, "tasks") == 0
    end

    test "new and deleted rows go to the others on the topic", %{conn: conn} do
      {:ok, mine, _html} = live(conn, "/rows/tasks")
      {:ok, theirs, _html} = live(build_conn(), "/rows/tasks")

      {:ok, [id]} = add_rows(mine, "tasks", %{title: "Shared"})
      assert ids(theirs, "tasks") == [id]

      {:ok, _undo} = delete_rows(mine, "tasks", [id])
      assert ids(theirs, "tasks") == []
    end
  end

  describe "a grid of a list" do
    test "adds rows with its changeset and struct, and only in the cells that take a value",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/rows/people")
      before = total(view, "people")

      assert {:ok, [id]} = add_rows(view, "people", %{name: "Hedy Lamarr", age: "40"})
      assert id > 1000
      assert total(view, "people") == before + 1

      assert {:error, [{:error, [{"city", "This cell cannot be set."}]}]} =
               add_rows(view, "people", %{name: "X", city: "Paris"})

      assert {:error, [{:error, [{"name", "can't be blank"}]}]} =
               add_rows(view, "people", %{age: "3"})
    end

    test "deletes rows from its copy, and brings them back", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/rows/people")
      [first | rest] = ids(view, "people")

      assert {:ok, undo} = delete_rows(view, "people", [first])
      assert ids(view, "people") == rest
      assert {:ok, [^first]} = restore_rows(view, "people", undo)
      assert ids(view, "people") == [first | rest]
    end
  end

  describe "a grid with functions of its own" do
    test "adds and deletes through them; a delete it cannot undo has no token", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/rows/things")

      assert %{"creates" => true, "deletes" => true, "restores" => false} =
               config_of(view, "things")

      assert {:ok, [_id]} = add_rows(view, "things", %{name: "Two"})

      assert {:error, [{:error, [{nil, "Not that name."}]}]} =
               add_rows(view, "things", %{name: "nope"})

      assert {:error, [{2, "Kept."}], nil} = delete_rows(view, "things", [2])
      assert {:ok, nil} = delete_rows(view, "things", [1])
      assert "One" not in Enum.map(rows(view, "things"), & &1["name"])
    end
  end

  test "a grid that does not add or delete rows refuses to", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/edit/people")
    assert %{"creates" => false, "deletes" => false} = config_of(view, "people")

    assert_raise ExUnit.AssertionError, ~r/did not add rows/, fn ->
      add_rows(view, "people", %{name: "X"})
    end

    assert_raise ExUnit.AssertionError, ~r/did not delete/, fn ->
      delete_rows(view, "people", [1])
    end
  end
end

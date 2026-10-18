defmodule Masu.ChoresTest do
  # The chores' table is this module's own: its tests run one at a time.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Masu.Test

  @endpoint MasuTest.Endpoint

  setup do
    MasuTest.Chore.reset!()
    :ok
  end

  defp text(view, selector) do
    view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()
  end

  defp done(view), do: view |> rows("chores") |> Map.new(&{&1["title"], &1["done"]})

  # The event the browser sends, without Masu.Test's checks.
  defp push(view, payload) do
    view |> element("#chores") |> render_hook("masu:action", payload)
    %{proxy: {ref, _topic, _pid}} = view
    assert_receive {^ref, {:reply, reply}}
    reply
  end

  describe "actions on the rows selected" do
    test "are offered while rows are selected, as :if says" do
      {:ok, view, _html} = live(build_conn(), "/chores")
      assert actions(view, "chores", :selection) == []

      select(view, "chores", [2])
      assert actions(view, "chores", :selection) == ["Done", "Later", "Fail"]

      {:ok, admin, _html} = live(build_conn(), "/chores?admin=true")
      select(admin, "chores", [2])
      assert actions(admin, "chores", :selection) == ["Done", "Remove", "Later", "Fail"]
    end

    test "get the ids selected and the scope; the rows are read again, and the selection cleared" do
      {:ok, view, _html} = live(build_conn(), "/chores")
      select(view, "chores", [2, 3])

      assert action(view, "chores", "Done") == {:ok, "2 done by ada"}

      assert done(view) == %{
               "Dishes" => true,
               "Laundry" => true,
               "Floors" => true,
               "Windows" => false
             }

      assert selection(view, "chores").count == 0
    end

    test "get the query of every row selected, less the rows taken out of it" do
      {:ok, view, _html} = live(build_conn(), "/chores?admin=true")
      view |> select_all("chores") |> select("chores", [4], false)

      assert action(view, "chores", "Remove") == {:ok, "3 removed"}
      assert ids(view, "chores") == [4]
      assert total(view, "chores") == 1
    end

    test "that fail keep the selection" do
      {:ok, view, _html} = live(build_conn(), "/chores")
      select(view, "chores", [2])
      assert action(view, "chores", "Fail") == {:error, "Not now."}
      assert selection(view, "chores").count == 1
    end

    test "that go on later reply, from any process, and say how far they are" do
      {:ok, view, _html} = live(build_conn(), "/chores")
      select(view, "chores", [2, 3])

      assert action(view, "chores", "Later") == :async
      # keep_selection: the selection stays.
      assert selection(view, "chores").count == 2
      ref = text(view, "#ref")

      Task.async(fn -> Masu.progress(ref, 1, 2) end) |> Task.await()
      assert_push_event(view, "masu:progress", %{"id" => "chores", "done" => 1, "total" => 2})

      Task.async(fn -> Masu.reply(ref, {:ok, "Both later"}) end) |> Task.await()

      assert_push_event(view, "masu:reply", %{
        "id" => "chores",
        "ok" => true,
        "message" => "Both later",
        "errors" => []
      })

      # Replied once: a second reply goes nowhere.
      Masu.reply(ref, :ok)
      refute_push_event(view, "masu:reply", _payload, 50)
    end

    test "the server refuses: none selected, one the grid does not offer, a label that is not its" do
      {:ok, view, _html} = live(build_conn(), "/chores")
      assert action(view, "chores", "Done") == {:error, :refused}

      select(view, "chores", [2])
      assert action(view, "chores", "Remove") == {:error, :refused}

      assert push(view, %{"kind" => "selection", "action" => 0, "label" => "Remove"}) == %{
               "error" => "action"
             }

      assert done(view)["Laundry"] == false
    end
  end

  describe "actions on a row" do
    test "each row shows its own, available or not; a link goes to its path" do
      {:ok, view, _html} = live(build_conn(), "/chores")
      assert actions(view, "chores", :row, 1) == ["Open", "Undo", "Peek"]
      assert actions(view, "chores", :row, 2) == ["Open", "Undo"]
      assert row_action(view, "chores", "Open", 3) == {:navigate, "/chores/3"}
    end

    test "run with the row read from the source; the rows are read again" do
      {:ok, view, _html} = live(build_conn(), "/chores")
      assert row_action(view, "chores", "Undo", 1) == :ok
      assert done(view)["Dishes"] == false
    end

    test "an event goes to the LiveView, with the row and the scope" do
      {:ok, view, _html} = live(build_conn(), "/chores")
      assert row_action(view, "chores", "Peek", 1) == :ok
      assert text(view, "#heard") == "peek Dishes by ada"
    end

    test "the server refuses: disabled for the row, not on it, a row that is not there" do
      {:ok, view, _html} = live(build_conn(), "/chores")
      # Undo is disabled for a chore not done.
      assert row_action(view, "chores", "Undo", 2) == {:error, :refused}
      assert row_action(view, "chores", "Peek", 2) == {:error, :refused}
      # A link runs nothing on the server.
      assert push(view, %{"kind" => "row", "action" => 0, "id" => 1}) == %{"error" => "action"}
      assert push(view, %{"kind" => "row", "action" => 1, "id" => 99}) == %{"error" => "row"}
      refute has_element?(view, "#heard")
    end
  end

  describe "declaring" do
    import Phoenix.Component, only: [sigil_H: 2]
    import Masu.Components

    test "an action on the selection needs selectable; a row action is a link or runs" do
      assigns = %{rows: [%{id: 1, name: "a"}]}

      assert_raise ArgumentError, ~r/needs selectable/, fn ->
        rendered_to_string(~H"""
        <.data_grid id="g" rows={@rows}>
          <:col field={:name} />
          <:action label="Archive" on_action={& &1} />
        </.data_grid>
        """)
      end

      assert_raise ArgumentError, ~r/is a link \(navigate or patch\) or runs/, fn ->
        Masu.Action.all([%{label: "Open", navigate: & &1, on_action: & &1}], :row)
      end

      assert_raise ArgumentError, ~r/acts on the rows selected/, fn ->
        Masu.Action.all([%{label: "Open", navigate: & &1}], :selection)
      end
    end
  end
end

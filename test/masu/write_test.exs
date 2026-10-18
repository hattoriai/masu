defmodule Masu.WriteTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Masu.Test

  alias Masu.Write
  alias Masu.Write.Change

  @endpoint MasuTest.Endpoint

  defp text(view, selector) do
    view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()
  end

  describe "a write in your own function" do
    test "knows the scope, the operation and what the person did" do
      {:ok, view, _html} = live(build_conn(), "/writes")

      assert edit(view, "things", [{1, :name, "Uno"}, {2, :name, "Dos"}], origin: :paste) == :ok
      assert text(view, "#heard") == "update paste by ada: 2"
      assert view |> rows("things") |> Enum.map(& &1["name"]) == ["Uno", "Dos"]

      assert {:ok, _undo} = delete_rows(view, "things", [2])
      assert text(view, "#heard") == "delete test by ada: 1"
    end

    test "saves a batch whole, or none of it" do
      {:ok, view, _html} = live(build_conn(), "/writes?mode=all")

      assert {:error, errors} = edit(view, "things", [{1, :name, "Uno"}, {2, :name, "nope"}])

      assert Enum.sort(errors) == [
               {1, "name", "Not saved: another row of the batch has an error."},
               {2, "name", "Not that name."}
             ]

      assert edit(view, "things", [{1, :name, "Uno"}, {2, :name, "Dos"}]) == :ok
      assert view |> rows("things") |> Enum.map(& &1["name"]) == ["Uno", "Dos"]
    end

    test "is saved later: the cells wait for the reply, which may refuse them" do
      {:ok, view, _html} = live(build_conn(), "/writes?mode=async")

      assert edit(view, "things", [{1, :name, "Uno"}]) == :async
      ref = text(view, "#ref")

      Task.async(fn -> Masu.reply(ref, {:error, "The ledger is closed."}) end) |> Task.await()

      assert_push_event(view, "masu:reply", %{
        "id" => "things",
        "ok" => false,
        "errors" => [[1, "name", "The ledger is closed."]]
      })

      assert delete_rows(view, "things", [2]) == :async
    end

    @tag :capture_log
    test "with a change left without a result is a mistake" do
      Process.flag(:trap_exit, true)
      {:ok, view, _html} = live(build_conn(), "/writes?mode=none")

      assert {{%ArgumentError{message: message}, _stack}, _call} =
               catch_exit(edit(view, "things", [{1, :name, "Uno"}]))

      assert message =~ "left 1 of its changes without a result"
    end
  end

  describe "results" do
    defp write(op, n) do
      changes = for i <- 0..(n - 1), do: %Change{index: i, id: i, row: %{id: i}}
      %Write{grid: "g", op: op, changes: changes}
    end

    test "each, one by one, and what is left" do
      write =
        :update
        |> write(3)
        |> then(&Write.ok(&1, Enum.at(&1.changes, 0), %{id: 0, saved: true}))
        |> Write.each(fn
          %{id: 1} -> {:error, "No."}
          change -> {:ok, change.row}
        end)

      assert Write.open(write) == []
      assert Write.saved(write) == [%{id: 0, saved: true}, %{id: 2}]
      assert [{%Change{id: 1}, "No."}] = Write.failed(write)
    end

    test "all: one result for the batch; a delete is :ok" do
      write = :update |> write(2) |> Write.all(fn _changes -> {:error, "Closed."} end)
      assert length(Write.failed(write)) == 2

      write = :delete |> write(2) |> Write.all(fn _changes -> :ok end)
      assert Write.saved(write) == [%{id: 0}, %{id: 1}]

      assert_raise ArgumentError, ~r/not \{:ok, rows\}/, fn ->
        :update |> write(2) |> Write.all(fn changes -> {:ok, Enum.take(changes, 1)} end)
      end
    end

    test "async: later, not for new rows" do
      write = :update |> write(2) |> Write.async()
      assert Write.open(write) == []
      assert Write.result(write, hd(write.changes)) == :pending

      assert_raise ArgumentError, ~r/need their ids at once/, fn ->
        :create |> write(1) |> Write.async()
      end
    end

    test "a ref is a ref" do
      assert_raise ArgumentError, ~r/not the ref/, fn -> Masu.reply("nope", :ok) end
    end
  end
end

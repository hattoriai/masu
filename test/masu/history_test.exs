defmodule Masu.HistoryTest do
  # The ledger's table, and the histories' tables, are this module's own.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Masu.Test

  alias Masu.History.{Entry, Memory}

  @endpoint MasuTest.Endpoint

  setup do
    MasuTest.Ledger.reset!()
    :ok
  end

  defp amounts(view), do: view |> rows("ledger") |> Enum.map(& &1["amount"])

  describe "recording" do
    test "an edit is an entry of its cell: before, after, who, what they did, its batch" do
      {:ok, view, _html} = live(build_conn(), "/ledger")
      assert edit(view, "ledger", [{1, :amount, "1250"}]) == :ok

      assert [entry] = history(view, "ledger", 1, :amount)

      assert %{
               key: "amount",
               op: :update,
               before: 1200,
               after: 1250,
               user: "Ada",
               origin: "test",
               batch_size: 1
             } = entry

      # In the rows' own repo.
      assert MasuTest.Repo.aggregate("masu_history", :count) == 1
    end

    test "a paste is one batch; a refused edit is not recorded" do
      {:ok, view, _html} = live(build_conn(), "/ledger")

      assert edit(view, "ledger", [{1, :amount, "1"}, {2, :amount, "2"}], origin: :paste) == :ok
      assert {:error, _} = edit(view, "ledger", [{3, :amount, "-5"}])

      [one] = history(view, "ledger", 1, :amount)
      [two] = history(view, "ledger", 2, :amount)
      assert one.batch == two.batch and one.batch_size == 2 and one.origin == "paste"
      assert history(view, "ledger", 3, :amount) == []
    end

    test "new rows and rows deleted are entries of their rows" do
      {:ok, view, _html} = live(build_conn(), "/ledger")
      assert {:ok, [id]} = add_rows(view, "ledger", %{item: "Gas", amount: "30"})
      assert {:ok, _undo} = delete_rows(view, "ledger", [2])

      assert [%{op: :create, key: nil, after: %{"item" => "Gas", "amount" => 30}}] =
               history(view, "ledger", id)

      # A row deleted is not in the grid: its history is the store's.
      assert history(view, "ledger", 2) == []

      assert [%Entry{op: :delete, before: %{"item" => "Power"}}] =
               MasuTest.SameHistory.for_row("ledger", 2)
    end

    @tag :capture_log
    test "in the row's transaction, when the history is in the rows' repo: no record, no change" do
      {:ok, view, _html} = live(build_conn(), "/ledger?store=broken")

      assert edit(view, "ledger", [{1, :amount, "9"}]) ==
               {:error, [{1, "amount", "Not saved: the history could not keep it."}]}

      assert MasuTest.Repo.get!(MasuTest.Ledger, 1).amount == 1200
    end

    test "in a repo of its own, after the row's transaction" do
      {:ok, view, _html} = live(build_conn(), "/ledger?store=other")
      assert edit(view, "ledger", [{1, :item, "Rent!"}]) == :ok

      assert [%{before: "Rent", after: "Rent!"}] = history(view, "ledger", 1, :item)
      assert MasuTest.Repo.aggregate("masu_history", :count) == 0
      assert MasuTest.HistoryRepo.aggregate("masu_history", :count) == 1
    end

    test "an on_update of the app's records in its own transaction, once" do
      {:ok, view, _html} = live(build_conn(), "/ledger?store=memory&own=true")
      assert edit(view, "ledger", [{1, :amount, "1300"}]) == :ok
      assert [%{before: 1200, after: 1300}] = history(view, "ledger", 1, :amount)
    end

    test "only of a row the grid's query shows" do
      :ok =
        Masu.History.record(Memory, [
          %{grid: "ledger", row_id: 99, key: :amount, before: 1, after: 2}
        ])

      {:ok, view, _html} = live(build_conn(), "/ledger?store=memory")
      assert history(view, "ledger", 99, :amount) == []
    end

    test "what the app changes another way, it records itself" do
      :ok =
        Masu.History.record(Memory, [
          %{
            grid: "ledger",
            row_id: 3,
            key: :amount,
            before: 40,
            after: 0,
            origin: :waive,
            user: %{id: 1, name: "Grace"}
          }
        ])

      assert [%Entry{user_name: "Grace", user_id: "1", origin: :waive}] =
               Memory.for_cell("ledger", 3, "amount")
    end
  end

  describe "restoring" do
    test "a value back: an edit, recorded as a restore" do
      {:ok, view, _html} = live(build_conn(), "/ledger")
      :ok = edit(view, "ledger", [{2, :amount, "95"}])
      :ok = edit(view, "ledger", [{2, :amount, "99"}])

      # The value before the first change, past the second.
      [_latest, first] = history(view, "ledger", 2, :amount)
      assert restore(view, "ledger", first.id) == {:ok, 1}
      assert Enum.at(amounts(view), 1) == 90

      assert [%{origin: "restore", before: 99, after: 90} | _] =
               history(view, "ledger", 2, :amount)

      # Someone else changed the cell since the history was read.
      [latest | _] = history(view, "ledger", 2, :amount)
      MasuTest.Repo.update_all(MasuTest.Ledger, set: [amount: 7])

      assert restore(view, "ledger", latest.id) ==
               {:error, [{2, "amount", "Changed by someone else meanwhile."}]}
    end

    test "a batch back, someone's paste undone; a cell changed since stays" do
      {:ok, view, _html} = live(build_conn(), "/ledger?store=other")

      :ok =
        edit(view, "ledger", [{1, :amount, "1"}, {2, :amount, "2"}, {3, :amount, "3"}],
          origin: :paste
        )

      :ok = edit(view, "ledger", [{3, :amount, "33"}])

      [%{batch: batch} | _] = history(view, "ledger", 1, :amount)

      assert restore(view, "ledger", {:batch, batch}) ==
               {:error, [{3, "amount", "Changed by someone else meanwhile."}]}

      assert amounts(view) == [1200, 90, 33]
    end
  end
end

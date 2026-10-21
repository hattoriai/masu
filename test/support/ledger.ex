defmodule MasuTest.HistoryRepo do
  @moduledoc "A SQLite repo of its own, for a history kept apart from the rows."
  use Ecto.Repo, otp_app: :masu, adapter: Ecto.Adapters.SQLite3
end

defmodule MasuTest.Ledger do
  @moduledoc "A line of a ledger, whose changes the history keeps."
  use Ecto.Schema

  import Ecto.Changeset

  alias Masu.History.Memory
  alias Mix.Tasks.Masu.Gen.History, as: GenHistory

  schema "ledger" do
    field(:item, :string)
    field(:amount, :integer)
  end

  def changeset(line, params) do
    line
    |> cast(params, [:item, :amount])
    |> validate_required([:item])
    |> validate_number(:amount, greater_than_or_equal_to: 0)
  end

  @doc "The ledger again: three lines."
  def reset! do
    MasuTest.Repo.delete_all(__MODULE__)

    for {item, amount, id} <- [{"Rent", 1200, 1}, {"Power", 90, 2}, {"Water", 40, 3}] do
      MasuTest.Repo.insert!(%__MODULE__{id: id, item: item, amount: amount})
    end

    Memory.clear()
    MasuTest.Repo.query!("DELETE FROM masu_history")
    MasuTest.HistoryRepo.query!("DELETE FROM masu_history")
    :ok
  end

  @doc "Runs the migration of `mix masu.gen.history` in a repo."
  def migrate_history!(repo) do
    dir = Path.join(System.tmp_dir!(), "masu-history-#{System.pid()}-#{inspect(repo)}")
    File.rm_rf!(dir)
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Quiet)
    GenHistory.write(dir, "masu_history", :masu_test, "20260101000000")
    Mix.shell(shell)
    # The same migration's module, for each repo.
    Code.put_compiler_option(:ignore_module_conflict, true)
    Ecto.Migrator.run(repo, dir, :up, all: true, log: false)
    Code.put_compiler_option(:ignore_module_conflict, false)
    File.rm_rf!(dir)
    :ok
  end

  @doc "The history's repo of its own, with its table."
  def start_history_repo! do
    path = Path.join(System.tmp_dir!(), "masu-history-#{System.pid()}.db")
    File.rm(path)
    System.at_exit(fn _status -> File.rm(path) end)
    {:ok, _pid} = MasuTest.HistoryRepo.start_link(database: path, pool_size: 1)
    migrate_history!(MasuTest.HistoryRepo)
  end
end

defmodule MasuTest.SameHistory do
  @moduledoc "A history in the rows' own repo: recorded in the row's transaction."
  use Masu.History.Ecto, repo: MasuTest.Repo
end

defmodule MasuTest.OtherHistory do
  @moduledoc "A history in a repo of its own: recorded after the row's transaction."
  use Masu.History.Ecto, repo: MasuTest.HistoryRepo
end

defmodule MasuTest.StrictHistory do
  @moduledoc "The memory history, which raises on a NUL in any text, as PostgreSQL does."
  @behaviour Masu.History

  alias Masu.History.Memory

  @impl true
  def record(entries), do: Memory.record(entries)
  @impl true
  def for_cell(grid, row_id, key, opts),
    do: Memory.for_cell(strict(grid), row_id, strict(key), opts)

  @impl true
  def for_row(grid, row_id, opts), do: Memory.for_row(strict(grid), row_id, opts)
  @impl true
  def recent(grid, opts), do: Memory.recent(strict(grid), opts)
  @impl true
  def batch(grid, batch), do: Memory.batch(strict(grid), strict(batch))
  @impl true
  def entry(grid, id), do: Memory.entry(strict(grid), id)
  @impl true
  def repo, do: nil

  defp strict(text) do
    if String.contains?(text, <<0>>), do: raise("invalid byte sequence: 0x00"), else: text
  end
end

defmodule MasuTest.BrokenHistory do
  @moduledoc "A history in the rows' repo that cannot record: the change does not save either."
  @behaviour Masu.History

  @impl true
  def record(_entries), do: raise("the history is down")
  @impl true
  def for_cell(_grid, _row_id, _key, _opts), do: []
  @impl true
  def for_row(_grid, _row_id, _opts), do: []
  @impl true
  def recent(_grid, _opts), do: []
  @impl true
  def batch(_grid, _batch), do: []
  @impl true
  def entry(_grid, _id), do: nil
  @impl true
  def repo, do: MasuTest.Repo
end

defmodule MasuTest.LedgerLive do
  @moduledoc """
  A ledger whose changes the history keeps, by `?store=`: the rows' own
  repo (`same`), a repo of its own (`other`), memory (`memory`), or one
  that cannot record (`broken`). With `?own=true`, its on_update saves its
  own way and records in its transaction (Masu.Write.record/3).
  """
  use Phoenix.LiveView

  import Masu.Components

  @stores %{
    "same" => MasuTest.SameHistory,
    "other" => MasuTest.OtherHistory,
    "memory" => Masu.History.Memory,
    "broken" => MasuTest.BrokenHistory,
    "strict" => MasuTest.StrictHistory
  }

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     assign(socket,
       store: Map.fetch!(@stores, params["store"] || "same"),
       own: params["own"] == "true",
       user: %{id: 7, name: "Ada"}
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.data_grid
      id="ledger"
      source={MasuTest.Ledger}
      repo={MasuTest.Repo}
      changeset={&MasuTest.Ledger.changeset/2}
      struct={%MasuTest.Ledger{}}
      deletable
      history={@store}
      user={@user}
      on_update={if @own, do: &own_update/1}
      sort={[:id]}
    >
      <:col field={:item} />
      <:col field={:amount} type={:integer} />
    </.data_grid>
    """
  end

  # Each line in a transaction of its own, which records it.
  defp own_update(write) do
    Enum.reduce(write.changes, write, fn change, write ->
      {:ok, write} =
        MasuTest.Repo.transaction(fn ->
          line = change.row |> MasuTest.Ledger.changeset(change.params) |> MasuTest.Repo.update!()
          write |> Masu.Write.ok(change, line) |> Masu.Write.record(change, line)
        end)

      write
    end)
  end
end

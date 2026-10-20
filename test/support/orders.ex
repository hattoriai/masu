defmodule MasuTest.Repo do
  @moduledoc "A SQLite repository for the tests of `Masu.Source.Ecto`."
  use Ecto.Repo, otp_app: :masu, adapter: Ecto.Adapters.SQLite3
end

defmodule MasuTest.Order do
  @moduledoc "An order, stored in SQLite."
  use Ecto.Schema

  schema "orders" do
    field :number, :string
    field :customer, :string
    field :status, :string
    field :total, :decimal
    field :placed_on, :date
  end

  import Ecto.Changeset

  def changeset(order, params) do
    order
    |> cast(params, [:customer, :status, :total, :placed_on])
    |> validate_required([:customer])
    |> validate_inclusion(:status, ~w(draft paid late void))
    |> validate_number(:total, greater_than_or_equal_to: 0)
  end
end

defmodule MasuTest.OrdersLive do
  @moduledoc "A LiveView with a grid of an Ecto schema, for the tests."
  use Phoenix.LiveView

  import Ecto.Query
  import Masu.Components

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.data_grid
      id="orders"
      source={from(o in MasuTest.Order, where: o.status != "void")}
      repo={MasuTest.Repo}
      label="Orders"
    >
      <:col field={:number} />
      <:col field={:customer} />
      <:col field={:status} type={:enum} />
      <:col field={:total} type={:decimal} />
      <:col field={:placed_on} type={:date} />
      <:col key="code" value={&String.downcase(&1.number)} />
    </.data_grid>
    """
  end
end

defmodule MasuTest.Orders do
  @moduledoc "Starts the SQLite repo once, with six orders."

  alias MasuTest.{Order, Repo}

  def setup! do
    if Process.whereis(Repo) do
      :ok
    else
      # A file of this run's own, deleted before and after it: an earlier
      # run's file must not give its table to this one.
      path = Path.join(System.tmp_dir!(), "masu-test-#{System.pid()}.db")
      File.rm(path)
      System.at_exit(fn _status -> File.rm(path) end)
      {:ok, _pid} = Repo.start_link(database: path, pool_size: 1)

      Repo.query!("""
      CREATE TABLE orders (
        id INTEGER PRIMARY KEY, number TEXT, customer TEXT, status TEXT, total DECIMAL, placed_on TEXT
      )
      """)

      # The table of Masu.Views.Ecto, as `mix masu.gen.views` makes it.
      Repo.query!("""
      CREATE TABLE masu_views (
        id INTEGER PRIMARY KEY, grid TEXT NOT NULL, owner TEXT NOT NULL, name TEXT,
        shared BOOLEAN NOT NULL DEFAULT FALSE, params TEXT NOT NULL,
        inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL
      )
      """)

      :ok = MasuTest.Accounts.setup!(Repo)

      # Tasks that a grid adds and deletes (Masu.Edit), of their own.
      Repo.query!(
        "CREATE TABLE tasks (id INTEGER PRIMARY KEY, title TEXT NOT NULL, status TEXT, points DECIMAL)"
      )

      # A ledger whose changes the history keeps (Masu.History), of its own;
      # the history's table in this repo and in a repo of its own, by the
      # migration of `mix masu.gen.history`.
      Repo.query!("CREATE TABLE ledger (id INTEGER PRIMARY KEY, item TEXT, amount INTEGER)")
      :ok = MasuTest.Ledger.migrate_history!(Repo)
      :ok = MasuTest.Ledger.start_history_repo!()

      # Chores that the actions of a grid change (Masu.Action), of their own.
      Repo.query!("CREATE TABLE chores (id INTEGER PRIMARY KEY, title TEXT, done BOOLEAN)")

      # Items with empty values and repeated ones, for paging by key.
      Repo.query!("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT, score INTEGER)")

      for id <- 1..237, do: Repo.insert!(item(id))

      # Sales of customers of companies, with tags and lines: columns of
      # related rows (Masu.Column paths).
      :ok = MasuTest.Sales.setup!(Repo)

      for {number, customer, status, total, day} <- [
            {"A-1", "Acme", "paid", "10.00", 1},
            {"A-2", "Bob's", "late", "250.50", 2},
            {"A-3", "Cyd", "paid", "9.99", 3},
            {"A-4", "acme corp", "paid", "120.00", 4},
            {"A-5", "Zed 100%", "draft", "999.00", 5},
            {"A-6", "Void Inc", "void", "50.00", 6}
          ] do
        Repo.insert!(%Order{
          number: number,
          customer: customer,
          status: status,
          total: Decimal.new(total),
          placed_on: Date.new!(2026, 1, day)
        })
      end

      :ok
    end
  end

  defp item(id) do
    name = if rem(id, 7) == 0, do: nil, else: "item #{rem(id * 31, 40)}"
    score = if rem(id, 5) == 0, do: nil, else: rem(id * 13, 9)
    struct(MasuTest.Item, id: id, name: name, score: score)
  end
end

defmodule MasuTest.Item do
  @moduledoc "An item with empty and repeated values: paging by key."
  use Ecto.Schema

  schema "items" do
    field(:name, :string)
    field(:score, :integer)
  end
end

defmodule MasuTest.Task do
  @moduledoc "A task, which a grid adds and deletes."
  use Ecto.Schema

  import Ecto.Changeset

  schema "tasks" do
    field(:title, :string)
    field(:status, Ecto.Enum, values: [:todo, :doing, :done])
    field(:points, :decimal)
  end

  def changeset(task, params) do
    task
    |> cast(params, [:title, :status, :points])
    |> validate_required([:title])
    |> validate_number(:points, greater_than_or_equal_to: 0)
  end
end

defmodule MasuTest.Chore do
  @moduledoc "A chore, which the actions of a grid change."
  use Ecto.Schema

  schema "chores" do
    field(:title, :string)
    field(:done, :boolean, default: false)
  end

  @doc "The chores again: four, the first done."
  def reset! do
    MasuTest.Repo.delete_all(__MODULE__)

    for {title, id} <- Enum.with_index(~w(Dishes Laundry Floors Windows), 1) do
      MasuTest.Repo.insert!(%__MODULE__{id: id, title: title, done: id == 1})
    end

    :ok
  end
end

defmodule MasuTest.OtherRepo do
  @moduledoc "The test repo, as a repo of an adapter whose order of NULLs Masu does not know."
  def __adapter__, do: MasuTest.OtherAdapter
  defdelegate all(query, opts), to: MasuTest.Repo
  defdelegate one(query, opts), to: MasuTest.Repo
end

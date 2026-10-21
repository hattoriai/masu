defmodule MasuTest.Repo do
  @moduledoc "The repository of the tests of `Masu.Source.Ecto`: SQLite, PostgreSQL or MySQL by MASU_DB."
  use Ecto.Repo, otp_app: :masu, adapter: MasuTest.DB.adapter()

  def __mix_recompile__?, do: MasuTest.DB.adapter() != __adapter__()
end

defmodule MasuTest.Order do
  @moduledoc "An order, stored in the test repo."
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
  @moduledoc "Starts the test repo once, with its tables and six orders."

  alias MasuTest.{Order, Repo}

  def setup! do
    if Process.whereis(Repo) do
      :ok
    else
      :ok = MasuTest.DB.start!(Repo)
      :ok = Ecto.Migrator.up(Repo, 1, MasuTest.Tables, log: false)

      # The table of Masu.Views.Ecto, by the migration of `mix masu.gen.views`.
      :ok = MasuTest.DB.generated!(Repo, Mix.Tasks.Masu.Gen.Views, "masu_views", "20260101000001")

      :ok = MasuTest.Accounts.setup!(Repo)

      # The history's table in this repo and in a repo of its own, by the
      # migration of `mix masu.gen.history`.
      :ok = MasuTest.Ledger.migrate_history!(Repo)
      :ok = MasuTest.Ledger.start_history_repo!()

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

      for table <- ~w(orders items companies customers sales tags sale_lines),
          do: MasuTest.DB.reset_ids!(Repo, table)

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

    MasuTest.DB.reset_ids!(MasuTest.Repo, "chores")
  end
end

defmodule MasuTest.OtherRepo do
  @moduledoc "The test repo, as a repo of an adapter whose order of NULLs Masu does not know."
  def __adapter__, do: MasuTest.OtherAdapter
  defdelegate all(query, opts), to: MasuTest.Repo
  defdelegate one(query, opts), to: MasuTest.Repo
end

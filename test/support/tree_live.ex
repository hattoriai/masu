defmodule MasuTest.Account do
  @moduledoc "An account of a chart of accounts: a tree by parent_id."
  use Ecto.Schema

  schema "accounts" do
    field(:parent_id, :integer)
    field(:name, :string)
    field(:balance, :decimal)
  end

  def changeset(account, params), do: Ecto.Changeset.cast(account, params, [:name, :balance])
end

defmodule MasuTest.Accounts do
  @moduledoc "The chart of accounts of the tree tests, as a list and as a table."

  alias MasuTest.Account

  def all do
    [
      %Account{id: 1, parent_id: nil, name: "Assets", balance: nil},
      %Account{id: 2, parent_id: 1, name: "Cash", balance: Decimal.new("100")},
      %Account{id: 3, parent_id: 1, name: "Bank", balance: nil},
      %Account{id: 4, parent_id: 3, name: "Checking", balance: Decimal.new("500")},
      %Account{id: 5, parent_id: 3, name: "Savings", balance: Decimal.new("1500")},
      %Account{id: 6, parent_id: nil, name: "Liabilities", balance: nil},
      %Account{id: 7, parent_id: 6, name: "Loans", balance: Decimal.new("300")},
      %Account{id: 8, parent_id: nil, name: "Equity", balance: nil}
    ]
  end

  def setup!(repo) do
    repo.query!("""
    CREATE TABLE accounts (id INTEGER PRIMARY KEY, parent_id INTEGER, name TEXT, balance DECIMAL)
    """)

    for account <- all(), do: repo.insert!(account)
    :ok
  end
end

defmodule MasuTest.TreeLive do
  @moduledoc "A chart of accounts in a tree: a list, or the SQLite table with `?source=ecto`."
  use Phoenix.LiveView

  import Masu.Components

  on_mount(Masu.Live)

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     assign(socket,
       ecto: params["source"] == "ecto",
       expanded: if(params["open"], do: [String.to_integer(params["open"])], else: [])
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%= if @ecto do %>
      <.data_grid
        id="accounts"
        source={MasuTest.Account}
        repo={MasuTest.Repo}
        tree={:parent_id}
        expanded={@expanded}
        changeset={&MasuTest.Account.changeset/2}
        live={{MasuTest.PubSub, "tree-accounts-ecto"}}
        sort={[:id]}
      >
        <:col field={:name} />
        <:col field={:balance} type={:decimal} />
      </.data_grid>
    <% else %>
      <.data_grid
        id="accounts"
        rows={MasuTest.Accounts.all()}
        tree={:parent_id}
        expanded={@expanded}
        changeset={&MasuTest.Account.changeset/2}
        live={{MasuTest.PubSub, "tree-accounts"}}
      >
        <:col field={:name} />
        <:col field={:balance} type={:decimal} />
      </.data_grid>
    <% end %>
    """
  end
end

defmodule MasuTest.DetailsLive do
  @moduledoc "People whose rows open on a detail: a text and a grid of their own."
  use Phoenix.LiveView

  import Masu.Components

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  def skills(person) do
    for {skill, i} <- Enum.with_index(["Math", "Logic", "Code"], 1),
        do: %{id: person.id * 10 + i, skill: skill, years: person.age - i}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.data_grid id="people" rows={MasuTest.People.all()} sort={[:id]}>
      <:col field={:name} />
      <:col field={:city} />
      <:detail :let={person}>
        <p class="bio">{person.name} lives in {person.city || "no city"}.</p>
        <.data_grid id={"skills-#{person.id}"} rows={skills(person)} height="10rem">
          <:col field={:skill} />
          <:col field={:years} type={:integer} />
        </.data_grid>
      </:detail>
    </.data_grid>
    """
  end
end

defmodule MasuTest.EditPeopleLive do
  @moduledoc "A grid of a list that edits, with a schemaless changeset."
  use Phoenix.LiveView

  import Ecto.Changeset
  import Masu.Components

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, people: MasuTest.People.all())}

  @impl true
  def render(assigns) do
    ~H"""
    <.data_grid id="people" rows={@people} changeset={&changeset/2} sort={[:id]}>
      <:col field={:name} />
      <:col field={:age} type={:integer} />
      <:col field={:city} editable={false} />
      <:col key="initials" value={&String.first(&1.name)} />
    </.data_grid>
    """
  end

  def changeset(person, params) do
    types = %{name: :string, age: :integer}

    {person, types}
    |> cast(params, Map.keys(types))
    |> validate_required([:name])
    |> validate_number(:age, greater_than: 0, less_than: 150)
  end
end

defmodule MasuTest.EditOrdersLive do
  @moduledoc "A grid of an Ecto schema that edits, and follows a topic."
  use Phoenix.LiveView

  import Ecto.Query
  import Masu.Components

  on_mount(Masu.Live)

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.data_grid
      id="orders"
      source={from(o in MasuTest.Order, where: o.status != "void")}
      repo={MasuTest.Repo}
      changeset={&MasuTest.Order.changeset/2}
      live={{MasuTest.PubSub, "edit-orders"}}
    >
      <:col field={:number} editable={false} />
      <:col field={:customer} />
      <:col field={:status} type={:enum} />
      <:col field={:total} type={:decimal} />
    </.data_grid>
    """
  end
end

defmodule MasuTest.UpdateLive do
  @moduledoc "A grid that saves with an on_update of its own, row by row."
  use Phoenix.LiveView

  import Masu.Components

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, rows: [%{id: 1, name: "One"}])}

  @impl true
  def render(assigns) do
    ~H"""
    <.data_grid id="things" rows={@rows} on_update={&save/1}>
      <:col field={:name} />
    </.data_grid>
    """
  end

  defp save(write), do: Masu.Write.each(write, &save_row(&1.row, &1.params))

  defp save_row(_row, %{"name" => "nope"}), do: {:error, "Not that name."}
  defp save_row(row, %{"name" => name}), do: {:ok, %{row | name: String.upcase(name)}}
end

defmodule MasuTest.LockedLive do
  @moduledoc "A grid with read-only rows and cells, that tells its LiveView what it saved."
  use Phoenix.LiveView

  import Masu.Components

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, people: MasuTest.People.all(), saved: [])}

  @impl true
  def render(assigns) do
    ~H"""
    <.data_grid
      id="people"
      rows={@people}
      changeset={&MasuTest.EditPeopleLive.changeset/2}
      row_editable={&(&1.id != 1)}
      on_update={&save/1}
      sort={[:id]}
    >
      <:col field={:name} />
      <:col field={:age} type={:integer} editable={&(&1.age < 80)} />
    </.data_grid>
    <p id="saved">{Enum.join(@saved, ", ")}</p>
    """
  end

  # The grid's own way, then the LiveView hears of what was saved.
  defp save(write) do
    write |> Masu.Write.save() |> tap(&send(self(), {:saved, Masu.Write.saved(&1)}))
  end

  @impl true
  def handle_info({:saved, rows}, socket),
    do: {:noreply, update(socket, :saved, &(&1 ++ Enum.map(rows, fn row -> row.name end)))}
end

defmodule MasuTest.SheetLive do
  @moduledoc "A grid of a definition that a Masu.Sheet shares: its attributes, given at once."
  use Phoenix.LiveView

  import Masu.Components

  on_mount(Masu.Live)

  def grid(topic) do
    [
      id: "people",
      rows: MasuTest.People.all(),
      changeset: &MasuTest.EditPeopleLive.changeset/2,
      live: {MasuTest.PubSub, topic},
      columns: [[field: :name], [field: :age, type: :integer], [field: :city, editable: false]]
    ]
  end

  @impl true
  def mount(%{"topic" => topic}, _session, socket), do: {:ok, assign(socket, grid: grid(topic))}

  @impl true
  def render(assigns) do
    ~H"""
    <.data_grid {@grid} label="People" />
    """
  end
end

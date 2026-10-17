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
  @moduledoc "A grid that saves with an update function of its own."
  use Phoenix.LiveView

  import Masu.Components

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, rows: [%{id: 1, name: "One"}])}

  @impl true
  def render(assigns) do
    ~H"""
    <.data_grid id="things" rows={@rows} update={&update/2}>
      <:col field={:name} />
    </.data_grid>
    """
  end

  defp update(_row, %{"name" => "nope"}), do: {:error, "Not that name."}
  defp update(row, %{"name" => name}), do: {:ok, %{row | name: String.upcase(name)}}
end

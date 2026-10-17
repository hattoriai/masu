defmodule MasuTest.TasksLive do
  @moduledoc "A grid of an Ecto schema that adds and deletes rows, and tells its LiveView."
  use Phoenix.LiveView

  import Masu.Components

  on_mount(Masu.Live)

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, log: [])}

  @impl true
  def render(assigns) do
    ~H"""
    <.data_grid
      id="tasks"
      source={MasuTest.Task}
      repo={MasuTest.Repo}
      changeset={&MasuTest.Task.changeset/2}
      struct={%MasuTest.Task{status: :todo}}
      deletable={&(&1.status != :done)}
      selectable
      live={{MasuTest.PubSub, "tasks"}}
      on_save={&send(self(), {:log, "saved", &1})}
      on_delete={&send(self(), {:log, "deleted", &1})}
      sort={[:id]}
    >
      <:col field={:title} />
      <:col field={:status} type={:enum} />
      <:col field={:points} type={:decimal} decimals={1} />
    </.data_grid>
    <p id="log">{Enum.join(@log, "; ")}</p>
    """
  end

  @impl true
  def handle_info({:log, what, rows}, socket) do
    entry = "#{what} #{Enum.map_join(rows, ",", & &1.title)}"
    {:noreply, update(socket, :log, &(&1 ++ [entry]))}
  end
end

defmodule MasuTest.RowsPeopleLive do
  @moduledoc "A grid of a list that adds rows with a changeset, and deletes them."
  use Phoenix.LiveView

  import Masu.Components

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, people: MasuTest.People.all())}

  @impl true
  def render(assigns) do
    ~H"""
    <.data_grid
      id="people"
      rows={@people}
      changeset={&MasuTest.EditPeopleLive.changeset/2}
      struct={fn -> %{id: System.unique_integer([:positive]) + 1000, name: nil, age: nil, city: nil} end}
      deletable
      sort={[:id]}
    >
      <:col field={:name} />
      <:col field={:age} type={:integer} />
      <:col field={:city} editable={false} />
    </.data_grid>
    """
  end
end

defmodule MasuTest.RowsThingsLive do
  @moduledoc "A grid that adds and deletes rows with functions of its own, and cannot undo a delete."
  use Phoenix.LiveView

  import Masu.Components

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, rows: [%{id: 1, name: "One"}, %{id: 2, name: "Keep"}])}

  @impl true
  def render(assigns) do
    ~H"""
    <.data_grid id="things" rows={@rows} create={&create/1} delete={&delete/1}>
      <:col field={:name} />
    </.data_grid>
    """
  end

  defp create(%{"name" => "nope"}), do: {:error, "Not that name."}
  defp create(%{"name" => name}), do: {:ok, %{id: System.unique_integer([:positive]), name: name}}
  defp create(_params), do: {:error, "A thing needs a name."}

  defp delete(%{name: "Keep"}), do: {:error, "Kept."}
  defp delete(_row), do: :ok
end

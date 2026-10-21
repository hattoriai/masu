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
      on_update={&logged(&1, "saved")}
      on_create={&logged(&1, "saved")}
      on_delete={&logged(&1, "deleted")}
      on_restore={&Masu.Write.save/1}
      sort={[:id]}
    >
      <:col field={:title} />
      <:col field={:status} type={:enum} />
      <:col field={:points} type={:decimal} decimals={1} />
    </.data_grid>
    <p id="log">{Enum.join(@log, "; ")}</p>
    """
  end

  # The grid's own way, and a line of the log for what it saved.
  defp logged(write, what) do
    write = Masu.Write.save(write)
    rows = Masu.Write.saved(write)
    if rows != [], do: send(self(), {:log, what, rows})
    write
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
    <.data_grid
      id="things"
      rows={@rows}
      on_create={&Masu.Write.each(&1, fn change -> create(change.params) end)}
      on_delete={&Masu.Write.each(&1, fn change -> delete(change.row) end)}
    >
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

defmodule MasuTest.RowsAccountLive do
  @moduledoc """
  A grid of an account's people: its changeset casts the account from
  params, and `create_with` sets it.
  """
  use Phoenix.LiveView

  import Masu.Components

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, people: [%{id: 1, name: "Ada", account: "acme"}])}

  @impl true
  def render(assigns) do
    ~H"""
    <.data_grid
      id="people"
      rows={@people}
      changeset={&changeset/2}
      struct={fn -> %{id: System.unique_integer([:positive]) + 1000, name: nil, account: nil} end}
      create_with={[account: "acme"]}
      sort={[:id]}
    >
      <:col field={:name} />
      <:col field={:account} />
    </.data_grid>
    """
  end

  def changeset(person, params) do
    {person, %{name: :string, account: :string}}
    |> Ecto.Changeset.cast(params, [:name, :account])
    |> Ecto.Changeset.validate_required([:name, :account])
  end
end

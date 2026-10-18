defmodule MasuTest.ChoresLive do
  @moduledoc """
  Chores with actions of the app's own (Masu.Action): on the rows
  selected, and on each row; one for admins only (`?admin=true`). What
  the actions get is shown on the page, and the ref of one that goes on
  later.
  """
  use Phoenix.LiveView

  import Ecto.Query
  import Masu.Components

  alias MasuTest.{Chore, Repo}

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     assign(socket,
       admin: params["admin"] == "true",
       scope: %{user: "ada"},
       heard: nil,
       ref: nil
     )}
  end

  @impl true
  def handle_info({:heard, heard}, socket), do: {:noreply, assign(socket, heard: heard)}
  def handle_info({:ref, ref}, socket), do: {:noreply, assign(socket, ref: ref)}

  def handle_info({Masu.Action, "peek", context}, socket),
    do: {:noreply, assign(socket, heard: "peek #{context.row.title} by #{context.scope.user}")}

  @impl true
  def render(assigns) do
    pid = self()

    assigns =
      assign(assigns,
        later: fn context ->
          send(pid, {:ref, context.ref})
          :async
        end,
        remove: fn context ->
          {count, _} = context.selected |> query() |> Repo.delete_all()
          {:ok, "#{count} removed"}
        end
      )

    ~H"""
    <p :if={@heard} id="heard">{@heard}</p>
    <p :if={@ref} id="ref">{@ref}</p>
    <.data_grid id="chores" source={Chore} repo={Repo} selectable sort={[:id]} scope={@scope}>
      <:col field={:title} />
      <:col field={:done} type={:boolean} />

      <:action label="Done" on_action={&done/1} />
      <:action :if={@admin} label="Remove" on_action={@remove} confirm="Remove {count} chores?" danger />
      <:action label="Later" on_action={@later} keep_selection />
      <:action label="Fail" on_action={fn _context -> {:error, "Not now."} end} />

      <:row_action label="Open" navigate={&"/chores/#{&1.id}"} />
      <:row_action label="Undo" on_action={&undo/1} disabled={&(!&1.done)} />
      <:row_action label="Peek" event="peek" show={&(&1.id == 1)} />
    </.data_grid>
    """
  end

  defp done(context) do
    {count, _} = context.selected |> query() |> Repo.update_all(set: [done: true])
    {:ok, "#{count} done by #{context.scope.user}"}
  end

  defp undo(context) do
    context.row |> Ecto.Changeset.change(done: false) |> Repo.update!()
    :ok
  end

  defp query({:ids, ids}), do: from(c in Chore, where: c.id in ^ids)
  defp query({:query, query}), do: query
end

defmodule MasuTest.WritesLive do
  @moduledoc """
  Things that a grid writes its own ways (Masu.Write), by `?mode=`: a
  batch saved whole (`all`), saved later (`async`), and what a write
  knows (`scope`). The ref of a write saved later is shown on the page.
  """
  use Phoenix.LiveView

  import Masu.Components

  @impl true
  def mount(params, _session, socket) do
    rows = [%{id: 1, name: "One"}, %{id: 2, name: "Two"}]
    {:ok, assign(socket, mode: params["mode"], rows: rows, heard: nil, ref: nil)}
  end

  @impl true
  def handle_info({:heard, heard}, socket), do: {:noreply, assign(socket, heard: heard)}
  def handle_info({:ref, ref}, socket), do: {:noreply, assign(socket, ref: ref)}

  @impl true
  def render(assigns) do
    pid = self()
    assigns = assign(assigns, write: &write(&1, assigns.mode, pid))

    ~H"""
    <p :if={@heard} id="heard">{@heard}</p>
    <p :if={@ref} id="ref">{@ref}</p>
    <.data_grid
      id="things"
      rows={@rows}
      scope={%{user: "ada"}}
      changeset={&changeset/2}
      on_update={@write}
      on_delete={@write}
      deletable
      sort={[:id]}
    >
      <:col field={:name} />
    </.data_grid>
    """
  end

  def changeset(row, params) do
    {row, %{name: :string}}
    |> Ecto.Changeset.cast(params, [:name])
    |> Ecto.Changeset.validate_required([:name])
  end

  # Saved whole, or not at all.
  defp write(write, "all", _pid) do
    Masu.Write.all(write, fn changes ->
      case Enum.find(changes, &(&1.params["name"] == "nope")) do
        nil -> {:ok, Enum.map(changes, &%{&1.row | name: &1.params["name"]})}
        change -> {:error, change, "Not that name."}
      end
    end)
  end

  defp write(write, "async", pid) do
    send(pid, {:ref, write.ref})
    Masu.Write.async(write)
  end

  # Nothing done: a mistake.
  defp write(write, "none", _pid), do: write

  defp write(write, _scope, pid) do
    send(
      pid,
      {:heard, "#{write.op} #{write.origin} by #{write.scope.user}: #{length(write.changes)}"}
    )

    Masu.Write.save(write)
  end
end

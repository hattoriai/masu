defmodule MasuTest.ExportLive do
  @moduledoc "People to export, from the grid's menu or the LiveView's own button."
  use Phoenix.LiveView

  import Masu.Components

  on_mount(Masu.Live)

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, csv: nil, admin: true)}

  # Export is for admins: the grid's `export` follows.
  @impl true
  def handle_event("admin", _params, socket),
    do: {:noreply, assign(socket, admin: not socket.assigns.admin)}

  def handle_event("csv", _params, socket) do
    csv = "people" |> Masu.Live.export() |> Masu.Export.stream() |> Enum.join()
    {:noreply, assign(socket, csv: csv)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <button id="csv" phx-click="csv">CSV</button>
    <button id="admin" phx-click="admin">Admin</button>
    <pre :if={@csv} id="out">{@csv}</pre>
    <.data_grid id="people" rows={rows()} export={@admin} sort={[:id]}>
      <:col field={:id} type={:integer} label="ID" />
      <:col :let={p} field={:name}><b>{p.name}</b></:col>
      <:col field={:balance} type={:decimal} />
      <:col field={:born} type={:date} />
      <:col field={:admin} type={:boolean} />
      <:col field={:city} hidden />
    </.data_grid>
    """
  end

  # People, and one whose name a spreadsheet would run as a formula.
  defp rows do
    MasuTest.People.all() ++
      [
        %{
          id: 6,
          name: "=HYPERLINK(\"x\")",
          city: "Bad, \"place\"",
          balance: nil,
          born: nil,
          admin: nil,
          age: 1
        }
      ]
  end
end

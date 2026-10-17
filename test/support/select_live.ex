defmodule MasuTest.SelectLive do
  @moduledoc "Orders to select (the SQLite table, or a list with `?source=list`); a button reads the selection."
  use Phoenix.LiveView

  import Masu.Components

  @impl true
  def mount(params, _session, socket) do
    {:ok, assign(socket, list: params["source"] == "list", selected: nil, summary: nil)}
  end

  @impl true
  def handle_event("selected", _params, socket) do
    selected =
      case Masu.Live.selected("orders") do
        {:ids, ids} ->
          "ids " <> Enum.join(Enum.sort(ids), ",")

        {:query, query} ->
          "query " <>
            (query |> MasuTest.Repo.all() |> Enum.map(& &1.id) |> Enum.sort() |> Enum.join(","))
      end

    {:noreply, assign(socket, selected: selected)}
  end

  @impl true
  def handle_info({:selected, summary}, socket), do: {:noreply, assign(socket, summary: summary)}

  @impl true
  def render(assigns) do
    pid = self()

    assigns =
      assign(assigns,
        rows: if(assigns.list, do: MasuTest.Repo.all(MasuTest.Order)),
        on_select: &send(pid, {:selected, &1})
      )

    ~H"""
    <button id="read" phx-click="selected">Read</button>
    <p :if={@selected} id="selected">{@selected}</p>
    <p :if={@summary} id="summary">{@summary.count} {@summary.all}</p>
    <%= if @list do %>
      <.data_grid id="orders" rows={@rows} selectable on_select={@on_select} sort={[:id]}>
        <:col field={:number} />
        <:col field={:status} type={:enum} />
      </.data_grid>
    <% else %>
      <.data_grid id="orders" source={MasuTest.Order} repo={MasuTest.Repo} selectable on_select={@on_select} sort={[:id]}>
        <:col field={:number} />
        <:col field={:status} type={:enum} />
      </.data_grid>
    <% end %>
    """
  end
end

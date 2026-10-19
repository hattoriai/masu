defmodule MasuTest.PlacedLive do
  @moduledoc """
  Orders with a range of days above the grid that filters it, through the
  URL (`url`), as the Koyomi guide does with a date range picker: the
  form posts `placed[from]` and `placed[to]`.
  """
  use Phoenix.LiveView

  import Masu.Components

  alias Plug.Conn.Query

  on_mount(Masu.Live)

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("placed", %{"placed" => %{"from" => from, "to" => to}}, socket) do
    filter = %{"0" => %{"key" => "placed_on", "op" => "between", "value" => [from, to]}}
    query = Query.encode(%{"orders" => %{"filter" => filter}})
    {:noreply, push_patch(socket, to: "/placed?" <> query)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <form id="placed" phx-change="placed"></form>
    <.data_grid id="orders" source={MasuTest.Order} repo={MasuTest.Repo} sort={[:id]} url>
      <:col field={:number} />
      <:col field={:placed_on} type={:date} />
    </.data_grid>
    """
  end
end

defmodule MasuTest.GrowLive do
  @moduledoc "A grid whose title takes the room its columns leave (`grow`)."
  use Phoenix.LiveView

  import Masu.Components

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, rows: [%{id: 1, title: "A title", author: "Ada", comments: 3}])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.data_grid id="items" rows={@rows}>
      <:col field={:title} min_width={280} grow />
      <:col field={:author} width={120} />
      <:col field={:comments} type={:integer} width={100} grow={2} />
    </.data_grid>
    """
  end
end

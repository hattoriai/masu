defmodule MasuTest.GroupsLive do
  @moduledoc """
  Orders grouped by the columns of `?group=status,customer`, from the
  SQLite table (`?source=ecto`), or as a list (`?source=list`).
  """
  use Phoenix.LiveView

  import Masu.Components

  @impl true
  def mount(params, _session, socket) do
    groups = (params["group"] || "") |> String.split(",", trim: true)
    {:ok, assign(socket, groups: groups, list: params["source"] == "list")}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :rows, if(assigns.list, do: MasuTest.Repo.all(MasuTest.Order)))

    ~H"""
    <%= if @list do %>
      <.data_grid id="orders" rows={@rows} group_by={@groups}>
        <:col field={:number} />
        <:col field={:customer} />
        <:col field={:status} type={:enum} />
        <:col field={:total} type={:decimal} aggregate={:sum} />
        <:col field={:placed_on} type={:date} aggregate={:max} />
      </.data_grid>
    <% else %>
      <.data_grid id="orders" source={MasuTest.Order} repo={MasuTest.Repo} group_by={@groups} sort={[:id]}>
        <:col field={:number} />
        <:col field={:customer} />
        <:col field={:status} type={:enum} />
        <:col field={:total} type={:decimal} aggregate={:sum} />
        <:col field={:placed_on} type={:date} aggregate={:max} />
      </.data_grid>
    <% end %>
    """
  end
end

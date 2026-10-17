defmodule MasuTest.ActionsLive do
  @moduledoc """
  Orders with menus of the app's own (Masu.Action): items in the header
  menu and in the menu of a cell, a panel, and an item for admins only
  (`?admin=true`). What the items get is shown on the page.
  """
  use Phoenix.LiveView

  import Masu.Components

  alias Phoenix.LiveView.JS

  @impl true
  def mount(params, _session, socket) do
    {:ok, assign(socket, admin: params["admin"] == "true", heard: nil)}
  end

  @impl true
  def handle_info({Masu.Action, "open", context}, socket),
    do:
      {:noreply,
       assign(socket, heard: "open #{context.grid} #{context.id} #{context.row.number}")}

  def handle_info({:explained, context}, socket),
    do: {:noreply, assign(socket, heard: "explain #{context.grid} #{context.column}")}

  def handle_info({:voided, context}, socket),
    do: {:noreply, assign(socket, heard: "void #{context.id} #{inspect(context.range)}")}

  def handle_info({:customer, context}, socket),
    do: {:noreply, assign(socket, heard: "customer #{context.value}")}

  @impl true
  def render(assigns) do
    pid = self()

    assigns =
      assign(assigns,
        explain: &send(pid, {:explained, &1}),
        void: &send(pid, {:voided, &1}),
        customer: &send(pid, {:customer, &1})
      )

    ~H"""
    <p :if={@heard} id="heard">{@heard}</p>
    <.data_grid id="orders" source={MasuTest.Order} repo={MasuTest.Repo} sort={[:id]} cell_menu>
      <:col field={:number} />
      <:col field={:customer} />
      <:col field={:status} type={:enum} values={~w(draft paid late void)} />
      <:col field={:total} type={:decimal} filterable={false} />

      <:header_action label="Explain" on_action={@explain} />
      <:header_action :let={action} label="Stats" types={[:decimal]}>
        <p id="stats">Stats of {action.column}</p>
      </:header_action>

      <:cell_action label="Open" event="open" />
      <:cell_action label="Only customers" columns={[:customer]} on_action={@customer} />
      <:cell_action :if={@admin} label="Void" on_action={@void} />
      <:cell_action label="Copy a link" js={JS.dispatch("app:link")} />
      <:cell_action :let={action} label="Peek" show={&(&1.type == :enum)}>
        <p id="peek">{action.row.number} is {action.value}</p>
      </:cell_action>
    </.data_grid>
    """
  end
end

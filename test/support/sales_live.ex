defmodule MasuTest.SalesLive do
  @moduledoc """
  Sales with columns of related rows: the customer's name and company (a
  belongs-to path) and the tags (a many-to-many path), from the database
  (`?source=ecto`) or from a list of preloaded rows (`?source=list`).
  """
  use Phoenix.LiveView

  import Masu.Components

  alias MasuTest.{Repo, Sale}

  @impl true
  def mount(params, _session, socket) do
    source =
      case params["source"] do
        "list" -> Sale |> Repo.all() |> Repo.preload([:tags, customer: :company])
        _ecto -> Sale
      end

    {:ok, assign(socket, source: source)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.data_grid id="sales" source={@source} repo={Repo}>
      <:col field={:number} />
      <:col field={:amount} type={:integer} aggregate={:sum} />
      <:col field={[:customer, :name]} label="Customer" />
      <:col field={[:customer, :company, :name]} key="company" />
      <:col field={[:tags, :name]} key="tags" type={:enum} />
    </.data_grid>
    """
  end
end

defmodule MasuTest.ControlledSalesLive do
  @moduledoc """
  A controlled grid (`on_query`) with a column of a related row's field:
  the LiveView runs the query, and shows the last one it was given.
  """
  use Phoenix.LiveView

  import Masu.Components

  alias MasuTest.{Repo, Sale}

  @impl true
  def mount(_params, _session, socket) do
    rows = Sale |> Repo.all() |> Repo.preload(:customer)
    {:ok, assign(socket, rows: rows, asked: nil)}
  end

  @impl true
  def handle_info({:sales_query, %{query: query}}, socket),
    do: {:noreply, assign(socket, asked: query)}

  @impl true
  def render(assigns) do
    pid = self()
    assigns = assign(assigns, on_query: &send(pid, {:sales_query, &1}))

    ~H"""
    <p id="asked">{@asked && inspect({@asked.sorts, @asked.filters})}</p>
    <.data_grid id="sales" rows={@rows} total={length(@rows)} on_query={@on_query}>
      <:col field={:number} />
      <:col field={[:customer, :name]} label="Customer" />
    </.data_grid>
    """
  end
end

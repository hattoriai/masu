defmodule MasuTest.BadIdsLive do
  @moduledoc """
  A grid of an Ecto schema with an integer key, with every event that
  takes a row's id: the tests send ids that are none.
  """
  use Phoenix.LiveView

  import Masu.Components

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.data_grid
      id="orders"
      source={MasuTest.Order}
      repo={MasuTest.Repo}
      changeset={&MasuTest.Order.changeset/2}
      deletable
      selectable
      history={Masu.History.Memory}
      user={%{id: 7, name: "Ada"}}
      sort={[:id]}
    >
      <:col field={:customer} />
      <:col field={:status} editor={&status_editor/1} />
      <:row_action label="Open" on_action={fn _context -> :ok end} />
      <:detail :let={order}>{order.customer}</:detail>
    </.data_grid>
    """
  end

  defp status_editor(assigns), do: ~H"<input name={@field.name} value={@field.value} />"
end

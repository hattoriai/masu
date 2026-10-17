defmodule MasuTest.ThemeLive do
  @moduledoc "Grids of each density, for their row heights and classes."
  use Phoenix.LiveView

  import Masu.Components

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.data_grid id="compact" rows={MasuTest.People.all()} density={:compact}>
      <:col field={:name} />
    </.data_grid>
    <.data_grid id="normal" rows={MasuTest.People.all()}><:col field={:name} /></.data_grid>
    <.data_grid id="tall" rows={MasuTest.People.all()} density={:comfortable} row_height={60}>
      <:col field={:name} />
    </.data_grid>
    """
  end
end

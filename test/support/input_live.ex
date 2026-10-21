defmodule MasuTest.InputLive do
  @moduledoc """
  A grid of a list that keeps its last view in memory, with a row whose
  name has a NUL character, for what the browser sends.
  """
  use Phoenix.LiveView

  import Masu.Components

  on_mount(Masu.Live)

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, user: %{id: "ada"})}

  @impl true
  def render(assigns) do
    ~H"""
    <.data_grid
      id="g"
      rows={[%{id: 1, name: "ab"}, %{id: 2, name: "a" <> <<0>> <> "b"}]}
      url
      views={Masu.Views.Memory}
      user={@user}
    >
      <:col field={:id} type={:integer} />
      <:col field={:name} />
    </.data_grid>
    """
  end
end

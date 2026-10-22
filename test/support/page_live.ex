defmodule MasuTest.PageLive do
  @moduledoc false
  # A grid in a page (a document): as tall as its rows, the wheel the
  # page's, and a view it opens with (`view`, from the session).
  use Phoenix.LiveView
  import Masu.Components

  @impl true
  def mount(_params, session, socket),
    do: {:ok, assign(socket, view: session["view"], rows: MasuTest.People.all())}

  @impl true
  def render(assigns) do
    ~H"""
    <.data_grid id="page" rows={@rows} height="auto" max_height="20rem" wheel={:page} view={@view}>
      <:col field={:id} type={:integer} />
      <:col field={:name} />
      <:col field={:city} />
      <:col field={:age} type={:integer} />
    </.data_grid>
    """
  end
end

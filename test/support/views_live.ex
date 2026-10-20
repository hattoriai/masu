defmodule MasuTest.EctoViews do
  @moduledoc "The views of the tests, in the SQLite repo."
  use Masu.Views.Ecto, repo: MasuTest.Repo
end

defmodule MasuTest.ViewsLive do
  @moduledoc """
  A grid that keeps its view in the URL and in a store (in memory, or
  the SQLite repo with `?store=ecto`); the user comes from the URL.
  """
  use Phoenix.LiveView

  import Masu.Components

  on_mount(Masu.Live)

  @impl true
  def mount(params, _session, socket) do
    store = if params["store"] == "ecto", do: MasuTest.EctoViews, else: Masu.Views.Memory

    {:ok,
     assign(socket,
       user: %{id: params["user"] || "ada"},
       account: params["account"],
       store: store
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.data_grid
      id="people"
      rows={MasuTest.People.all()}
      url
      views={@store}
      user={@user}
      views_scope={@account}
      columns_menu
      sort={[:name]}
    >
      <:col field={:id} type={:integer} pinned={:start} />
      <:col field={:name} />
      <:col field={:city} />
      <:col field={:age} type={:integer} />
      <:col field={:admin} type={:boolean} hidden />
    </.data_grid>
    """
  end
end

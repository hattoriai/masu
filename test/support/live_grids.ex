defmodule MasuTest.LivePeopleLive do
  @moduledoc "A grid of a list that follows a topic, for the tests of Masu.Live."
  use Phoenix.LiveView

  import Masu.Components

  on_mount(Masu.Live)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, people: MasuTest.People.all())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.data_grid id="people" rows={@people} label="People" live={{MasuTest.PubSub, "people"}} sort={[:name]}>
      <:col field={:name} />
      <:col field={:age} type={:integer} />
    </.data_grid>
    """
  end
end

defmodule MasuTest.LiveOrdersLive do
  @moduledoc "A grid of an Ecto schema that follows a topic, for the tests of Masu.Live."
  use Phoenix.LiveView

  import Masu.Components

  on_mount(Masu.Live)

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.data_grid id="orders" source={MasuTest.Order} repo={MasuTest.Repo} live={{MasuTest.PubSub, "orders"}}>
      <:col field={:number} />
      <:col field={:status} type={:enum} />
    </.data_grid>
    """
  end
end

defmodule MasuTest.NoHookLive do
  @moduledoc "A grid with `live` in a LiveView without the hook."
  use Phoenix.LiveView

  import Masu.Components

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.data_grid id="people" rows={MasuTest.People.all()} live={{MasuTest.PubSub, "people"}}>
      <:col field={:name} />
    </.data_grid>
    """
  end
end

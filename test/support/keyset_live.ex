defmodule MasuTest.KeysetLive do
  @moduledoc """
  Items read in a task (`load={:async}`), sorted by a field with empty
  values: paging by key; and items read by a read of the app's own.
  """
  use Phoenix.LiveView

  import Ecto.Query
  import Masu.Components

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.data_grid id="items" source={MasuTest.Item} repo={MasuTest.Repo} load={:async} sort={[:name]}>
      <:col field={:id} type={:integer} />
      <:col field={:name} />
      <:col field={:score} type={:integer} />
    </.data_grid>
    <.data_grid id="read" source={MasuTest.Item} repo={MasuTest.Repo} read={&read/2}>
      <:col field={:id} type={:integer} />
      <:col field={:name} />
    </.data_grid>
    """
  end

  defp read(query, page) do
    query
    |> offset(^page.offset)
    |> limit(^page.limit)
    |> MasuTest.Repo.all()
    |> Enum.map(&%{&1 | name: "read: #{&1.name}"})
  end
end

defmodule MasuTest.CountSource do
  @moduledoc """
  A source that does not count (a search engine's): `:unknown`,
  `{:at_least, n}`, or the count with its rows (`:inline`).
  """
  @behaviour Masu.Source

  @impl true
  def init(opts, _grid_opts), do: %{rows: Keyword.fetch!(opts, :rows), mode: opts[:mode]}

  @impl true
  def prepare(state, _query, _columns), do: state

  @impl true
  def count(%{mode: :at_least}), do: {:at_least, 100}
  def count(%{mode: :exact, rows: rows}), do: length(rows)
  def count(_state), do: :unknown

  @impl true
  def rows(%{mode: :inline, rows: rows}, offset, limit),
    do: {Enum.slice(rows, offset, limit), length(rows)}

  def rows(%{rows: rows}, offset, limit), do: Enum.slice(rows, offset, limit)
end

defmodule MasuTest.CountsLive do
  @moduledoc "Grids that do not know their count, that count late, and that page."
  use Phoenix.LiveView

  import Ecto.Query
  import Masu.Components

  on_mount(Masu.Live)

  @impl true
  def mount(params, _session, socket) do
    mode = Map.get(params, "mode", "unknown") |> String.to_existing_atom()
    rows = for id <- 1..250, do: %{id: id, name: "row #{id}"}
    {:ok, assign(socket, mode: mode, rows: rows)}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.data_grid id="engine" source={{MasuTest.CountSource, rows: @rows, mode: @mode}}>
      <:col field={:id} type={:integer} />
      <:col field={:name} />
    </.data_grid>
    <.data_grid id="late" source={MasuTest.Item} repo={MasuTest.Repo} count={:deferred} sort={[:id]}>
      <:col field={:id} type={:integer} />
      <:col field={:name} />
    </.data_grid>
    <.data_grid id="never" source={from(i in MasuTest.Item)} repo={MasuTest.Repo} count={:none} sort={[:id]}>
      <:col field={:id} type={:integer} />
      <:col field={:name} />
    </.data_grid>
    <.data_grid
      id="pages"
      source={MasuTest.Item}
      repo={MasuTest.Repo}
      paging={:pages}
      page_size={50}
      sort={[:id]}
      url
    >
      <:col field={:id} type={:integer} />
      <:col field={:name} />
    </.data_grid>
    """
  end
end

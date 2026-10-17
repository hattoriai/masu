defmodule MasuTest.CountSource do
  @moduledoc """
  A source that does not count (a search engine's): `:unknown`,
  `{:at_least, n}`, or the count with its rows (`:inline`).
  """
  @behaviour Masu.Source

  @impl true
  def init(opts, _grid_opts),
    do: %{rows: Keyword.fetch!(opts, :rows), mode: opts[:mode], notify: opts[:notify]}

  @impl true
  def prepare(state, _query, _columns), do: state

  @impl true
  def count(%{mode: :at_least}), do: {:at_least, 100}
  def count(%{mode: :exact, rows: rows}), do: length(rows)
  def count(_state), do: :unknown

  @impl true
  def rows(%{mode: :inline, rows: rows}, offset, limit),
    do: {Enum.slice(rows, offset, limit), length(rows)}

  def rows(%{rows: rows} = state, offset, limit) do
    # A test hears of each read: a read is a query, for a source like Lotus.
    if state.notify, do: send(state.notify, {:read, offset, limit})
    Enum.slice(rows, offset, limit)
  end
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

defmodule MasuTest.BlocksLive do
  @moduledoc "Grids that read a source in blocks and pages of their own sizes, and tell the test of each read."
  use Phoenix.LiveView

  import Masu.Components

  @impl true
  def mount(_params, session, socket) do
    rows = for id <- 1..2500, do: %{id: id, name: "row #{id}"}
    {:ok, assign(socket, rows: rows, notify: session["notify"])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.data_grid id="scroll" source={{MasuTest.CountSource, rows: @rows, mode: :exact, notify: @notify}} block_size={250}>
      <:col field={:id} type={:integer} />
    </.data_grid>
    <.data_grid
      id="report"
      source={{MasuTest.CountSource, rows: @rows, mode: :exact, notify: @notify}}
      paging={:pages}
      page_size={1000}
      max_block={1000}
    >
      <:col field={:id} type={:integer} />
    </.data_grid>
    """
  end
end

defmodule MasuTest.SlowSource do
  @moduledoc """
  A slow source: a list that takes `delay` milliseconds to prepare and to
  read, as a warehouse would; with `fail: true`, its reads fail.
  """
  @behaviour Masu.Source

  alias Masu.Source.List, as: ListSource

  @impl true
  def init(opts, grid_opts) do
    %{
      list: ListSource.init(Keyword.fetch!(opts, :rows), grid_opts),
      delay: Keyword.get(opts, :delay, 0),
      fail: Keyword.get(opts, :fail, false)
    }
  end

  @impl true
  def prepare(state, query, columns) do
    Process.sleep(state.delay)
    %{state | list: ListSource.prepare(state.list, query, columns)}
  end

  @impl true
  def count(state), do: ListSource.count(state.list)

  @impl true
  def rows(%{fail: true}, _offset, _limit), do: {:error, "the warehouse is down"}

  def rows(state, offset, limit) do
    Process.sleep(state.delay)
    ListSource.rows(state.list, offset, limit)
  end
end

defmodule MasuTest.AsyncLive do
  @moduledoc "People from a slow source, read in a task (`load={:async}`): `?delay=`, `?fail=true`, `?timeout=`."
  use Phoenix.LiveView

  import Masu.Components

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     assign(socket,
       delay: String.to_integer(params["delay"] || "0"),
       fail: params["fail"] == "true",
       timeout: params["timeout"] && String.to_integer(params["timeout"])
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.data_grid
      id="people"
      source={{MasuTest.SlowSource, rows: MasuTest.People.all(), delay: @delay, fail: @fail}}
      load={:async}
      timeout={@timeout}
      sort={[:id]}
    >
      <:col field={:name} />
      <:col field={:age} type={:integer} />
    </.data_grid>
    """
  end
end

defmodule MasuTest.ControlledLive do
  @moduledoc """
  A controlled grid (`on_query`), as Lotus Web would have it: the
  LiveView runs its query (in `start_async`), a page at a time, and
  counts its runs; the grid shows the rows it is given.
  """
  use Phoenix.LiveView

  import Masu.Components

  @page 2

  @impl true
  def mount(params, _session, socket) do
    delay = String.to_integer(params["delay"] || "0")

    {:ok,
     socket
     |> assign(runs: 0, running: false, rows: [], total: 0, delay: delay)
     |> run(%Masu.Query{}, 0)}
  end

  @impl true
  def handle_info({:results_query, %{query: query, offset: offset, limit: @page}}, socket),
    do: {:noreply, run(socket, query, offset)}

  # The query, as Lotus runs it: in a task, all its rows filtered and
  # sorted, then a page of them, and the count.
  defp run(socket, query, offset) do
    socket = assign(socket, running: true, runs: socket.assigns.runs + 1)
    delay = socket.assigns.delay

    start_async(socket, :run, fn ->
      Process.sleep(delay)

      rows =
        MasuTest.People.all()
        |> Enum.filter(fn row ->
          Enum.all?(
            query.filters,
            &Masu.Filter.match?(&1, Map.get(row, String.to_existing_atom(&1.key)))
          )
        end)
        |> sort(query.sorts)

      {Enum.slice(rows, offset, @page), length(rows)}
    end)
  end

  defp sort(rows, [%Masu.Sort{key: key, direction: direction} | _]),
    do: Enum.sort_by(rows, &Map.get(&1, String.to_existing_atom(key)), direction)

  defp sort(rows, []), do: rows

  @impl true
  def handle_async(:run, {:ok, {rows, total}}, socket),
    do: {:noreply, assign(socket, rows: rows, total: total, running: false)}

  @impl true
  def render(assigns) do
    pid = self()
    assigns = assign(assigns, on_query: &send(pid, {:results_query, &1}))

    ~H"""
    <p id="runs">{@runs}</p>
    <.data_grid
      id="people"
      rows={@rows}
      total={@total}
      loading={@running}
      on_query={@on_query}
      paging={:pages}
      page_size={2}
      multi_sort={false}
      filter_bar={false}
    >
      <:col field={:name} />
      <:col field={:age} type={:integer} />
      <:col field={:balance} type={:decimal} />
    </.data_grid>
    """
  end
end

defmodule Masu.Live do
  @moduledoc ~S"""
  Live rows: a grid that follows a PubSub topic, and shows the rows that
  change on it as they change.

      <.data_grid id="orders" source={Order} repo={Repo} live={{MyApp.PubSub, "orders"}}>

  Where the rows change, broadcast them:

      {:ok, order} = Repo.update(changeset)
      Masu.Live.broadcast_upsert(MyApp.PubSub, "orders", order)

      Repo.delete!(order)
      Masu.Live.broadcast_delete(MyApp.PubSub, "orders", order)

  The grid takes the change into the rows of its query, with the person's
  order, filters and search, changes its count, and the browser shows the
  new rows in the place the person reads, each changed row with a short
  highlight. A grid of an Ecto source asks its query again; a grid of a
  list puts the row in the list (by its id), or takes it out.

  Changes that come together, as from a batch of updates, make one new
  set of rows: the grid takes every change that waits in the LiveView's
  mailbox at once.

  ## The hook

  The LiveView process subscribes to the topic, and its `handle_info`
  receives the changes: this `on_mount` hook takes them, so the LiveView
  needs no clause of its own. Add it to the LiveView, or to its
  `live_session`:

      on_mount Masu.Live

      live_session :default, on_mount: [Masu.Live] do

  A grid with `live` in a LiveView without the hook raises, saying so.

  ## A list and its LiveView

  A grid of a list keeps the changes in its own copy of the list. The
  LiveView's assign does not change: give the grid new `rows` (which
  replace its copy) or broadcast changes, not both.
  """

  import Phoenix.LiveView, only: [attach_hook: 4]

  alias Phoenix.LiveView.Socket
  alias Plug.Conn.Query

  @typedoc "A change to the rows of a topic."
  @type change :: {:upsert, term()} | {:delete, term()}

  @doc false
  def on_mount(_arg, _params, _session, %Socket{} = socket) do
    Process.put(__MODULE__, %{})
    socket = attach_hook(socket, :masu_live, :handle_info, &__MODULE__.__handle_info__/2)

    # A grid with `url` keeps its view in the URL's params: the hook reads
    # them (a LiveView at the router only).
    socket =
      if socket.router,
        do: attach_hook(socket, :masu_params, :handle_params, &__MODULE__.__handle_params__/3),
        else: socket

    {:cont, socket}
  end

  @doc false
  def __handle_params__(params, uri, socket) do
    Process.put({__MODULE__, :params}, {params, uri})

    for grid <- Process.get({__MODULE__, :url_grids}, []),
        do: Phoenix.LiveView.send_update(Masu.Grid, id: grid, masu_params: true)

    # A LiveView without handle_params/3 of its own may still be patched,
    # as a grid with `url` does.
    if function_exported?(socket.view, :handle_params, 3),
      do: {:cont, socket},
      else: {:halt, socket}
  end

  @doc """
  The export of the grid `grid` of this LiveView (`Masu.Export`): its
  rows as they are now (the person's order, filters and search), with
  the columns that show. Call it in the LiveView; write it anywhere.
  """
  @spec export(String.t()) :: Masu.Export.t()
  def export(grid), do: Map.fetch!(grid!(grid), :export)

  @doc """
  The rows selected in the grid `grid` of this LiveView (`selectable`):
  `{:ids, ids}`, or, when the person selected every row of the query,
  `{:query, query}` for an Ecto source (an `Ecto.Query` of the rows, with
  the person's filters and search, less the rows they took out of it) and
  `{:ids, ids}` of every such row for a list.

      def handle_event("archive", _params, socket) do
        case Masu.Live.selected("orders") do
          {:ids, ids} -> Orders.archive(ids)
          {:query, query} -> Repo.update_all(query, set: [archived: true])
        end

        {:noreply, socket}
      end
  """
  @spec selected(String.t()) :: {:ids, [term()]} | {:query, term()}
  def selected(grid), do: grid!(grid).selected.()

  defp grid!(grid) do
    Process.get({__MODULE__, :grid, grid}) ||
      raise ArgumentError, "no grid #{inspect(grid)} in this LiveView"
  end

  @doc false
  # What a grid gives its LiveView: its export and its selection, as they
  # are at its last render.
  @spec put_grid(String.t(), map()) :: :ok
  def put_grid(grid, data) do
    Process.put({__MODULE__, :grid, grid}, data)
    :ok
  end

  @doc false
  # The params of the grid `grid` in the URL (`?orders[sort]=...`), or nil,
  # and the URL. Registers the grid, which hears of later params.
  @spec params(String.t()) :: {map() | nil, String.t() | nil}
  def params(grid) do
    unless Process.get(__MODULE__) do
      raise ArgumentError, """
      the grid #{grid} has `url`, but its LiveView has no Masu.Live hook. \
      Add `on_mount Masu.Live` to the LiveView, or to its live_session.\
      """
    end

    Process.put(
      {__MODULE__, :url_grids},
      MapSet.put(Process.get({__MODULE__, :url_grids}, MapSet.new()), grid)
    )

    case Process.get({__MODULE__, :params}) do
      {params, uri} ->
        grid_params = Map.get(params, grid)
        {if(is_map(grid_params), do: grid_params), uri}

      nil ->
        {nil, nil}
    end
  end

  @doc false
  # The URL with the params of the grid `grid` replaced (none: left out).
  @spec url(String.t(), String.t(), map()) :: String.t()
  def url(uri, grid, grid_params) do
    %URI{path: path, query: query} = URI.parse(uri)
    params = Query.decode(query || "")

    params =
      if grid_params == %{},
        do: Map.delete(params, grid),
        else: Map.put(params, grid, grid_params)

    case Query.encode(params) do
      "" -> path || "/"
      query -> "#{path || "/"}?#{query}"
    end
  end

  @doc """
  Broadcasts a row that was inserted or changed: a grid that follows the
  topic shows it, in the place of its query.
  """
  @spec broadcast_upsert(atom(), String.t(), term()) :: :ok | {:error, term()}
  def broadcast_upsert(pubsub, topic, row),
    do: Phoenix.PubSub.broadcast(pubsub, topic, {__MODULE__, topic, {:upsert, row}})

  @doc false
  # As broadcast_upsert/3, to every process but `from`, with who saved
  # the row (`%{name, color}`, or nil): its flash takes their color.
  @spec broadcast_upsert_from(pid(), atom(), String.t(), term(), map() | nil) ::
          :ok | {:error, term()}
  def broadcast_upsert_from(from, pubsub, topic, row, by \\ nil),
    do:
      Phoenix.PubSub.broadcast_from(pubsub, from, topic, {__MODULE__, topic, {:upsert, row, by}})

  @doc """
  Broadcasts a row that was deleted, given as the row or its id: a grid
  that follows the topic takes it out.
  """
  @spec broadcast_delete(atom(), String.t(), term()) :: :ok | {:error, term()}
  def broadcast_delete(pubsub, topic, row_or_id),
    do: Phoenix.PubSub.broadcast(pubsub, topic, {__MODULE__, topic, {:delete, row_or_id}})

  @doc false
  # Subscribes the LiveView to the people of a topic it follows, once.
  @spec follow_presence(atom(), String.t()) :: :ok
  def follow_presence(pubsub, topic) do
    key = {__MODULE__, :presence, topic}

    unless Process.get(key) do
      :ok = Phoenix.PubSub.subscribe(pubsub, Masu.Presence.topic(topic))
      Process.put(key, true)
    end

    :ok
  end

  @doc false
  # The grids of this LiveView that follow `topic` (a grid calls it when it
  # starts, and when its topic changes). Subscribes the process once a
  # topic.
  @spec follow(String.t(), {atom(), String.t()} | nil, {atom(), String.t()} | nil) :: :ok
  def follow(grid, old, new) do
    grids =
      Process.get(__MODULE__) ||
        raise ArgumentError, """
        the grid #{grid} has `live`, but its LiveView has no Masu.Live hook. \
        Add `on_mount Masu.Live` to the LiveView, or to its live_session.\
        """

    grids = if old, do: unfollow(grids, grid, old), else: grids

    grids =
      case new do
        {pubsub, topic} ->
          unless Map.has_key?(grids, topic), do: :ok = Phoenix.PubSub.subscribe(pubsub, topic)
          Map.update(grids, topic, MapSet.new([grid]), &MapSet.put(&1, grid))

        nil ->
          grids
      end

    Process.put(__MODULE__, grids)
    :ok
  end

  defp unfollow(grids, grid, {pubsub, topic}) do
    case Map.get(grids, topic) do
      nil ->
        grids

      ids ->
        ids = MapSet.delete(ids, grid)

        if MapSet.size(ids) == 0 do
          :ok = Phoenix.PubSub.unsubscribe(pubsub, topic)
          Map.delete(grids, topic)
        else
          Map.put(grids, topic, ids)
        end
    end
  end

  @doc false
  # A grid with `url` whose view changed.
  def __handle_info__({Masu.Live.Patch, url}, socket),
    do: {:halt, Phoenix.LiveView.push_patch(socket, to: url, replace: true)}

  def __handle_info__({__MODULE__, topic, change}, socket) do
    grids = Process.get(__MODULE__, %{})

    for grid <- Map.get(grids, topic, []) do
      pending = Process.get({__MODULE__, grid}, [])
      Process.put({__MODULE__, grid}, [change | pending])

      # The first change asks the grid to take them; the update comes
      # after every message already in the mailbox, so the changes that
      # come together are taken together.
      if pending == [], do: Phoenix.LiveView.send_update(Masu.Grid, id: grid, masu_changes: true)
    end

    {:halt, socket}
  end

  # The people of a grid's topic changed (Masu.Presence): the grids of the
  # topic draw them again.
  def __handle_info__(
        %Phoenix.Socket.Broadcast{event: "presence_diff", topic: "masu:presence:" <> topic},
        socket
      ) do
    for grid <- Map.get(Process.get(__MODULE__, %{}), topic, []) do
      Phoenix.LiveView.send_update(Masu.Grid, id: grid, masu_presence: true)
    end

    {:halt, socket}
  end

  def __handle_info__(_message, socket), do: {:cont, socket}

  @doc false
  # The changes that wait for a grid, oldest first; they are its now.
  @spec take(String.t()) :: [change()]
  def take(grid) do
    grid
    |> then(&Process.delete({__MODULE__, &1}))
    |> List.wrap()
    |> Enum.reverse()
  end
end

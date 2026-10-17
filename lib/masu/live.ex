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

  @typedoc "A change to the rows of a topic."
  @type change :: {:upsert, term()} | {:delete, term()}

  @doc false
  def on_mount(_arg, _params, _session, %Socket{} = socket) do
    Process.put(__MODULE__, %{})
    {:cont, attach_hook(socket, :masu_live, :handle_info, &__MODULE__.__handle_info__/2)}
  end

  @doc """
  Broadcasts a row that was inserted or changed: a grid that follows the
  topic shows it, in the place of its query.
  """
  @spec broadcast_upsert(atom(), String.t(), term()) :: :ok | {:error, term()}
  def broadcast_upsert(pubsub, topic, row),
    do: Phoenix.PubSub.broadcast(pubsub, topic, {__MODULE__, topic, {:upsert, row}})

  @doc """
  Broadcasts a row that was deleted, given as the row or its id: a grid
  that follows the topic takes it out.
  """
  @spec broadcast_delete(atom(), String.t(), term()) :: :ok | {:error, term()}
  def broadcast_delete(pubsub, topic, row_or_id),
    do: Phoenix.PubSub.broadcast(pubsub, topic, {__MODULE__, topic, {:delete, row_or_id}})

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

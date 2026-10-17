defmodule Masu.Views do
  @moduledoc ~S"""
  Where a grid keeps people's views: the last view of each person, which
  the grid restores when they come back, and named views ("My open
  orders") that a person saves for themselves or shares with everyone.

      <.data_grid id="orders" source={Order} repo={Repo} views={MyApp.GridViews} user={@user}>

  `views` is a module of this behaviour. Masu has two:

    * `Masu.Views.Ecto`, a table in your database (`use Masu.Views.Ecto,
      repo: MyApp.Repo`, and `mix masu.gen.views` for its migration);
    * `Masu.Views.Memory`, in memory, for development and tests.

  A store of your own implements the callbacks below. A view is kept as
  its params (see `Masu.View`): a map of strings, what differs from the
  grid's own view. `grid` is the grid's `views_key` (its id unless given)
  and `user` the grid's `user`; a person is `to_string(user.id)`.
  """

  @typedoc "A named view, as the views menu lists it."
  @type saved :: %{
          id: String.t(),
          name: String.t(),
          shared: boolean(),
          mine: boolean(),
          params: map()
        }

  @doc "The person's last view of the grid, or nil."
  @callback last(grid :: String.t(), user :: map()) :: map() | nil

  @doc "Keeps the person's view of the grid, as it changes."
  @callback put_last(grid :: String.t(), user :: map(), params :: map()) :: :ok

  @doc "The named views the person may apply: their own and the shared ones, by name."
  @callback list(grid :: String.t(), user :: map()) :: [saved()]

  @doc """
  Saves a named view of the person's: a view of theirs with that name is
  replaced. `shared` shows it to everyone who has the grid.
  """
  @callback save(
              grid :: String.t(),
              user :: map(),
              name :: String.t(),
              params :: map(),
              shared :: boolean()
            ) :: {:ok, saved()} | {:error, String.t()}

  @doc "Deletes a named view of the person's (not one of someone else's)."
  @callback delete(grid :: String.t(), user :: map(), id :: String.t()) :: :ok

  @doc false
  @spec owner(map()) :: String.t()
  def owner(%{id: id}), do: to_string(id)
end

defmodule Masu.Views.Memory do
  @moduledoc """
  Views in memory, for development and tests: they last as long as the
  node, and every grid of the node shares them. Not for production.

  Start it in your supervision tree (or in `test_helper.exs`):

      children = [Masu.Views.Memory, ...]
  """
  @behaviour Masu.Views

  use Agent

  @doc false
  def start_link(_opts \\ []),
    do: Agent.start_link(fn -> %{last: %{}, saved: %{}, next: 1} end, name: __MODULE__)

  @doc "Forgets every view."
  @spec clear() :: :ok
  def clear, do: Agent.update(__MODULE__, fn _state -> %{last: %{}, saved: %{}, next: 1} end)

  @impl true
  def last(grid, user),
    do: Agent.get(__MODULE__, &get_in(&1, [:last, {grid, Masu.Views.owner(user)}]))

  @impl true
  def put_last(grid, user, params) do
    Agent.update(__MODULE__, &put_in(&1, [:last, {grid, Masu.Views.owner(user)}], params))
  end

  @impl true
  def list(grid, user) do
    owner = Masu.Views.owner(user)

    Agent.get(__MODULE__, fn state ->
      for {id, view} <- state.saved,
          view.grid == grid and (view.owner == owner or view.shared) do
        %{
          id: id,
          name: view.name,
          shared: view.shared,
          mine: view.owner == owner,
          params: view.params
        }
      end
      |> Enum.sort_by(&String.downcase(&1.name))
    end)
  end

  @impl true
  def save(grid, user, name, params, shared) do
    owner = Masu.Views.owner(user)

    Agent.get_and_update(__MODULE__, fn state ->
      {id, next} =
        case find(state, grid, owner, name) do
          {id, _view} -> {id, state.next}
          nil -> {Integer.to_string(state.next), state.next + 1}
        end

      view = %{grid: grid, owner: owner, name: name, params: params, shared: shared}
      saved = %{id: id, name: name, shared: shared, mine: true, params: params}
      {{:ok, saved}, %{state | saved: Map.put(state.saved, id, view), next: next}}
    end)
  end

  defp find(state, grid, owner, name),
    do:
      Enum.find(state.saved, fn {_id, v} ->
        v.grid == grid and v.owner == owner and v.name == name
      end)

  @impl true
  def delete(grid, user, id) do
    owner = Masu.Views.owner(user)

    Agent.update(__MODULE__, fn state ->
      case state.saved[id] do
        %{grid: ^grid, owner: ^owner} -> %{state | saved: Map.delete(state.saved, id)}
        _other -> state
      end
    end)
  end
end

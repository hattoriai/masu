if Code.ensure_loaded?(Issho.Tool) do
  defmodule Masu.Issho do
    @moduledoc ~S"""
    Masu's grids in [Issho](https://hex.pm/packages/issho)'s rooms: agents
    read and change a grid as a person does, and the people who have it
    open see where they are and what they change.

    A grid of a room is named as a document of it is, `"room/grid"`
    (`"notebook:42/tasks"`): the room, and the grid's id. Its rows stay
    the grid's own: its source reads them, and its writes save them, the
    grid's way (`Masu.Sheet`). Issho carries who is there and where.

    ## The grids an agent may use

    Your app says which grid a name is, for whom, with a function of the
    name and the agent's `Issho.Tool.Context`, which gives the grid's
    attributes (those of `data_grid/1`, and `scope`, for its writes):

        config :masu, Masu.Issho, grids: {MyApp.Grids, :for_agent}

        def for_agent("project:" <> rest, ctx) do
          [project_id, "tasks"] = String.split(rest, "/")
          scope = MyApp.Accounts.scope_for(ctx.opts[:on_behalf_of])
          {:ok, Keyword.put(tasks(scope, project_id), :scope, scope)}
        end

        def for_agent(_grid, _ctx), do: {:error, "There is no such grid."}

    The agent is in the room (the room's policy lets it join), and each
    write asks the policy too (`:write`), before the grid's own rules.

    ## Tools

    `tools/0`: read a grid (in an order, filtered, searched), point at
    cells, edit cells, add rows and delete rows. Give them to an agent
    with Issho's (`Issho.Tools.room/0`), over MCP (`Issho.MCP`) or your
    app's own model (`Issho.Tools`).

    `config :masu, Masu.Issho, pace: 120`: the milliseconds an agent
    stays on each cell it edits, so the people see it move (0 for none).
    """

    alias Issho.Participant
    alias Issho.Tool.Context
    alias Masu.Sheet

    @doc "Masu's tools for agents."
    @spec tools() :: [module()]
    def tools,
      do: [
        Masu.Issho.Tools.Read,
        Masu.Issho.Tools.Select,
        Masu.Issho.Tools.Edit,
        Masu.Issho.Tools.Add,
        Masu.Issho.Tools.Delete
      ]

    @doc "The place of a cell, or of a range of rows and keys, in a grid of a room."
    @spec place(String.t(), {term(), String.t()} | {[term()], [String.t()]}) :: map()
    def place(grid, {ids, keys}) when is_list(ids) and is_list(keys),
      do: %{"doc" => grid, "at" => %{"range" => %{"rows" => Enum.take(ids, 500), "keys" => keys}}}

    def place(grid, {id, key}), do: %{"doc" => grid, "at" => %{"cell" => [id, to_string(key)]}}

    @doc false
    # The grid of a name, for the agent of the context: its sheet, in the
    # room the agent is in.
    @spec open(Context.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
    def open(%Context{} = ctx, grid) when is_binary(grid) do
      room = Issho.Policy.room(grid)

      with true <- room != grid || {:error, "Name a grid as room/grid: notebook:42/tasks."},
           {:ok, participant} <- Context.join(ctx, room),
           :ok <- Participant.authorize(participant, :read),
           {:ok, attrs} <- attrs(grid, ctx) do
        attrs = Map.new(attrs)

        {:ok,
         %{
           ctx: ctx,
           grid: grid,
           participant: participant,
           sheet: Sheet.new(attrs),
           scope: attrs[:scope],
           user: user(ctx)
         }}
      else
        {:error, reason} -> Context.error(reason)
      end
    end

    defp attrs(grid, ctx) do
      case Keyword.get(Application.get_env(:masu, __MODULE__, []), :grids) do
        {module, function} ->
          apply(module, function, [grid, ctx])

        function when is_function(function, 2) ->
          function.(grid, ctx)

        nil ->
          raise ArgumentError,
                "Masu.Issho needs `config :masu, Masu.Issho, grids: {MyApp.Grids, :for_agent}`"
      end
      |> case do
        {:ok, attrs} -> {:ok, attrs}
        {:error, reason} -> {:error, reason}
        nil -> {:error, "There is no grid #{grid}."}
      end
    end

    # Who writes, for the grid's history and the rows' flash.
    defp user(ctx) do
      identity = Issho.Identity.new(ctx.actor)
      %{id: identity.key, name: identity.name || identity.key}
    end

    @doc false
    @spec pace() :: non_neg_integer()
    def pace, do: Keyword.get(Application.get_env(:masu, __MODULE__, []), :pace, 120)
  end
end

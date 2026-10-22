if Code.ensure_loaded?(Issho.Tool) do
  defmodule Masu.Issho do
    @moduledoc ~S"""
    Masu's grids in [Issho](https://hex.pm/packages/issho)'s rooms: agents
    read and change a grid as a person does, and the people who have it
    open see where they are and what they change.

    A grid is named as a document is, `"room/grid"` (`"notebook:42/tasks"`):
    its `issho` `:document`, whose room is the part before the first
    `"/"`. A place in a grid is `Masu.Issho.Place`. Its rows stay
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

    `config :masu, Masu.Issho, pace: 120, travel: true`: `pace`, the
    milliseconds an agent stays on each cell it edits, typing, so the
    people see it (0 for none); `travel`, whether it goes to each cell and
    selects ranges as a drag does, as a person would (false: it is there at
    once). Only where it goes is sent: each browser draws the way there.
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
           user: user(ctx),
           by: Issho.Identity.new(ctx.actor, Keyword.take(ctx.opts, [:claims, :on_behalf_of])),
           issho: %{instance: ctx.instance, room: room, doc: grid}
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

    @doc false
    # The options of the agent's writes (Masu.Sheet): who, for the
    # history, the rows' flash and the write's `by`; and the room, which
    # hears of them ("document.changed").
    @spec write_opts(map()) :: keyword()
    def write_opts(grid),
      do: [scope: grid.scope, user: grid.user, by: grid.by, issho: grid.issho]

    # Who writes, for the grid's history and the rows' flash.
    defp user(ctx) do
      identity = Issho.Identity.new(ctx.actor)

      color =
        Issho.Color.sanitize(identity.color) ||
          "var(--issho-person-#{Issho.Color.index(identity.key)}, currentColor)"

      %{id: identity.key, name: identity.name || identity.key, color: color}
    end

    @doc false
    @spec pace() :: non_neg_integer()
    def pace, do: Keyword.get(Application.get_env(:masu, __MODULE__, []), :pace, 120)

    @doc false
    @spec travel?() :: boolean()
    def travel?, do: Keyword.get(Application.get_env(:masu, __MODULE__, []), :travel, true)

    @doc false
    # Goes to a cell, or selects a range as a drag does (pressed on its first
    # cell, let go on its last), with Issho's motion (`Issho.Motion`): only
    # where the agent goes is sent, each browser draws the way, and it moves
    # only for someone who sees the grid.
    @spec go(map(), {term(), String.t()} | {[term()], [String.t()]}) :: :ok
    def go(grid, {[first | _] = ids, [key | _] = keys}) do
      :ok =
        Issho.Motion.drag(
          grid.participant,
          target(grid, {first, key}),
          target(grid, {ids, keys}),
          travel: travel?()
        )
    end

    def go(grid, place),
      do: :ok = Issho.Motion.go(grid.participant, target(grid, place), travel: travel?())

    @doc false
    # A moment on a place, when someone sees it: typing in a cell, before
    # rows go.
    @spec pause(map(), {term(), String.t()} | {[term()], [String.t()]}, non_neg_integer()) :: :ok
    def pause(grid, place, ms), do: Issho.Motion.pause(grid.participant, target(grid, place), ms)

    defp target(grid, place), do: place(grid.grid, place)
  end
end

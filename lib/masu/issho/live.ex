if Code.ensure_loaded?(Issho.Live) do
  defmodule Masu.Issho.Live do
    @moduledoc false
    # The people of a grid in an Issho room: the grid's LiveView joins the
    # room (Issho.Live), puts where its person is in the room's awareness,
    # and reads the others from it, agents too. The rows stay the grid's:
    # this carries only who is there and where.
    #
    # In the session's awareness state, which the components of a
    # LiveView share in a room:
    #
    #   * "place": `%{"doc" => "room/grid", "at" => %{"cell" => [id, key],
    #     "range" => %{"rows" => ids, "keys" => keys}}}`, the person's cell;
    #   * "locks": the cell they are editing;
    #   * "masu": `%{"room/grid" => %{"view" => query, "top" => id}}`, the
    #     grids they have open, with their view (to follow them) and their
    #     first row on the screen.

    @doc false
    # The grid's settings, of its `issho` attribute.
    @spec config(term(), map() | nil) :: map()
    def config(issho, user) when is_list(issho) or is_map(issho) do
      issho = Map.new(issho)

      %{
        instance: Map.fetch!(issho, :instance),
        room: Map.fetch!(issho, :room),
        actor: Map.get(issho, :actor) || user,
        opts: issho |> Map.take([:can, :claims, :on_behalf_of]) |> Keyword.new()
      }
    end

    @doc false
    @spec doc(map(), String.t()) :: String.t()
    def doc(%{room: room}, grid), do: room <> "/" <> grid

    @doc false
    # Joins the room for the grid (the LiveView's session there, if it has
    # one), and says the grid is open.
    @spec join(map(), String.t(), map() | nil) :: :ok | {:error, term()}
    def join(config, grid, view) do
      with {:ok, _session} <-
             Issho.Live.join(config.instance, config.actor, config.room, config.opts) do
        true = Issho.Live.subscribe(config.room, {Masu.Grid, grid})
        put(config, grid, %{view: view, top: nil})
      end
    end

    @doc false
    # Where the person is now: any of `cell`, `range`, `editing`, `top`
    # and `view`, as the browser says them.
    @spec put(map(), String.t(), map()) :: :ok | {:error, term()}
    def put(config, grid, changes) do
      doc = doc(config, grid)
      state = Issho.Live.awareness(config.room)
      open = get_in(state, ["masu", doc]) || %{}

      open =
        open
        |> put_key("view", changes, :view)
        |> put_key("top", changes, :top)

      state =
        state
        |> Map.update("masu", %{doc => open}, &Map.put(&1, doc, open))
        |> place(doc, changes)

      Issho.Live.aware(config.room, state)
    end

    defp put_key(map, name, changes, key) do
      case Map.fetch(changes, key) do
        {:ok, value} -> Map.put(map, name, value)
        :error -> map
      end
    end

    # The person's place, when the change says where it is.
    defp place(state, doc, %{cell: cell} = changes) do
      range = changes[:range]
      here? = match?(%{"doc" => ^doc}, state["place"])

      place =
        cond do
          cell != nil or range != nil ->
            %{
              "doc" => doc,
              "at" => Map.reject(%{"cell" => cell, "range" => range}, &is_nil(elem(&1, 1)))
            }

          here? ->
            nil

          true ->
            state["place"]
        end

      locks = Enum.reject(state["locks"] || [], &match?(%{"doc" => ^doc}, &1))

      locks =
        if changes[:editing] == true and cell != nil,
          do: [%{"doc" => doc, "at" => %{"cell" => cell}} | locks],
          else: locks

      Map.merge(state, %{"place" => place, "locks" => locks})
    end

    defp place(state, _doc, _changes), do: state

    @doc false
    # The others who have the grid open, or who are in it (an agent), as
    # the grid draws them: one a person, their session that moved
    # last in the grid.
    @spec people(map(), String.t()) :: [map()]
    def people(config, grid) do
      doc = doc(config, grid)
      own = Issho.Identity.new(config.actor).key
      metas = Issho.Live.people(config.room)

      config.room
      |> Issho.Live.states()
      |> Map.values()
      |> Enum.filter(fn %{"key" => key, "state" => state} -> key != own and here?(state, doc) end)
      |> Enum.group_by(& &1["key"], & &1["state"])
      |> Enum.map(fn {key, states} -> person(key, states, doc, metas) end)
      |> Enum.sort_by(&{&1.name || "", &1.id})
    end

    defp here?(state, doc) when is_map(state),
      do: match?(%{"doc" => ^doc}, state["place"]) or is_map_key(state["masu"] || %{}, doc)

    defp here?(_state, _doc), do: false

    defp person(key, states, doc, metas) do
      state = Enum.find(states, &cell(&1, doc)) || hd(states)
      meta = person_meta(Map.get(metas, key))
      open = get_in(state, ["masu", doc]) || %{}
      cell = cell(state, doc)
      name = meta["name"]

      %{
        id: key,
        name: name,
        color: color(meta, key),
        avatar: meta["avatar"],
        initials: initials(name || key),
        cell: cell,
        range: range(state, doc),
        editing:
          cell != nil and %{"doc" => doc, "at" => %{"cell" => cell}} in (state["locks"] || []),
        view: open["view"],
        top: open["top"]
      }
    end

    # Phoenix.Presence's entry of a key: the meta of its first session.
    defp person_meta(%{metas: [meta | _]}), do: meta
    defp person_meta(%{"metas" => [meta | _]}), do: meta
    defp person_meta(_none), do: %{}

    defp cell(%{"place" => %{"doc" => doc, "at" => %{"cell" => [_id, _key] = cell}}}, doc),
      do: cell

    defp cell(_state, _doc), do: nil

    defp range(
           %{"place" => %{"doc" => doc, "at" => %{"range" => %{"rows" => rows, "keys" => keys}}}},
           doc
         )
         when is_list(rows) and is_list(keys),
         do: %{"rows" => Enum.take(rows, 500), "keys" => keys}

    defp range(_state, _doc), do: nil

    @doc false
    # The color of the grid's own person in the room, for the flash of the
    # rows they save.
    @spec color_of(map()) :: String.t()
    def color_of(config) do
      identity = Issho.Identity.new(config.actor)
      color(%{"color" => identity.color}, identity.key)
    end

    # Issho's colors: the person's own (Issho checks it), else the theme's
    # color of their index in the room's palette (issho.css, Sumi, a dark
    # mode), the same as Issho's list of people and pointers show.
    defp color(meta, key) do
      case Issho.Color.sanitize(meta["color"]) do
        nil -> "var(--issho-person-#{meta["palette"] || Issho.Color.index(key)}, currentColor)"
        color -> color
      end
    end

    defp initials(name) do
      name
      |> to_string()
      |> String.split(~r/\s+/, trim: true)
      |> Enum.take(2)
      |> Enum.map_join(&String.first/1)
      |> String.upcase()
    end
  end
end

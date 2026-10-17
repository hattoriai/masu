defmodule Masu.Presence do
  @moduledoc ~S"""
  Who else has a grid open, and where they are: the people of a grid,
  with `Phoenix.Presence`.

      <.data_grid
        id="orders"
        source={Order}
        repo={Repo}
        changeset={&Order.changeset/2}
        live={{MyApp.PubSub, "orders"}}
        presence={MyAppWeb.Presence}
        user={%{id: @current_user.id, name: @current_user.name}}
      >

  The grid shows the other people who have it open (their avatars above
  it), the cell each of them is on (a line in their color, with their
  name), the cell each of them is editing (which the others cannot edit
  meanwhile), and the rows they save, which flash in their color.

  ## Setting up

  `presence` is your app's `Phoenix.Presence` module, on the same PubSub
  as the grid's `live` topic (`mix phx.gen.presence` makes one):

      defmodule MyAppWeb.Presence do
        use Phoenix.Presence, otp_app: :my_app, pubsub_server: MyApp.PubSub
      end

  and it must be started in your supervision tree, after the PubSub. The
  grid needs `live` (the people of a grid are those of its topic) and the
  `Masu.Live` hook.

  ## The user

  `user` is a map: `id` (required), `name`, and, if you have them,
  `color` (a CSS color) and `avatar` (an image's URL). A person with no
  color gets one of a palette of eight, by their id, the same in every
  browser.

  The people are those of other users: a person who has the grid open in
  two tabs does not see themselves.

  ## Places, not positions

  Each person has their own order, filters and search, so a place is a
  row's id and a column's key, not a row's index: a person sees another's
  line on the cell of that row wherever it is in their own order, and not
  at all when their filters leave the row out.

  ## The look

  The avatars are HEEx: give the grid a `:person` slot to draw them with
  your own component; it gets each person as a map with `:id`, `:name`,
  `:color`, `:avatar`, `:initials`, `:cell`, `:range`, `:editing`, `:view`
  and `:top`. Each avatar is a button that follows the person: the grid
  shows their order, filters and search (unless their grid has
  `share_view={false}`) and keeps their place in view:

      <:person :let={person}>
        <.avatar src={person.avatar} name={person.name} ring={person.color} />
      </:person>

  The lines and labels on the cells are drawn by the browser: they are
  `.masu-peer` and `.masu-peer-label` elements with the person's color in
  `--masu-peer-color` (see the Theming guide), and `configure/1` of the
  bundle draws the label with a function of your own.

  ## Editing at the same time

  A cell that someone is editing shows it, and does not open an editor
  for anyone else: an advisory lock, as a database's. The guarantee is the
  server's: an edit of a cell that changed meanwhile is refused (see the
  Editing guide).
  """

  @palette ~w(#2563eb #db2777 #16a34a #d97706 #7c3aed #0891b2 #dc2626 #4d7c0f)

  @typedoc "A person who has the grid open."
  @type person :: %{
          id: String.t(),
          name: String.t() | nil,
          color: String.t(),
          avatar: String.t() | nil,
          initials: String.t(),
          cell: [term()] | nil,
          range: map() | nil,
          editing: boolean(),
          view: map() | nil,
          top: term()
        }

  @doc """
  The color of a user: their own `color`, or one of a palette of eight by
  their id, the same in every browser.
  """
  @spec color(map()) :: String.t()
  def color(%{color: color} = user) when is_binary(color) do
    # A color goes to other people's browsers: only a plain CSS color.
    if color =~
         ~r/^(#[0-9a-fA-F]{3,8}|[a-z]+|(rgb|rgba|hsl|hsla|oklch|oklab)\([0-9a-z.,%\s\/-]+\))$/,
       do: color,
       else: color(Map.delete(user, :color))
  end

  def color(%{id: id}),
    do: Enum.at(@palette, :erlang.phash2(to_string(id), length(@palette)))

  @doc false
  @spec topic(String.t()) :: String.t()
  def topic(live_topic), do: "masu:presence:" <> live_topic

  @doc false
  # The meta of this LiveView's user, as the grid tracks it: who they are,
  # and their view (the query's wire form), or nil when the grid keeps it
  # to itself (`share_view={false}`).
  @spec meta(map(), map() | nil) :: map()
  def meta(user, view \\ nil)

  def meta(%{id: _id} = user, view) do
    %{
      name: Map.get(user, :name),
      color: color(user),
      avatar: Map.get(user, :avatar),
      cell: nil,
      range: nil,
      editing: false,
      view: view,
      top: nil
    }
  end

  def meta(user, _view),
    do: raise(ArgumentError, "a Masu grid's user is a map with an :id, got: #{inspect(user)}")

  @doc false
  @spec track(module(), String.t(), map(), map() | nil) :: :ok
  def track(presence, live_topic, user, view \\ nil) do
    {:ok, _ref} =
      presence.track(self(), topic(live_topic), to_string(user.id), meta(user, view))

    :ok
  end

  @doc false
  @spec untrack(module(), String.t(), map()) :: :ok
  def untrack(presence, live_topic, user) do
    presence.untrack(self(), topic(live_topic), to_string(user.id))
  end

  @doc false
  # Where this LiveView's user is now, any of: `cell` ([row id, column
  # key] or nil), `range` (`%{"rows" => ids, "keys" => keys}` or nil),
  # `editing`, `top` (the id of the first row on their screen) and `view`.
  @spec update(module(), String.t(), map(), map()) :: :ok
  def update(presence, live_topic, user, changes) do
    {:ok, _ref} =
      presence.update(self(), topic(live_topic), to_string(user.id), &Map.merge(&1, changes))

    :ok
  end

  @doc false
  # The other people of the topic: one a user, the tab that moved last
  # (the one with a cell, else the first).
  @spec people(module(), String.t(), map()) :: [person()]
  def people(presence, live_topic, user) do
    own = to_string(user.id)

    for {id, %{metas: metas}} <- presence.list(topic(live_topic)), id != own do
      meta = Enum.find(Enum.reverse(metas), &(&1.cell != nil)) || hd(metas)

      %{
        id: id,
        name: meta.name,
        color: meta.color,
        avatar: meta.avatar,
        initials: initials(meta.name || id),
        cell: meta.cell,
        range: Map.get(meta, :range),
        editing: meta.editing,
        view: Map.get(meta, :view),
        top: Map.get(meta, :top)
      }
    end
    |> Enum.sort_by(&{&1.name || "", &1.id})
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

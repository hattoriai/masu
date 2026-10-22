defmodule MasuTest.Collaboration do
  @moduledoc "The Issho policy of the test app: anyone in any room, but the reader writes nowhere."
  @behaviour Issho.Policy

  @impl true
  def authorize(%Issho.Identity{key: "agent:reader"}, _room, action)
      when action in [:write, :lock],
      do: {:error, :forbidden}

  def authorize(_identity, _room, _action), do: :ok

  @impl true
  def document(_identity, _id), do: {:error, :not_found}
end

defmodule MasuTest.PresenceLive do
  @moduledoc "A grid that shows who else has it open, in an Issho room; the user and the room come from the URL."
  use Phoenix.LiveView

  import Masu.Components

  on_mount(Masu.Live)
  on_mount(Issho.Live)

  @impl true
  def mount(params, _session, socket) do
    user = %{id: params["user"], name: String.capitalize(params["user"])}
    user = if params["color"], do: Map.put(user, :color, params["color"]), else: user
    # ?id= the grid's id (an embed's), ?grid= its name in the room,
    # ?can=read a reader's, ?two=1 another grid of the room beside it.
    issho =
      [instance: MasuTest.Issho, room: params["room"] || "presence"] ++
        if(params["grid"], do: [grid: params["grid"]], else: []) ++
        if(params["can"] == "read", do: [can: :read], else: [])

    {:ok,
     assign(socket,
       user: user,
       issho: issho,
       topic: "presence-" <> (params["room"] || "people"),
       slot: params["slot"] == "1",
       share: params["share"] != "0",
       follow: params["follow"] != "0",
       id: params["id"] || "people",
       two: params["two"] == "1"
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%= if @slot do %>
      <.data_grid id="people" rows={MasuTest.People.all()} changeset={&MasuTest.EditPeopleLive.changeset/2}
        live={{MasuTest.PubSub, @topic}} issho={@issho} user={@user}>
        <:col field={:name} />
        <:person :let={person}><b class="mine">{person.name} ({person.initials})</b></:person>
      </.data_grid>
    <% else %>
      <.data_grid id={@id} rows={MasuTest.People.all()} changeset={&MasuTest.EditPeopleLive.changeset/2}
        live={{MasuTest.PubSub, @topic}} issho={@issho} user={@user}
        share_view={@share}
        follow={@follow}>
        <:col field={:name} />
      </.data_grid>
      <.data_grid :if={@two} id="others" rows={MasuTest.People.all()}
        issho={Keyword.put(@issho, :grid, "others")} user={@user}>
        <:col field={:name} />
      </.data_grid>
    <% end %>
    """
  end
end

defmodule MasuTest.Presence do
  @moduledoc "The Phoenix.Presence of the test app."
  use Phoenix.Presence, otp_app: :masu, pubsub_server: MasuTest.PubSub
end

defmodule MasuTest.PresenceLive do
  @moduledoc "A grid that shows who else has it open; the user comes from the URL."
  use Phoenix.LiveView

  import Masu.Components

  on_mount(Masu.Live)

  @impl true
  def mount(params, _session, socket) do
    user = %{id: params["user"], name: String.capitalize(params["user"])}
    user = if params["color"], do: Map.put(user, :color, params["color"]), else: user
    {:ok, assign(socket, user: user, slot: params["slot"] == "1", share: params["share"] != "0")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%= if @slot do %>
      <.data_grid id="people" rows={MasuTest.People.all()} changeset={&MasuTest.EditPeopleLive.changeset/2}
        live={{MasuTest.PubSub, "presence-people"}} presence={MasuTest.Presence} user={@user}>
        <:col field={:name} />
        <:person :let={person}><b class="mine">{person.name} ({person.initials})</b></:person>
      </.data_grid>
    <% else %>
      <.data_grid id="people" rows={MasuTest.People.all()} changeset={&MasuTest.EditPeopleLive.changeset/2}
        live={{MasuTest.PubSub, "presence-people"}} presence={MasuTest.Presence} user={@user}
        share_view={@share}>
        <:col field={:name} />
      </.data_grid>
    <% end %>
    """
  end
end

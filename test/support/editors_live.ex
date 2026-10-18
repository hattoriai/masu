defmodule MasuTest.EditorsLive do
  @moduledoc """
  Editors of the app's own: a form of HEEx for a column (a name, and a
  stay of two days that posts `from` and `to`), and an editor of the
  browser's by name (a color, with options).
  """
  use Phoenix.LiveView

  import Ecto.Changeset
  import Masu.Components

  @types %{name: :string, stay: :map, color: :string}

  @impl true
  def mount(_params, _session, socket) do
    rows = [
      %{
        id: 1,
        name: "Ada",
        stay: %{"from" => "2027-03-15", "to" => "2027-03-20"},
        color: "#ff0000",
        locked: false
      },
      %{id: 2, name: "Grace", stay: nil, color: nil, locked: true}
    ]

    {:ok, assign(socket, rows: rows)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.data_grid id="people" rows={@rows} changeset={&changeset/2} scope={%{user: "ada"}} sort={[:id]}>
      <:col field={:name} editor={&name_editor/1} editable={&(!&1.locked)} />
      <:col field={:stay} editor={&stay_editor/1} />
      <:col field={:color} editor={{"color", %{swatches: ["#ff0000", "#00ff00"]}}} />
    </.data_grid>
    """
  end

  defp name_editor(assigns) do
    ~H"""
    <input id="name-input" type="text" name={@field.name} value={@field.value} aria-labelledby={@label_id} />
    <p id="name-editor-of">{@id} {@column.key} {@row.name} {@scope.user}</p>
    """
  end

  defp stay_editor(assigns) do
    ~H"""
    <input id="stay-from" type="date" name={@field.name <> "[from]"} value={@value && @value["from"]} />
    <input id="stay-to" type="date" name={@field.name <> "[to]"} value={@value && @value["to"]} />
    """
  end

  def changeset(row, params) do
    {row, @types}
    |> cast(params, Map.keys(@types))
    |> validate_required([:name])
    |> validate_change(:stay, fn :stay, stay ->
      if stay["from"] <= stay["to"], do: [], else: [stay: "ends before it starts"]
    end)
  end
end

defmodule MasuTest.Stay do
  @moduledoc "A stay of days, which shows as a range (Masu.Wire)."
  defstruct [:from, :to]
end

defimpl Masu.Wire, for: MasuTest.Stay do
  def to_wire(stay), do: "#{stay.from}/#{stay.to}"
end

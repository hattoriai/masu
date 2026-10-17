defmodule Masu.Action do
  @moduledoc """
  An item of a grid's menus of your own: in a column's header menu
  (`:header_action`), or in the menu of a cell (`:cell_action`), which a
  right click opens, or the context-menu key or Shift+F10 on the active
  cell.

      <.data_grid id="orders" source={Order} repo={Repo} cell_menu>
        <:col field={:customer} />
        <:col field={:total} type={:decimal} />

        <:header_action label="Explain" on_action={&explain/1} />
        <:cell_action label="Open the customer" event="open_customer" columns={["customer"]} />
        <:cell_action label="Copy a link" js={JS.dispatch("app:copy-link")} />
        <:header_action :let={action} label="Column stats" types={[:integer, :decimal]}>
          <.stats column={action.column} />
        </:header_action>
      </.data_grid>

  An item does one or more of:

    * `on_action` - a function of the item's context, called in the
      LiveView's process (as `on_select` is);
    * `event` - a name: the LiveView gets `{Masu.Action, name, context}`
      in its `handle_info/2`, to change its own assigns (open a modal,
      navigate);
    * `js` - a `Phoenix.LiveView.JS` command, run in the browser on the
      grid's element; the element gets a `masu:action` event first, whose
      `detail` is the context as the browser has it;
    * content - a panel of your own, which the server renders with the
      context (`:let`) under the header or the cell, until the person
      closes it (Escape, or a click away).

  The context is a map:

    * `grid` - the id of the grid;
    * `column` - the key of the column;
    * for a cell: `id`, the row's id, `row`, the row as the source reads
      it, and `value`, the cell's value; read on the server, not taken
      from the browser;
    * for a cell in a selected range: `range`, `%{ids: ids, columns:
      keys}`, the rows (up to 10,000) and the columns of the range; the
      ids are the browser's, which an item checks as it checks any
      params.

  In the browser, the context has the column's key, the row's id, and
  the value as the browser shows it.

  `columns` (keys) and `types` limit the columns an item is for, and
  `show`, a function of the `Masu.Column`, too; `:if` leaves an item out
  altogether (`:if={@admin?}`). The server runs only the items that the
  grid offers for the column.
  """

  alias Masu.Column
  alias Phoenix.LiveView.JS

  @type kind :: :header | :cell

  @type t :: %__MODULE__{
          kind: kind(),
          index: non_neg_integer(),
          label: String.t(),
          on_action: (map() -> term()) | nil,
          event: String.t() | nil,
          js: String.t() | nil,
          columns: [String.t()] | nil,
          types: [Column.type()] | nil,
          show: (Column.t() -> boolean()) | nil,
          slot: map() | nil
        }

  defstruct [:kind, :index, :label, :on_action, :event, :js, :columns, :types, :show, :slot]

  @doc false
  # The items of a slot (`:header_action` or `:cell_action`), each with
  # its place in it: the id the browser gives back.
  @spec all([map()], kind()) :: [t()]
  def all(entries, kind) do
    entries
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} -> new(entry, kind, index) end)
  end

  defp new(entry, kind, index) do
    label = Map.get(entry, :label) || raise ArgumentError, "a :#{kind}_action needs a label"
    on_action = Map.get(entry, :on_action)

    unless is_nil(on_action) or is_function(on_action, 1) do
      raise ArgumentError, "the on_action of #{inspect(label)} must be a function of one argument"
    end

    action = %__MODULE__{
      kind: kind,
      index: index,
      label: label,
      on_action: on_action,
      event: Map.get(entry, :event),
      js: encode_js(Map.get(entry, :js)),
      columns: entry |> Map.get(:columns) |> keys(),
      types: Map.get(entry, :types),
      show: Map.get(entry, :show),
      slot: if(Map.get(entry, :inner_block), do: entry)
    }

    if action.on_action || action.event || action.js || action.slot do
      action
    else
      raise ArgumentError,
            "the :#{kind}_action #{inspect(label)} does nothing: give it on_action, event, js or content"
    end
  end

  defp keys(nil), do: nil
  defp keys(keys), do: Enum.map(keys, &to_string/1)

  defp encode_js(nil), do: nil

  defp encode_js(%JS{} = js), do: js |> JS.to_encodable() |> JSON.encode!()

  @doc false
  # Whether the item is for the column.
  @spec for?(t(), Column.t()) :: boolean()
  def for?(%__MODULE__{} = action, %Column{} = column) do
    (is_nil(action.columns) or column.key in action.columns) and
      (is_nil(action.types) or column.type in action.types) and
      (is_nil(action.show) or action.show.(column) == true)
  end

  @doc false
  # Whether the item does something on the server: a function, an event
  # or a panel.
  @spec server?(t()) :: boolean()
  def server?(%__MODULE__{} = action),
    do: action.on_action != nil or action.event != nil or action.slot != nil

  @doc false
  # The items of a column, as the browser gets them.
  @spec to_wire([t()], Column.t()) :: [map()]
  def to_wire(actions, %Column{} = column) do
    for action <- actions, for?(action, column) do
      %{
        "id" => action.index,
        "label" => action.label,
        "server" => action.on_action != nil or action.event != nil,
        "js" => action.js,
        "panel" => action.slot != nil
      }
    end
  end

  @doc false
  # Runs an item on the server: its function, and its event to the
  # LiveView (this process).
  @spec run(t(), map()) :: :ok
  def run(%__MODULE__{} = action, context) do
    if action.on_action, do: action.on_action.(context)
    if action.event, do: send(self(), {__MODULE__, action.event, context})
    :ok
  end
end

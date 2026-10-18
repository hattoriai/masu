defmodule Masu.Action do
  @moduledoc """
  Actions of your own, on a grid: on the rows selected (`:action`), on a
  row (`:row_action`), and items of its menus, in a column's header menu
  (`:header_action`) or in the menu of a cell (`:cell_action`).

      <.data_grid id="orders" source={Order} repo={Repo} selectable cell_menu scope={@current_scope}>
        <:col field={:customer} />
        <:col field={:total} type={:decimal} />

        <:action label="Archive" on_action={&OrdersGrid.archive/1} />
        <:action :if={@admin?} label="Delete" on_action={&OrdersGrid.delete/1}
          confirm="Delete {count} orders?" danger />

        <:row_action label="Open" navigate={&~p"/orders/\#{&1}"} />
        <:row_action label="Send again" on_action={&OrdersGrid.resend/1}
          disabled={&(&1.status == "draft")} />

        <:header_action label="Explain" on_action={&explain/1} />
        <:cell_action label="Open the customer" event="open_customer" columns={["customer"]} />
        <:cell_action label="Copy a link" js={JS.dispatch("app:copy-link")} />
        <:header_action :let={action} label="Column stats" types={[:integer, :decimal]}>
          <.stats column={action.column} />
        </:header_action>
      </.data_grid>

  ## Where they are

    * `:action` - a button of the bar above the grid while rows are
      selected ("4 selected · Archive · Delete · Clear"); it needs
      `selectable`;
    * `:row_action` - an item of the menu at the end of each row (its
      button, a right click, or the context-menu key or Shift+F10 on the
      row), and of the menu of its cells;
    * `:header_action` - an item of a column's header menu;
    * `:cell_action` - an item of the menu of a cell (a right click, or
      the context-menu key or Shift+F10 on the active cell).

  ## What an action does

    * `on_action` - a function of the action's context, called in the
      LiveView's process (as `on_select` is), which gives its result
      (below);
    * `event` - a name: the LiveView gets `{Masu.Action, name, context}`
      in its `handle_info/2`, to change its own assigns (open a modal,
      navigate);
    * `navigate` and `patch` (`:row_action`) - a function of the row
      that gives a path: the item is a link, which a middle click opens
      in a tab and a right click copies;
    * `js` (`:header_action`, `:cell_action`) - a `Phoenix.LiveView.JS`
      command, run in the browser on the grid's element; the element
      gets a `masu:action` event first, whose `detail` is the context as
      the browser has it;
    * content (`:header_action`, `:cell_action`) - a panel of your own,
      which the server renders with the context (`:let`) under the
      header or the cell, until the person closes it (Escape, or a click
      away).

  ## The context

  A map:

    * `grid` - the id of the grid;
    * `scope` - the grid's `scope` (`@current_scope`);
    * `ref` - the action's reference, for `:async` and `Masu.reply/2`;
    * for the rows selected: `selected`, as `Masu.Live.selected/1` gives
      it (`{:ids, ids}`, or `{:query, query}` when the person selected
      every row of an Ecto source's query: an action on a million rows
      is one `Repo.update_all/3`), and `count`;
    * for a row: `id`, `row`, the row as the source reads it now, and
      `editors`, the people (`Masu.Presence`) whose editor is open on a
      cell of the row;
    * for a header or a cell: `column`, the key of the column;
    * for a cell: `id`, `row`, `value`, the cell's value; read on the
      server, not taken from the browser;
    * for a cell in a selected range: `range`, `%{ids: ids, columns:
      keys}`, the rows (up to 10,000) and the columns of the range; the
      ids are the browser's, which an action checks as it checks any
      params.

  In the browser (`js`), the context has the column's key, the row's id,
  and the value as the browser shows it.

  ## The result

  `on_action` gives one of:

    * `:ok` (or any other value) - done;
    * `{:ok, message}` - done, and the grid says `message` (to a screen
      reader too);
    * `{:error, message}` - it failed: the grid says so;
    * `:async` - it goes on in another process (an Oban job, a task),
      which says how it went with `Masu.reply(context.ref, result)`, and
      how far it is with `Masu.progress/3`. The grid shows it running
      meanwhile.

  After an action on the rows selected, or on a row, that is done (or
  replied `:ok`), the grid reads its rows again, and the selection is
  cleared (`keep_selection` keeps it). A failed action keeps it.

  An action of a LiveView's own (to change its assigns, run it with
  `start_async/3`) sends itself a message, and replies when it is done:

      <:action label="Archive" on_action={&send(self(), {:archive, &1})} ... />

      def handle_info({:archive, context}, socket) do
        socket =
          start_async(socket, :archive, fn ->
            Orders.archive(context.scope, context.selected)
            Masu.reply(context.ref, {:ok, "\#{context.count} orders archived"})
          end)

        {:noreply, socket}
      end

  …with `on_action` giving `:async`: `&(send(self(), {:archive, &1}) && :async)`.

  ## Which actions a grid offers

  `:if` leaves an action out altogether (`:if={@admin?}`). `columns`
  (keys) and `types` limit the columns of a header or cell item, and
  `show`, a function of the `Masu.Column`, too. A row action's `show` is
  a function of the row: the row has the item or not; its `disabled`, a
  function of the row (or a boolean), shows it unavailable.

  `confirm` asks first: "Delete {count} orders?" (`{count}` is the rows
  selected); `danger` shows the action as one that destroys.

  The server runs only the actions that the grid offers, for the column
  and for the row: one left out by `:if`, hidden or disabled for the row
  (read again from the source), or with no selection, is refused.
  """

  alias Masu.Column
  alias Phoenix.LiveView.JS

  @type kind :: :header | :cell | :selection | :row

  @typedoc "What an action's `on_action` gives."
  @type result :: :ok | {:ok, String.t()} | {:error, String.t()} | :async

  @type t :: %__MODULE__{
          kind: kind(),
          index: non_neg_integer(),
          label: String.t(),
          on_action: (map() -> term()) | nil,
          event: String.t() | nil,
          js: String.t() | nil,
          navigate: (term() -> String.t()) | nil,
          patch: (term() -> String.t()) | nil,
          columns: [String.t()] | nil,
          types: [Column.type()] | nil,
          show: (term() -> boolean()) | nil,
          disabled: (term() -> boolean()) | boolean(),
          confirm: String.t() | nil,
          danger: boolean(),
          keep_selection: boolean(),
          slot: map() | nil
        }

  defstruct [
    :kind,
    :index,
    :label,
    :on_action,
    :event,
    :js,
    :navigate,
    :patch,
    :columns,
    :types,
    :show,
    :confirm,
    :slot,
    disabled: false,
    danger: false,
    keep_selection: false
  ]

  @doc false
  # The items of a slot, each with its place in it: the id the browser
  # gives back.
  @spec all([map()], kind()) :: [t()]
  def all(entries, kind) do
    entries
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} -> new(entry, kind, index) end)
  end

  defp new(entry, kind, index) do
    name = slot_name(kind)
    label = Map.get(entry, :label) || raise ArgumentError, "a :#{name} needs a label"

    for attr <- [:on_action, :navigate, :patch, :show],
        fun = Map.get(entry, attr),
        not is_function(fun, 1) do
      raise ArgumentError, "the #{attr} of #{inspect(label)} must be a function of one argument"
    end

    disabled = Map.get(entry, :disabled, false)

    unless is_boolean(disabled) or is_function(disabled, 1) do
      raise ArgumentError,
            "the disabled of #{inspect(label)} is a boolean or a function of the row"
    end

    action = %__MODULE__{
      kind: kind,
      index: index,
      label: label,
      on_action: Map.get(entry, :on_action),
      event: Map.get(entry, :event),
      js: encode_js(Map.get(entry, :js)),
      navigate: Map.get(entry, :navigate),
      patch: Map.get(entry, :patch),
      columns: entry |> Map.get(:columns) |> keys(),
      types: Map.get(entry, :types),
      show: Map.get(entry, :show),
      disabled: disabled,
      confirm: Map.get(entry, :confirm),
      danger: Map.get(entry, :danger, false) == true,
      keep_selection: Map.get(entry, :keep_selection, false) == true,
      slot: if(Map.get(entry, :inner_block), do: entry)
    }

    check!(action, name)
  end

  # What each kind of action may do.
  defp check!(%{kind: kind} = action, name) when kind in [:header, :cell] do
    if action.navigate || action.patch do
      raise ArgumentError,
            "the :#{name} #{inspect(action.label)} has navigate or patch, which are for a :row_action"
    end

    if action.on_action || action.event || action.js || action.slot do
      action
    else
      raise ArgumentError,
            "the :#{name} #{inspect(action.label)} does nothing: give it on_action, event, js or content"
    end
  end

  defp check!(%{kind: :selection} = action, name) do
    if action.js || action.slot || action.navigate || action.patch do
      raise ArgumentError,
            "the :#{name} #{inspect(action.label)} acts on the rows selected: give it on_action or event"
    end

    if action.on_action || action.event,
      do: action,
      else:
        raise(
          ArgumentError,
          "the :#{name} #{inspect(action.label)} does nothing: give it on_action or event"
        )
  end

  defp check!(%{kind: :row} = action, name) do
    links = Enum.count([action.navigate, action.patch], & &1)
    runs = Enum.count([action.on_action, action.event], & &1)

    cond do
      action.js || action.slot ->
        raise ArgumentError,
              "the :#{name} #{inspect(action.label)} acts on a row: give it on_action, event, navigate or patch"

      links > 1 or (links == 1 and runs > 0) ->
        raise ArgumentError,
              "the :#{name} #{inspect(action.label)} is a link (navigate or patch) or runs (on_action, event), not both"

      links + runs == 0 ->
        raise ArgumentError,
              "the :#{name} #{inspect(action.label)} does nothing: give it on_action, event, navigate or patch"

      true ->
        action
    end
  end

  defp slot_name(:selection), do: "action"
  defp slot_name(kind), do: "#{kind}_action"

  defp keys(nil), do: nil
  defp keys(keys), do: Enum.map(keys, &to_string/1)

  defp encode_js(nil), do: nil

  # Its ops, as Phoenix.HTML.Safe gives them (JS.to_encodable/1 is of newer
  # LiveViews).
  defp encode_js(%JS{ops: ops}), do: JSON.encode!(ops)

  @doc false
  # Whether a header or cell item is for the column.
  @spec for?(t(), Column.t()) :: boolean()
  def for?(%__MODULE__{} = action, %Column{} = column) do
    (is_nil(action.columns) or column.key in action.columns) and
      (is_nil(action.types) or column.type in action.types) and
      (is_nil(action.show) or action.show.(column) == true)
  end

  @doc false
  # Whether a row action is on the row, and whether it is available.
  @spec shown?(t(), term()) :: boolean()
  def shown?(%__MODULE__{show: nil}, _row), do: true
  def shown?(%__MODULE__{show: show}, row), do: show.(row) == true

  @doc false
  @spec disabled?(t(), term()) :: boolean()
  def disabled?(%__MODULE__{disabled: disabled}, _row) when is_boolean(disabled), do: disabled
  def disabled?(%__MODULE__{disabled: disabled}, row), do: disabled.(row) == true

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
  # The actions on the selection, or on rows, as the browser gets them;
  # a row's own state (shown, disabled, its link) comes with the row.
  @spec to_wire([t()]) :: [map()]
  def to_wire(actions) do
    for action <- actions do
      %{
        "id" => action.index,
        "label" => action.label,
        "link" => (action.navigate && "navigate") || (action.patch && "patch"),
        "confirm" => action.confirm,
        "danger" => action.danger
      }
    end
  end

  @doc false
  # The row actions of a row, as the row carries them: `[id, disabled,
  # href]` for each that it shows.
  @spec row_wire([t()], term()) :: [list()]
  def row_wire(actions, row) do
    for action <- actions, shown?(action, row) do
      [action.index, disabled?(action, row), href(action, row)]
    end
  end

  @doc false
  @spec href(t(), term()) :: String.t() | nil
  def href(%__MODULE__{navigate: fun}, row) when is_function(fun, 1), do: to_string(fun.(row))
  def href(%__MODULE__{patch: fun}, row) when is_function(fun, 1), do: to_string(fun.(row))
  def href(_action, _row), do: nil

  @doc false
  # Runs an item on the server: its function, and its event to the
  # LiveView (this process). Gives its result.
  @spec run(t(), map()) :: :ok | {:ok, String.t()} | {:error, String.t()} | :async
  def run(%__MODULE__{} = action, context) do
    result = if action.on_action, do: action.on_action.(context), else: :ok
    if action.event, do: send(self(), {__MODULE__, action.event, context})

    case result do
      {:ok, message} when is_binary(message) -> {:ok, message}
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, "The action failed: #{inspect(reason)}"}
      :async -> :async
      _done -> :ok
    end
  end
end

defmodule Masu.Grid do
  @moduledoc """
  The LiveComponent behind `Masu.Components.data_grid/1`.

  Render the grid with `data_grid/1`, not with this module: it is public
  for its events, which the browser sends and `Masu.Test` sends in tests.

  The component holds the grid's source (`Masu.Source`) and query
  (`Masu.Query`). The browser asks it for blocks of rows:

    * `"masu:rows"` with `from` and `count`: the rows of the current query
      from row `from`, at most 500 of them;
    * `"masu:query"` with `sorts`, `filters` and `search`: applies a new
      query, and answers with its count and its first rows;
    * `"masu:values"` with `key`: the values of a column, for its filter
      menu;
    * `"masu:edit"` with `edits`, a list of `id`, `key` and `value`: saves
      the edits of each row together (see `Masu.Components.data_grid/1`'s
      `changeset` and `update`), and answers with the errors of the cells
      that were not saved.

  Each answer carries the grid's `revision`, which changes whenever its
  rows do (a new query, or new rows from the LiveView), so that the
  browser drops the blocks of an older one.

  A row goes to the browser as a list: its id, then a value for each
  column, the column's value in JSON (see `Masu.Column` for the types) or,
  for a column with content, the HTML of its cell (with its value, as
  `[html, value]`, when the column is editable). In a grid whose cells
  edit by the row's state (`row_editable`, or a column's `editable`
  function), a row ends with its read-only cells: `true` for every cell,
  or the indexes of their columns.
  """

  use Phoenix.LiveComponent

  alias Masu.{Column, Query, Source, Value}
  alias Phoenix.HTML.Safe

  @max_block 500
  @first_block 100
  @initial_rows 60

  @messages %{
    "search" => "Search",
    "empty" => "No rows",
    "row" => "{count} row",
    "rows" => "{count} rows",
    "loading" => "Loading",
    "people" => "Also here",
    "follow" => "Follow {label}"
  }

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       source: nil,
       input: nil,
       revision: 0,
       initial: nil,
       followed: nil,
       changed: [],
       changed_by: %{},
       tracked: nil,
       people: [],
       saved_by: %{}
     )}
  end

  @impl true
  def update(%{masu_presence: true}, socket), do: {:ok, refresh_people(socket)}

  def update(%{masu_changes: true}, socket) do
    case Masu.Live.take(socket.assigns.id) do
      [] -> {:ok, socket}
      changes -> {:ok, take_changes(socket, changes)}
    end
  end

  def update(assigns, socket) do
    socket = assign(socket, Map.drop(assigns, [:input]))
    columns = Enum.map(assigns.col, &Column.new/1)

    socket =
      cond do
        is_nil(socket.assigns.source) -> start(socket, assigns.input, columns)
        assigns.input != socket.assigns.input -> restart(socket, assigns.input, columns)
        true -> assign(socket, columns: supported(socket.assigns.source, columns, socket.assigns))
      end

    {:ok, follow(socket)}
  end

  # The topic of `live`, followed in the connected LiveView only.
  defp follow(%{assigns: %{live: live, followed: live}} = socket), do: socket

  defp follow(socket) do
    if connected?(socket) do
      :ok = Masu.Live.follow(socket.assigns.id, socket.assigns.followed, socket.assigns.live)
      socket |> assign(followed: socket.assigns.live) |> track()
    else
      socket
    end
  end

  # The people of the grid's topic (Masu.Presence): this LiveView's user
  # is tracked once, and the grid draws the others.
  defp track(%{assigns: %{presence: nil}} = socket), do: socket
  defp track(%{assigns: %{live: nil}} = socket), do: socket

  defp track(%{assigns: %{presence: presence, live: {pubsub, topic}, user: user}} = socket) do
    if socket.assigns.tracked != topic do
      if socket.assigns.tracked, do: Masu.Presence.untrack(presence, socket.assigns.tracked, user)
      :ok = Masu.Live.follow_presence(pubsub, topic)
      :ok = Masu.Presence.track(presence, topic, user)
    end

    socket |> assign(tracked: topic) |> refresh_people()
  end

  defp refresh_people(%{assigns: %{presence: presence, tracked: topic, user: user}} = socket)
       when is_binary(topic) do
    people = Masu.Presence.people(presence, topic, user)

    socket
    |> assign(people: people)
    |> push_event("masu:people", %{
      "id" => socket.assigns.id,
      "people" => Enum.map(people, &Map.take(&1, [:id, :name, :color, :cell, :range, :editing]))
    })
  end

  defp refresh_people(socket), do: socket

  # Changes from the topic: the source takes them and applies the query
  # again; the browser asks again for the rows it shows, and highlights
  # the changed ones.
  defp take_changes(socket, by_changes) do
    %{source: source, query: query, columns: columns, revision: revision} = socket.assigns
    row_id = row_id(socket.assigns)

    changes = Enum.map(by_changes, &without_by/1)

    changed =
      for {:upsert, row} <- changes, uniq: true, do: Value.to_wire(row_id.(row))

    changed_by =
      for {:upsert, row, %{color: color}} <- by_changes,
          into: %{},
          do: {to_string(Value.to_wire(row_id.(row))), color}

    source = source |> Source.change(changes, row_id) |> Source.prepare(query, columns)

    # Who saved each row last, for a refusal that names them ("Changed by
    # Ada meanwhile.").
    saved_by =
      for {:upsert, row, %{name: name}} when is_binary(name) <- by_changes,
          into: socket.assigns.saved_by,
          do: {Value.to_wire(row_id.(row)), name}

    assign(socket,
      saved_by: saved_by,
      source: source,
      total: Source.count(source),
      revision: revision + 1,
      initial: nil,
      changed: changed,
      changed_by: changed_by
    )
  end

  # A change from a grid's edit says who saved it; the source does not need it.
  defp without_by({:upsert, row, _by}), do: {:upsert, row}
  defp without_by(change), do: change

  defp start(socket, input, columns) do
    source = Source.new(input, source_opts(socket.assigns))
    columns = supported(source, columns, socket.assigns)

    query =
      case Query.new([sort: socket.assigns.sort, filters: socket.assigns.filters], columns) do
        {:ok, query} -> query
        {:error, reason} -> raise ArgumentError, "grid #{socket.assigns.id}: #{reason}"
      end

    source = Source.prepare(source, query, columns)

    socket
    |> assign(input: input, source: source, columns: columns, query: query)
    |> assign(total: Source.count(source))
    |> assign(initial: Source.rows(source, 0, @initial_rows))
  end

  # New rows (or a new query of the LiveView): the person's order, filters
  # and search stay, and the browser drops the rows it has.
  defp restart(socket, input, columns) do
    source = Source.new(input, source_opts(socket.assigns))
    columns = supported(source, columns, socket.assigns)
    source = Source.prepare(source, socket.assigns.query, columns)

    assign(socket,
      input: input,
      source: source,
      columns: columns,
      total: Source.count(source),
      revision: socket.assigns.revision + 1,
      initial: nil,
      changed: []
    )
  end

  defp source_opts(assigns),
    do: [repo: assigns.repo, repo_opts: assigns.repo_opts, grid: assigns.id]

  # A column that the source cannot sort or filter by does neither. A
  # column is editable when the grid edits, and it names a field.
  defp supported(source, columns, assigns) do
    edits? = assigns.changeset != nil or assigns.update != nil

    Enum.map(columns, fn column ->
      column = %{
        column
        | editable:
            edits? and column.editable != false and is_nil(column.value) and
              not is_nil(column.field)
      }

      if Source.supports?(source, column),
        do: column,
        else: %{column | sortable: false, filterable: false, searchable: false}
    end)
  end

  @impl true
  def handle_event("masu:rows", %{"from" => from, "count" => count}, socket)
      when is_integer(from) and is_integer(count) do
    from = max(from, 0)
    count = count |> max(0) |> min(@max_block)
    {:reply, block(socket, from, count), socket}
  end

  # The values of a column for its filter menu: among the rows of the
  # query without the column's own filters, so that the menu offers the
  # values the person may add.
  def handle_event("masu:values", %{"key" => key} = params, socket) when is_binary(key) do
    %{source: source, query: query, columns: columns} = socket.assigns

    case Column.find(columns, key) do
      %Column{filterable: true} = column ->
        others = %{query | filters: Enum.reject(query.filters, &(&1.key == key))}
        search = if is_binary(params["search"]), do: String.trim(params["search"])
        values = Source.values(source, column, others, columns, search: search, limit: 50)

        {:reply,
         %{"key" => key, "values" => Enum.map(values, fn {v, n} -> [Value.to_wire(v), n] end)},
         socket}

      _other ->
        {:reply, %{"key" => key, "values" => []}, socket}
    end
  end

  # Edits of cells: saved, then the rows of the query again, as for a
  # live change. Other LiveViews that follow the grid's topic get the
  # saved rows; this one has them already.
  def handle_event("masu:edit", %{"edits" => edits}, socket) when is_list(edits) do
    row_id = row_id(socket.assigns)
    {saved, errors} = Masu.Edit.run(edits, socket.assigns, row_id)

    socket =
      if saved == [] do
        socket
      else
        %{source: source, query: query, columns: columns, revision: revision} = socket.assigns

        source =
          source
          |> Source.change(Enum.map(saved, &{:upsert, &1}), row_id)
          |> Source.prepare(query, columns)

        broadcast(socket.assigns.live, saved, socket.assigns.user)
        if is_function(socket.assigns.on_save, 1), do: socket.assigns.on_save.(saved)

        assign(socket,
          source: source,
          total: Source.count(source),
          revision: revision + 1,
          initial: nil,
          changed: []
        )
      end

    {:reply,
     %{
       "revision" => socket.assigns.revision,
       "rows" => encode_rows(saved, socket.assigns),
       "errors" => errors
     }, socket}
  end

  # The place of a row in this person's order: where to scroll to follow
  # another person (Masu.Presence).
  def handle_event("masu:locate", %{"id" => id}, socket) do
    index = Source.locate(socket.assigns.source, id, row_id(socket.assigns))
    {:reply, %{"index" => index, "revision" => socket.assigns.revision}, socket}
  end

  # Where this LiveView's user is in the grid, for the others (Masu.Presence).
  def handle_event("masu:cursor", %{"cell" => cell, "editing" => editing} = params, socket)
      when (is_nil(cell) or (is_list(cell) and length(cell) == 2)) and is_boolean(editing) do
    %{presence: presence, tracked: topic, user: user} = socket.assigns
    range = range(params["range"])

    if presence && topic,
      do: :ok = Masu.Presence.move(presence, topic, user, cell, range, editing)

    {:noreply, socket}
  end

  def handle_event("masu:query", params, socket) when is_map(params) do
    %{source: source, columns: columns, revision: revision} = socket.assigns

    case Query.from_wire(params, columns) do
      {:ok, query} ->
        source = Source.prepare(source, query, columns)

        socket =
          assign(socket,
            source: source,
            query: query,
            total: Source.count(source),
            revision: revision + 1,
            initial: nil,
            changed: []
          )

        reply =
          socket
          |> block(0, @first_block)
          |> Map.put("query", Query.to_wire(query))

        {:reply, reply, socket}

      {:error, reason} ->
        {:reply, %{"error" => reason, "revision" => revision}, socket}
    end
  end

  # A selected range goes to the others as its rows' ids (at most 500) and
  # its columns' keys: the rows are where each person's order puts them.
  defp range(%{"rows" => rows, "keys" => keys}) when is_list(rows) and is_list(keys),
    do: %{"rows" => Enum.take(rows, 500), "keys" => Enum.filter(keys, &is_binary/1)}

  defp range(_other), do: nil

  defp block(socket, from, count) do
    %{source: source, total: total, revision: revision} = socket.assigns
    rows = if count == 0, do: [], else: Source.rows(source, from, count)

    %{
      "from" => from,
      "rows" => encode_rows(rows, socket.assigns),
      "total" => total,
      "revision" => revision
    }
  end

  defp encode_rows(rows, assigns) do
    row_id = row_id(assigns)
    locks? = locks?(assigns)

    Enum.map(rows, fn row ->
      cells = [Value.to_wire(row_id.(row)) | cells(assigns.columns, row)]
      if locks?, do: cells ++ [locks(assigns, row)], else: cells
    end)
  end

  # A grid whose cells edit by row sends, after a row's cells, which are
  # read-only: `true` for the whole row, or the indexes of its columns.
  defp locks?(assigns),
    do: assigns.row_editable != nil or Enum.any?(assigns.columns, &(&1.editable_if != nil))

  defp locks(assigns, row) do
    if assigns.row_editable && assigns.row_editable.(row) == false do
      true
    else
      for {column, i} <- Enum.with_index(assigns.columns),
          column.editable and not Column.editable?(column, row),
          do: i
    end
  end

  defp broadcast(nil, _rows, _user), do: :ok

  defp broadcast({pubsub, topic}, rows, user) do
    by = if user, do: %{name: Map.get(user, :name), color: Masu.Presence.color(user)}
    for row <- rows, do: Masu.Live.broadcast_upsert_from(self(), pubsub, topic, row, by)
    :ok
  end

  defp row_id(assigns), do: assigns.row_id || (&default_row_id/1)

  defp cells(columns, row) do
    Enum.map(columns, fn
      %Column{slot: nil} = column ->
        column |> Column.get(row) |> Value.to_wire()

      # An editable column of HEEx sends its value too, for the editor.
      %Column{slot: slot, editable: true} = column ->
        [slot_html(slot, row), column |> Column.get(row) |> Value.to_wire()]

      %Column{slot: slot} ->
        slot_html(slot, row)
    end)
  end

  defp default_row_id(%{id: id}), do: id
  defp default_row_id(%{"id" => id}), do: id
  defp default_row_id(_row), do: nil

  defp slot_html(slot, row) do
    assigns = %{slot: slot, row: row}

    ~H"{render_slot([@slot], @row)}"
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:messages, Map.merge(@messages, stringify(assigns.messages)))
      |> assign(:cols, Enum.map_join(assigns.columns, " ", &"#{&1.width}px"))

    ~H"""
    <div
      id={@id}
      class={["masu", @class]}
      phx-hook="Masu"
      phx-target={@myself}
      data-masu={config(assigns)}
      {@rest}
    >
      <div :if={@presence} class="masu-people" role="group" aria-label={@messages["people"]}>
        <button
          :for={person <- Enum.take(@people, 5)}
          type="button"
          class="masu-person"
          style={"--masu-peer-color: #{person.color}"}
          title={person.name}
          aria-label={String.replace(@messages["follow"], "{label}", person.name || person.id)}
          data-person={person.id}
        >
          <%= if @person != [] do %>
            {render_slot(@person, person)}
          <% else %>
            <img :if={person.avatar} src={person.avatar} alt={person.name} />
            <span :if={!person.avatar} class="masu-initials" aria-hidden="true">
              {person.initials}
            </span>
          <% end %>
        </button>
        <span :if={length(@people) > 5} class="masu-person masu-people-more">
          +{length(@people) - 5}
        </span>
      </div>
      <div id={"#{@id}-ui"} class="masu-ui" phx-update="ignore">
        <div :if={@searchable} class="masu-toolbar">
          <input
            type="search"
            class="masu-search"
            placeholder={@messages["search"]}
            aria-label={@messages["search"]}
            aria-controls={"#{@id}-grid"}
            value={@query.search}
            autocomplete="off"
          />
        </div>
        <div
          id={"#{@id}-grid"}
          class="masu-grid"
          role="grid"
          tabindex="0"
          aria-label={@label}
          aria-labelledby={@label_id}
          aria-rowcount={@total + 1}
          aria-colcount={length(@columns)}
          aria-multiselectable="true"
          style={"--masu-cols: #{@cols}; --masu-row-height: #{@row_height}px; height: #{@height}"}
        >
          <div class="masu-head" role="rowgroup">
            <div class="masu-row masu-header" role="row" aria-rowindex="1">
              <div
                :for={{column, i} <- Enum.with_index(@columns, 1)}
                class={["masu-hcell", "masu-align-#{column.align}", column.sortable && "masu-sortable"]}
                role="columnheader"
                aria-colindex={i}
                aria-sort={aria_sort(@query, column)}
                data-key={column.key}
              >
                <span class="masu-label">{column.label}</span>
              </div>
            </div>
          </div>
          <div class="masu-body" role="rowgroup" style={"height: #{@total * @row_height}px"}>
            <div
              :for={{row, index} <- Enum.with_index(@initial || [])}
              class="masu-row"
              role="row"
              aria-rowindex={index + 2}
              style={"transform: translateY(#{index * @row_height}px)"}
            >
              <div
                :for={{column, i} <- Enum.with_index(@columns, 1)}
                class={["masu-cell", "masu-align-#{column.align}", "masu-type-#{column.type}"]}
                role="gridcell"
                aria-colindex={i}
              >
                <%= if column.slot do %>
                  {render_slot([column.slot], row)}
                <% else %>
                  {column |> Column.get(row) |> Value.to_wire()}
                <% end %>
              </div>
            </div>
          </div>
          <div class="masu-empty" hidden={@total > 0}>
            <%= if @empty != [] do %>
              {render_slot(@empty)}
            <% else %>
              {@messages["empty"]}
            <% end %>
          </div>
        </div>
        <div class="masu-status" role="status" aria-live="polite"></div>
      </div>
    </div>
    """
  end

  defp aria_sort(%Query{sorts: [%{key: key, direction: direction} | _]}, %Column{key: key}),
    do: if(direction == :asc, do: "ascending", else: "descending")

  defp aria_sort(_query, %Column{sortable: true}), do: "none"
  defp aria_sort(_query, _column), do: nil

  defp config(assigns) do
    JSON.encode!(%{
      "v" => 1,
      "columns" => Enum.map(assigns.columns, &column_config/1),
      "rowHeight" => assigns.row_height,
      "total" => assigns.total,
      "revision" => assigns.revision,
      "query" => Query.to_wire(assigns.query),
      "locale" => assigns.locale,
      "searchable" => assigns.searchable,
      "changed" => assigns.changed,
      "changedBy" => assigns.changed_by,
      "locks" => locks?(assigns),
      "presence" => assigns.presence != nil,
      "messages" => assigns.messages,
      "initial" =>
        assigns.initial && %{"from" => 0, "rows" => encode_rows(assigns.initial, assigns)}
    })
  end

  defp column_config(%Column{} = column) do
    %{
      "key" => column.key,
      "label" => column.label,
      "type" => Atom.to_string(column.type),
      "width" => column.width,
      "minWidth" => column.min_width,
      "align" => Atom.to_string(column.align),
      "sortable" => column.sortable,
      "filterable" => column.filterable,
      "editable" => column.editable,
      "html" => column.slot != nil
    }
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end

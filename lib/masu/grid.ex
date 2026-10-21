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

  alias Masu.{Action, Column, Filter, Group, Input, Layout, Query, Source, Tree, Value, View}
  alias Masu.Export.{Download, Ticket}
  alias Masu.Source.Ecto, as: EctoSource
  alias Masu.Source.Given
  alias Masu.Source.List, as: ListSource
  alias Phoenix.HTML.Safe

  # The rows the server renders before the browser takes over.
  @initial_rows 60
  # Rows open on their detail at once: opening one more closes the first.
  @max_details 50

  # The words the server renders (Masu.Messages has all of them).
  @messages Map.take(
              Masu.Messages.defaults(),
              ~w(search empty row rows loading people follow view_dropped detail pages page of_pages previous next range running stop retry timeout failed)
            )

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
       issho: nil,
       issho_config: nil,
       show_people: true,
       saved_by: %{},
       all_columns: [],
       layout: nil,
       default_view: nil,
       view_params: %{},
       uri: nil,
       notice: nil,
       saved_views: [],
       initial_nodes: nil,
       open_details: [],
       detail_rows: [],
       selection: %{all: false, ids: MapSet.new(), except: MapSet.new()},
       trash: [],
       total: 0,
       exact: true,
       count_ref: 0,
       page: 0,
       initial_from: 0,
       header_actions: [],
       cell_actions: [],
       actions: [],
       row_actions: [],
       scope: nil,
       pending: %{},
       cell_menu: [],
       action_panel: nil,
       cell_editor: nil,
       history: nil,
       column_specs: nil,
       types: %{},
       load: :inline,
       timeout: nil,
       running: nil,
       read: nil,
       error: nil,
       on_query: nil,
       given_total: nil,
       given_loading: false,
       awaiting: false,
       multi_sort: true
     )}
  end

  @impl true
  def update(%{masu_presence: true}, socket), do: {:ok, refresh_people(socket)}

  # The room's people moved, came or went (Masu.Issho.Live).
  def update(%{issho: {event, _room, _payload}}, socket) when event in ["aware", "presence_diff"],
    do: {:ok, refresh_people(socket)}

  def update(%{issho: {"bye", _room, _reason}}, socket),
    do: {:ok, socket |> assign(tracked: nil, issho: nil) |> put_people([])}

  def update(%{issho: _event}, socket), do: {:ok, socket}

  # A read in a task (`load={:async}`) that took longer than `timeout`.
  def update(%{masu_timeout: name}, %{assigns: %{running: name}} = socket) do
    timeout = Map.get(stringify(socket.assigns.messages), "timeout", @messages["timeout"])
    {:ok, socket |> cancel_async(name) |> assign(running: nil, error: timeout)}
  end

  def update(%{masu_timeout: _name}, socket), do: {:ok, socket}

  # A write or an action that went on later replied (Masu.reply/2).
  def update(%{masu_reply: {token, result}}, socket) do
    case Map.pop(socket.assigns.pending, token) do
      {nil, _pending} ->
        {:ok, socket}

      {entry, pending} ->
        {:ok, socket |> assign(pending: pending) |> replied(token, entry, result)}
    end
  end

  def update(%{masu_progress: {token, done, total}}, socket) do
    if Map.has_key?(socket.assigns.pending, token) do
      {:ok,
       push_event(socket, "masu:progress", %{
         "id" => socket.assigns.id,
         "token" => token,
         "done" => done,
         "total" => total
       })}
    else
      {:ok, socket}
    end
  end

  def update(%{masu_changes: true}, socket) do
    case Masu.Live.take(socket.assigns.id) do
      [] -> {:ok, socket}
      changes -> {:ok, take_changes(socket, changes)}
    end
  end

  # The URL's params changed (Masu.Live): a view of them, unless it is
  # the grid's own (the patch the grid made).
  def update(%{masu_params: true}, socket) do
    {params, uri} = Masu.Live.params(socket.assigns.id)
    params = params || %{}
    socket = assign(socket, uri: uri)

    if params == socket.assigns.view_params do
      {:ok, socket}
    else
      %{all_columns: all, default_view: default} = socket.assigns
      {view, dropped} = View.from_params(params, all, default)
      {:ok, apply_view(socket, view, dropped, patch: false)}
    end
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(Map.drop(assigns, [:input, :header_action, :cell_action, :action, :row_action]))
      |> assign(
        header_actions: Action.all(Map.get(assigns, :header_action, []), :header),
        cell_actions: Action.all(Map.get(assigns, :cell_action, []), :cell),
        actions: Action.all(Map.get(assigns, :action, []), :selection),
        row_actions: Action.all(Map.get(assigns, :row_action, []), :row)
      )

    slots = Enum.map(Map.get(assigns, :col, []), &Column.new/1)

    socket =
      cond do
        is_nil(socket.assigns.source) ->
          start(socket, assigns.input, slots)

        # New rows, or a controlled grid's answer to what the person did.
        assigns.input != socket.assigns.input or answered?(socket.assigns) ->
          restart(socket, assigns.input, slots)

        true ->
          %{source: source, types: types} = socket.assigns
          {columns, types} = columns_for(socket.assigns, slots, source, types)
          socket |> assign(types: types) |> relayout(supported(source, columns, socket.assigns))
      end

    {:ok, follow(socket)}
  end

  # The topic of `live`, followed in the connected LiveView only, and the
  # people of the grid's room or topic.
  defp follow(socket) do
    cond do
      not connected?(socket) ->
        socket

      socket.assigns.live == socket.assigns.followed ->
        join_room(socket)

      true ->
        :ok = Masu.Live.follow(socket.assigns.id, socket.assigns.followed, socket.assigns.live)
        socket |> assign(followed: socket.assigns.live) |> track() |> join_room()
    end
  end

  # The grid's people in an Issho room (`issho`): its LiveView joins the
  # room once, and the grid puts its person's place there.
  defp join_room(%{assigns: %{issho_config: nil}} = socket), do: socket

  defp join_room(%{assigns: %{issho_config: given, user: user}} = socket) do
    config = Masu.Issho.Live.config(given, user)

    if socket.assigns.issho && socket.assigns.issho.room == config.room do
      socket
    else
      case Masu.Issho.Live.join(config, socket.assigns.id, shared_view(socket.assigns)) do
        :ok -> socket |> assign(issho: config) |> refresh_people()
        {:error, _reason} -> socket
      end
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
      :ok = Masu.Presence.track(presence, topic, user, shared_view(socket.assigns))
    end

    socket |> assign(tracked: topic) |> refresh_people()
  end

  defp refresh_people(%{assigns: %{issho: issho}} = socket) when issho != nil,
    do: put_people(socket, Masu.Issho.Live.people(issho, socket.assigns.id))

  defp refresh_people(%{assigns: %{presence: presence, tracked: topic, user: user}} = socket)
       when is_binary(topic),
       do: put_people(socket, Masu.Presence.people(presence, topic, user))

  defp refresh_people(socket), do: socket

  # The people to the browser, when they changed: a room's awareness
  # comes often, and most of it is elsewhere.
  defp put_people(%{assigns: %{people: people}} = socket, people), do: socket

  defp put_people(socket, people) do
    socket
    |> assign(people: people)
    |> push_event("masu:people", %{
      "id" => socket.assigns.id,
      "people" =>
        Enum.map(
          people,
          &Map.take(&1, [:id, :name, :color, :cell, :range, :editing, :view, :top])
        )
    })
  end

  # The person's view (order, filters, search) goes to the others, who
  # see it when they follow them; `share_view={false}` keeps it.
  defp shared_view(%{share_view: false}), do: nil
  defp shared_view(%{query: query}), do: Query.to_wire(query)

  # Changes from the topic: the source takes them and applies the query
  # again; the browser asks again for the rows it shows, and highlights
  # the changed ones.
  defp take_changes(socket, by_changes) do
    %{source: source, query: query, all_columns: columns, revision: revision} = socket.assigns
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

    socket
    |> assign(
      saved_by: saved_by,
      source: source,
      revision: revision + 1,
      initial: nil,
      changed: changed,
      changed_by: changed_by
    )
    |> recount(keep: true)
    |> refresh_details()
  end

  # A change from a grid's edit says who saved it; the source does not need it.
  defp without_by({:upsert, row, _by}), do: {:upsert, row}
  defp without_by(change), do: change

  # The grid's first view: of the URL (`url`), else the person's last
  # (`views`), else the grid's own, of its attributes.
  defp start(socket, input, slots) do
    source = new_source(socket.assigns, input)
    {columns, types} = columns_for(socket.assigns, slots, source, %{})
    socket = assign(socket, types: types)
    all = supported(source, columns, socket.assigns)

    query =
      case Query.new(
             [
               sort: socket.assigns.sort,
               filters: socket.assigns.filters,
               group_by: socket.assigns.group_by
             ],
             all
           ) do
        {:ok, query} -> query
        {:error, reason} -> raise ArgumentError, "grid #{socket.assigns.id}: #{reason}"
      end

    default = %View{query: query, layout: Layout.new(all)}
    socket = assign(socket, all_columns: all, default_view: default)
    {view, dropped, uri} = first_view(socket.assigns, all, default)
    view = %{view | query: start_open(view.query, socket.assigns)}

    socket =
      socket
      |> assign(input: input, uri: uri, notice: notice(dropped, 1))
      |> put_view(view)
      |> list_views()

    if async?(socket.assigns) do
      socket
      |> assign(source: source, total: 0, exact: false, initial: [])
      |> read_async(source, view.query, socket.assigns.page, false)
    else
      socket
      |> assign(source: Source.prepare(source, view.query, all))
      |> recount()
      |> put_initial()
    end
  end

  # The first rows, which the server renders and the browser starts with
  # (in a tree, with their places).
  defp put_initial(%{assigns: %{source: source} = assigns} = socket) do
    {from, limit} =
      if assigns.paging == :pages,
        do: {assigns.page * assigns.page_size, assigns.page_size},
        else: {0, assigns.block_size}

    socket =
      case Source.nodes(source, from, limit) do
        nil ->
          {rows, known} = Source.window(source, from, limit)
          socket = if known, do: put_count(socket, {known, true}), else: socket

          assign(socket,
            source: Source.seen(source, from, rows),
            initial: rows,
            initial_nodes: nil,
            initial_from: from
          )

        nodes ->
          assign(socket,
            initial: Enum.map(nodes, &elem(&1, 0)),
            initial_nodes: Enum.map(nodes, &elem(&1, 1)),
            initial_from: from
          )
      end

    learn(socket, from, length(socket.assigns.initial), limit)
  end

  defp first_view(assigns, all, default) do
    {params, uri} = if assigns.url, do: Masu.Live.params(assigns.id), else: {nil, nil}

    {view, dropped} =
      cond do
        params != nil -> View.from_params(params, all, default)
        last = last_view(assigns) -> View.from_params(last, all, default)
        true -> {default, []}
      end

    {view, dropped, uri}
  end

  defp last_view(%{views: views, user: user} = assigns) when views != nil and user != nil,
    do: views.last(views_key(assigns), user)

  defp last_view(_assigns), do: nil

  # New rows (or a new query of the LiveView): the person's view stays,
  # and the browser drops the rows it has. New rows may have other
  # columns (a query tool's): the view keeps what is of the columns that
  # are there still, and names the others.
  defp restart(socket, input, slots) do
    socket = assign(socket, awaiting: false)
    source = new_source(socket.assigns, input)
    {columns, types} = columns_for(socket.assigns, slots, source, %{})
    socket = assign(socket, types: types)
    all = supported(source, columns, socket.assigns)
    {query, dropped} = Query.fit(socket.assigns.query, all)
    {default_query, _dropped} = Query.fit(socket.assigns.default_view.query, all)
    revision = socket.assigns.revision + 1

    socket =
      socket
      |> assign(default_view: %{socket.assigns.default_view | query: default_query})
      |> relayout(all)
      |> assign(input: input, query: query, revision: revision, initial: nil, changed: [])
      |> fitted(dropped, revision)

    if async?(socket.assigns) do
      socket |> assign(source: source) |> read_async(source, query, socket.assigns.page, false)
    else
      socket
      |> assign(source: Source.prepare(source, query, all))
      |> recount(keep: true)
      |> refresh_details()
    end
  end

  # The rows' source: the LiveView's own rows, as they are, for a
  # controlled grid (`on_query`), from its page; else a list, a query or
  # a source of the app's.
  defp new_source(%{on_query: on_query} = assigns, rows) when is_function(on_query, 1) do
    offset = if assigns.paging == :pages, do: assigns.page * assigns.page_size, else: 0
    state = Given.init(rows, offset: offset, total: assigns.given_total)
    %Source{module: Given, state: state}
  end

  defp new_source(assigns, input), do: Source.new(input, source_opts(assigns))

  # A controlled grid's LiveView rendered it again after the person's
  # change, done (not `loading`): its rows are the answer, the same as
  # before or not.
  defp answered?(%{awaiting: true, given_loading: loading}), do: loading != true
  defp answered?(_assigns), do: false

  defp controlled?(assigns), do: is_function(assigns.on_query, 1)

  # Rows to come: the LiveView of a controlled grid runs its query, or a
  # read in a task runs.
  defp running?(assigns) do
    if controlled?(assigns),
      do: assigns.awaiting or assigns.given_loading == true,
      else: match?({:masu_read, _id}, assigns.running) or assigns.running == :connecting
  end

  # The grid reads its source in a task (`load={:async}`).
  defp async?(assigns), do: assigns.load == :async and not controlled?(assigns)

  # The person's view, to the LiveView of a controlled grid, which runs
  # its query: `page` from 1, and its rows' `offset` and `limit`.
  defp report(socket) do
    %{query: query, page: page, page_size: size, paging: paging} = socket.assigns

    {offset, limit} =
      if paging == :pages, do: {page * size, size}, else: {0, nil}

    socket.assigns.on_query.(%{query: query, page: page + 1, offset: offset, limit: limit})
    assign(socket, awaiting: true)
  end

  # The first rows of a query (of the page `page`), its count, and its
  # source prepared, read in a task. The answer is taken if no other
  # read came after it (`running`); `changed?` puts the view in the
  # URL and the store.
  defp read_async(socket, source, query, page, changed?) do
    socket = stop_read(socket)
    %{all_columns: columns, count: count} = socket.assigns
    {from, limit} = first_rows(%{socket.assigns | page: page})

    read = %{
      source: source,
      query: query,
      page: page,
      from: from,
      limit: limit,
      changed?: changed?
    }

    socket = assign(socket, read: read, error: nil)
    run = fn -> read_first(source, query, columns, count, from, limit) end

    if connected?(socket),
      do: start_read(socket, run),
      else: assign(socket, running: :connecting)
  end

  defp start_read(socket, run) do
    name = {:masu_read, System.unique_integer([:positive])}

    socket
    |> assign(running: name)
    |> start_async(name, fn -> guarded(run) end)
    |> time_out(name)
  end

  # What a read in a task does: the query prepared, its count (`:exact`)
  # and its first rows.
  defp read_first(source, query, columns, count, from, limit) do
    prepared = Source.prepare(source, query, columns)
    counted = if count == :exact, do: Source.counted(prepared)
    window = read_window(prepared, from, limit)
    %{source: seen(prepared, from, window), counted: counted, window: window}
  end

  # Rows from `from`, with their places in a tree.
  defp read_window(source, from, count) do
    case Source.nodes(source, from, count) do
      nil -> {:rows, Source.window(source, from, count)}
      nodes -> {:nodes, nodes}
    end
  end

  # The source after a window read in a task (`Source.seen/3`).
  defp seen(source, from, {:rows, {rows, _known}}), do: Source.seen(source, from, rows)
  defp seen(source, _from, {:nodes, _nodes}), do: source

  defp stop_read(%{assigns: %{running: {:masu_read, _id} = name}} = socket),
    do: socket |> cancel_async(name) |> assign(running: nil)

  defp stop_read(socket), do: socket

  defp time_out(%{assigns: %{timeout: timeout, id: id}} = socket, name)
       when is_integer(timeout) do
    Phoenix.LiveView.send_update_after(self(), __MODULE__, %{id: id, masu_timeout: name}, timeout)
    socket
  end

  defp time_out(socket, _name), do: socket

  # A source's error, or its raise, as the grid shows it: in the task,
  # not in the LiveView.
  defp guarded(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, Exception.format_banner(kind, reason)}
  end

  # The answer of a read in a task: the query, its rows and its count.
  defp take_read(socket, data) do
    %{read: read, revision: revision, count_ref: ref} = socket.assigns
    ref = ref + 1

    socket =
      assign(socket,
        source: data.source,
        query: read.query,
        page: read.page,
        revision: revision + 1,
        changed: [],
        count_ref: ref,
        read: nil
      )

    socket =
      case socket.assigns.count do
        :none -> assign(socket, total: 0, exact: false)
        :deferred -> socket |> assign(total: 0, exact: false) |> count_later(ref, data.source)
        _exact -> socket |> assign(total: 0) |> put_count(data.counted)
      end

    socket =
      case data.window do
        {:nodes, nodes} ->
          assign(socket,
            initial: Enum.map(nodes, &elem(&1, 0)),
            initial_nodes: Enum.map(nodes, &elem(&1, 1)),
            initial_from: read.from
          )

        {:rows, {rows, known}} ->
          socket = if known, do: put_count(socket, {known, true}), else: socket
          assign(socket, initial: rows, initial_nodes: nil, initial_from: read.from)
      end

    socket =
      socket
      |> learn(read.from, length(socket.assigns.initial), read.limit)
      |> refresh_details()

    if read.changed?, do: view_changed(socket), else: socket
  end

  defp failure(socket, message) do
    template = Map.get(stringify(socket.assigns.messages), "failed", @messages["failed"])
    assign(socket, running: nil, error: String.replace(template, "{label}", message))
  end

  defp fitted(socket, [], _revision), do: socket

  defp fitted(socket, dropped, revision),
    do: socket |> assign(notice: notice(dropped, revision)) |> view_changed(patch: false)

  # The grid's columns: its `:col` slots, else its `columns`, else its
  # source's (c:Masu.Source.columns/1). A column of `type={:auto}` takes
  # the type of its values, which `types` has, by key, when the grid
  # learned it before; else the grid reads a block of the source for it.
  defp columns_for(assigns, slots, source, types) do
    columns =
      if slots != [] do
        slots
      else
        specs =
          assigns.column_specs || Source.columns(source) ||
            raise(
              ArgumentError,
              "<.data_grid id=#{inspect(assigns.id)}> has no columns: give it :col slots, " <>
                "`columns`, or a source with columns/1"
            )

        specs |> Enum.with_index() |> Enum.map(fn {spec, place} -> spec_column(spec, place) end)
      end

    learn_types(columns, source, types, assigns.block_size)
  end

  # A column of `columns` (or a source's): a key, or a :col's attributes.
  # Without a field, the value at its place of a row that is a list;
  # without a type, the type of its values.
  defp spec_column(key, place) when is_binary(key) or is_atom(key),
    do: spec_column(%{key: to_string(key)}, place)

  defp spec_column(attrs, place) when is_list(attrs), do: attrs |> Map.new() |> spec_column(place)

  defp spec_column(attrs, place) when is_map(attrs) do
    attrs = Map.put_new(attrs, :type, :auto)

    if Map.has_key?(attrs, :field) or Map.has_key?(attrs, :value),
      do: Column.new(attrs),
      else: attrs |> Map.put(:field, place) |> Column.new()
  end

  defp learn_types(columns, source, types, block_size) do
    missing = Enum.filter(columns, &(&1.type == :auto and not Map.has_key?(types, &1.key)))

    types =
      if missing == [] do
        types
      else
        plain = Enum.map(columns, &Column.typed(&1, :text))
        rows = source |> Source.prepare(%Query{}, plain) |> Source.rows(0, block_size)

        Enum.reduce(missing, types, fn column, types ->
          Map.put(types, column.key, Column.infer(Enum.map(rows, &Column.get(column, &1))))
        end)
      end

    {Enum.map(columns, &Column.typed(&1, Map.get(types, &1.key, :text))), types}
  end

  # The columns again (the LiveView rendered the grid again): the person's
  # layout, fitted to them.
  defp relayout(socket, all) do
    %{layout: layout, default_view: default} = socket.assigns

    # An order the person did not change is the columns' own: a query
    # tool's new columns come in theirs.
    layout =
      if layout.order == default.layout.order,
        do: %{layout | order: Enum.map(all, & &1.key)},
        else: layout

    layout = Layout.fit(layout, all)
    default = %{socket.assigns.default_view | layout: Layout.new(all)}

    assign(socket,
      all_columns: all,
      default_view: default,
      layout: layout,
      columns: Layout.columns(layout, all)
    )
  end

  defp put_view(socket, %View{query: query, layout: layout} = view) do
    assign(socket,
      query: query,
      layout: layout,
      page: if(socket.assigns.paging == :pages, do: view.page, else: 0),
      columns: Layout.columns(layout, socket.assigns.all_columns),
      view_params: View.to_params(view, socket.assigns.default_view)
    )
  end

  # `expanded`: in a tree, the ids of the rows that start open; else
  # `:all`, or the keys of the columns whose groups start open.
  defp start_open(query, %{tree: nil, expanded: expanded}),
    do: %{query | open_groups: open_groups(expanded)}

  defp start_open(query, %{expanded: expanded}),
    do: %{query | expanded: MapSet.new(expanded || [], &Value.to_wire/1)}

  defp open_groups(:all), do: :all
  defp open_groups(keys), do: Enum.map(keys || [], &to_string/1)

  # The groups the person closed stay closed with a new filter or view;
  # the rows they closed in a filter's tree open again.
  defp closed_groups(collapsed), do: MapSet.filter(collapsed, &Group.id?/1)

  # `ids` put in a set of the query (`:expanded` or `:collapsed`), or
  # taken from it.
  defp mark(query, set, ids, true),
    do: Map.update!(query, set, &MapSet.union(&1, MapSet.new(ids)))

  defp mark(query, set, ids, false),
    do: Map.update!(query, set, &MapSet.difference(&1, MapSet.new(ids)))

  # A whole view at once (a saved view, the grid's own, or the URL's):
  # its rows from the first.
  defp apply_view(socket, %View{} = view, dropped, opts \\ []) do
    %{source: source, all_columns: all, revision: revision, query: current} = socket.assigns

    view = %{
      view
      | query: %{
          view.query
          | expanded: current.expanded,
            collapsed: closed_groups(current.collapsed),
            open_groups: current.open_groups
        }
    }

    cond do
      # The LiveView of a controlled grid runs the view's query.
      controlled?(socket.assigns) ->
        socket
        |> assign(notice: notice(dropped, revision + 1), page: view.page)
        |> put_view(view)
        |> report()
        |> view_changed(opts)

      async?(socket.assigns) ->
        page = if socket.assigns.paging == :pages, do: view.page, else: 0

        socket
        |> assign(notice: notice(dropped, revision + 1))
        |> put_view(%{view | query: current})
        |> read_async(source, view.query, page, true)

      true ->
        apply_view_now(socket, view, dropped, opts, source, all, revision)
    end
  end

  defp apply_view_now(socket, view, dropped, opts, source, all, revision) do
    source = Source.prepare(source, view.query, all)

    socket
    |> assign(
      source: source,
      page: if(socket.assigns.paging == :pages, do: view.page, else: 0),
      revision: revision + 1,
      changed: [],
      notice: notice(dropped, revision + 1)
    )
    |> recount()
    |> put_initial()
    |> put_view(view)
    |> refresh_details()
    |> view_changed(opts)
  end

  defp notice([], _id), do: nil
  defp notice(keys, id), do: [id, Enum.join(keys, ", ")]

  # The view changed: into the URL (`url`), the store (`views`), and to
  # the people who may follow this person (Masu.Presence).
  defp view_changed(socket, opts \\ []) do
    %{query: query, layout: layout, default_view: default, page: page} = socket.assigns
    params = View.to_params(%View{query: query, layout: layout, page: page}, default)
    socket = assign(socket, view_params: params)
    assigns = socket.assigns

    if assigns.views && assigns.user && connected?(socket),
      do: :ok = assigns.views.put_last(views_key(assigns), assigns.user, params)

    socket = share_view(socket)

    # The LiveView patches its URL (Masu.Live): a patch from the
    # component's event would take the place of the event's reply.
    if assigns.url && assigns.uri && Keyword.get(opts, :patch, true),
      do: send(self(), {Masu.Live.Patch, Masu.Live.url(assigns.uri, assigns.id, params)})

    socket
  end

  defp list_views(%{assigns: %{views: views, user: user} = assigns} = socket)
       when views != nil and user != nil,
       do: assign(socket, saved_views: views.list(views_key(assigns), user))

  defp list_views(socket), do: socket

  # A scope keeps its views apart from another's: an account's, say.
  defp views_key(assigns) do
    key = assigns.views_key || assigns.id

    case Map.get(assigns, :views_scope) do
      nil -> key
      scope -> "#{key}@#{scope}"
    end
  end

  @doc false
  # A grid's source and columns, of its attributes, outside a LiveView
  # (Masu.Sheet): as the grid starts them, with no slots.
  @spec setup(map()) :: {Source.t(), [Column.t()]}
  def setup(assigns) do
    source = new_source(assigns, assigns.input)
    {columns, _types} = columns_for(assigns, [], source, %{})
    {source, supported(source, columns, assigns)}
  end

  defp source_opts(assigns) do
    [
      repo: assigns.repo,
      repo_opts: assigns.repo_opts,
      read: Map.get(assigns, :source_read),
      count_limit: Map.get(assigns, :count_limit),
      grid: assigns.id,
      tree: assigns.tree,
      row_id: row_id(assigns)
    ]
  end

  # A column that the source cannot sort or filter by does neither. A
  # column is editable when the grid edits, and it names a field.
  # A column takes a value on a new row when the grid creates rows, as it
  # takes one in an edit; a field of `create_with` takes neither. An
  # enum's values are its own, or its schema's.
  defp supported(source, columns, assigns) do
    edits? = edits?(assigns)
    creates? = creates?(assigns)
    fixed = assigns |> Map.get(:create_with, %{}) |> Map.keys() |> Enum.map(&to_string/1)

    Enum.map(columns, fn column ->
      field? = settable?(column, fixed)

      many? = Source.many?(source, column)

      column = %{
        column
        | editable: edits? and field?,
          creatable: creates? and field?,
          many: many?,
          values: column.values || enum_values(source, column)
      }

      cond do
        not Source.supports?(source, column) ->
          %{column | sortable: false, filterable: false, searchable: false}

        many? ->
          ops = Source.filter_ops(source, column) || Filter.many_ops()
          column = %{column | sortable: false, aggregate: nil}
          with_filter_ops(column, Enum.filter(Filter.many_ops(), &(&1 in ops)))

        true ->
          with_filter_ops(column, scalar_ops(Source.filter_ops(source, column)))
      end
    end)
  end

  # The operators its source filters a column by; none: it does not filter.
  # A source's operators, of the column's own (`filters`) when it has them.
  defp with_filter_ops(%Column{filter_ops: nil} = column, nil), do: column
  defp with_filter_ops(column, nil), do: with_filter_ops(column, column.filter_ops)

  defp with_filter_ops(%Column{filter_ops: own} = column, ops)
       when is_list(own) and own != ops,
       do: with_filter_ops(%{column | filter_ops: nil}, Enum.filter(ops, &(&1 in own)))

  defp with_filter_ops(column, []), do: %{column | filter_ops: [], filterable: false}
  defp with_filter_ops(column, ops), do: %{column | filter_ops: ops}

  # The operators of a column of one value, of those its source runs.
  defp scalar_ops(nil), do: nil
  defp scalar_ops(ops), do: ops -- [:all_of, :none_of]

  # A column the person may set: a field, not `editable={false}`, nor
  # one of `create_with`.
  defp settable?(column, fixed),
    do: column.editable != false and named_field?(column) and to_string(column.field) not in fixed

  # A field of a map or struct: not a function, nor a place in a row that
  # is a list.
  defp named_field?(%Column{value: nil, field: field}) when is_atom(field) and field != nil,
    do: true

  defp named_field?(%Column{value: nil, field: field}) when is_binary(field), do: true
  defp named_field?(%Column{}), do: false

  defp edits?(assigns),
    do: is_function(assigns[:on_update], 1) or is_function(assigns[:changeset], 2)

  defp creates?(assigns) do
    is_function(Map.get(assigns, :on_create), 1) or
      (is_function(Map.get(assigns, :changeset), 2) and Map.get(assigns, :struct) != nil)
  end

  defp enum_values(
         %Source{module: EctoSource, state: state},
         %Column{type: :enum, value: nil} = column
       ),
       do: EctoSource.enum_values(state, column.field)

  defp enum_values(_source, _column), do: nil

  @impl true
  def handle_async(:masu_count, {:ok, {ref, counted}}, socket) do
    if ref == socket.assigns.count_ref,
      do: {:noreply, put_count(socket, counted)},
      else: {:noreply, socket}
  end

  def handle_async(:masu_count, {:exit, _reason}, socket), do: {:noreply, socket}

  # A read in a task (`load={:async}`), if it is the last one asked for.
  def handle_async({:masu_read, _id} = name, result, %{assigns: %{running: name}} = socket) do
    socket = assign(socket, running: nil)

    case result do
      {:ok, {:ok, data}} -> {:noreply, take_read(socket, data)}
      {:ok, {:error, message}} -> {:noreply, failure(socket, message)}
      {:exit, reason} -> {:noreply, failure(socket, Exception.format_exit(reason))}
    end
  end

  def handle_async({:masu_read, _id}, _result, socket), do: {:noreply, socket}

  # A block of rows read in a task, to the browser, with the revision it
  # was read for: the browser drops it if its rows changed meanwhile.
  def handle_async({:masu_block, from, count, revision}, result, socket) do
    socket =
      if socket.assigns.running == {:block, from}, do: assign(socket, running: nil), else: socket

    case result do
      {:ok, {:ok, window}} when revision == socket.assigns.revision ->
        {reply, socket} = take_block(socket, window, from, count)

        {:noreply,
         push_event(socket, "masu:block", %{"id" => socket.assigns.id, "block" => reply})}

      {:ok, {:ok, _window}} ->
        stale = %{"from" => from, "rows" => [], "revision" => revision}

        {:noreply,
         push_event(socket, "masu:block", %{"id" => socket.assigns.id, "block" => stale})}

      {:ok, {:error, message}} ->
        {:noreply, push_failed_block(failure(socket, message), from, revision)}

      {:exit, reason} ->
        {:noreply,
         push_failed_block(failure(socket, Exception.format_exit(reason)), from, revision)}
    end
  end

  defp push_failed_block(socket, from, revision) do
    block = %{"from" => from, "rows" => [], "revision" => revision, "failed" => true}
    push_event(socket, "masu:block", %{"id" => socket.assigns.id, "block" => block})
  end

  @impl true
  def handle_event("masu:rows", %{"from" => from, "count" => count}, socket)
      when is_integer(from) and is_integer(count) do
    from = max(from, 0)
    count = count |> max(0) |> min(socket.assigns.max_block)
    assigns = socket.assigns

    cond do
      # A controlled grid whose LiveView runs its query: its rows come.
      controlled?(assigns) and (assigns.awaiting or assigns.given_loading) ->
        {:reply, %{"pending" => true, "from" => from, "revision" => assigns.revision}, socket}

      # A read in a task: the rows come in a `masu:block` event.
      async?(assigns) and count > 0 and connected?(socket) ->
        {:reply, %{"pending" => true, "from" => from, "revision" => assigns.revision},
         read_block(socket, from, count)}

      true ->
        {reply, socket} = block(socket, from, count)
        {:reply, reply, socket}
    end
  end

  # Stops the read in a task, and keeps the rows the grid has (Stop).
  def handle_event("masu:cancel", _params, socket),
    do: {:noreply, socket |> stop_read() |> assign(running: nil, read: nil)}

  # Reads again what failed (Run again): the read in a task that failed,
  # or the query.
  def handle_event("masu:retry", _params, socket) do
    %{read: read, source: source, query: query, page: page} = socket.assigns
    socket = assign(socket, error: nil)

    socket =
      if read,
        do: read_async(socket, read.source, read.query, read.page, read.changed?),
        else: read_async(socket, source, query, page, false)

    {:noreply, socket}
  end

  # The count of a grid that does not know it (`count={:none}`, or a
  # source that does not): asked for once, as the person goes to the end.
  def handle_event("masu:count", _params, socket) do
    %{source: source, count_ref: ref, revision: revision} = socket.assigns

    # In a task: the count comes with the render after it.
    # The person went to the end: every row is counted (`count_limit`).
    source = Source.uncapped(source)

    if async?(socket.assigns) and connected?(socket) do
      {:reply, %{"pending" => true, "revision" => revision}, count_later(socket, ref, source)}
    else
      socket = put_count(socket, Source.counted(source))

      {:reply,
       %{
         "total" => socket.assigns.total,
         "exact" => socket.assigns.exact,
         "revision" => socket.assigns.revision
       }, socket}
    end
  end

  # The pager: a page from 1 (its buttons, its field).
  def handle_event("masu:goto", %{"page" => page}, socket) do
    case Integer.parse(to_string(page)) do
      {page, _rest} when socket.assigns.paging == :pages ->
        {:reply, _reply, socket} = handle_event("masu:page", %{"page" => page - 1}, socket)
        {:noreply, socket}

      _other ->
        {:noreply, socket}
    end
  end

  # A page (`paging={:pages}`), from 0: its rows, and into the view (the
  # URL, the store).
  def handle_event("masu:page", %{"page" => page}, socket) when is_integer(page) do
    %{page_size: size, total: total, exact: exact} = socket.assigns
    last = if exact, do: max(div(max(total, 1) - 1, size), 0), else: page
    page = page |> max(0) |> min(last)
    socket = assign(socket, page: page)

    cond do
      # The LiveView reads the page; the rows come when it renders the grid.
      controlled?(socket.assigns) ->
        socket = socket |> report() |> view_changed()

        {:reply, %{"pending" => true, "page" => page, "revision" => socket.assigns.revision},
         socket}

      # The browser asks for the page's rows, which a task reads.
      async?(socket.assigns) ->
        {:reply, %{"pending" => true, "page" => page, "revision" => socket.assigns.revision},
         view_changed(socket)}

      true ->
        {reply, socket} = block(socket, page * size, size)
        {:reply, Map.put(reply, "page", page), view_changed(socket)}
    end
  end

  # The values of a column for its filter menu: among the rows of the
  # query without the column's own filters, so that the menu offers the
  # values the person may add. A search past the bound, or with a NUL, is
  # not run: the menu cannot show an error, so it gets no values.
  def handle_event("masu:values", %{"key" => key} = params, socket) when is_binary(key) do
    %{source: source, query: query, all_columns: columns} = socket.assigns

    case {Column.find(columns, key), Input.search(params["search"])} do
      {%Column{filterable: true} = column, :ok} ->
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
  def handle_event("masu:edit", %{"edits" => edits} = params, socket) when is_list(edits) do
    origin = Masu.Edit.origin(params["origin"], :edit)
    result = Masu.Edit.update(edits, socket.assigns, row_id(socket.assigns), origin)

    socket =
      socket
      |> take_saved(Enum.map(result.saved, &{:upsert, &1}))
      |> put_pending(result.token, %{kind: :write, op: :update, cells: result.pending})

    {:reply,
     %{
       "revision" => socket.assigns.revision,
       "rows" => encode_rows(result.saved, socket.assigns),
       "errors" => result.errors,
       "async" => result.token,
       "saving" => result.pending
     }
     |> drop_nil("async"), socket}
  end

  # New rows (`create`, or `changeset` and `struct`), each the values of
  # its cells: the answer has, for each, its id, or the errors of its
  # cells (`[key, message]`, a key of nil for the row); and the place of
  # the first new row in the person's order, when it is in their query.
  def handle_event("masu:create", %{"rows" => drafts} = params, socket) when is_list(drafts) do
    if creates?(socket.assigns) do
      row_id = row_id(socket.assigns)
      origin = Masu.Edit.origin(params["origin"], :draft)
      results = Masu.Edit.create(drafts, socket.assigns, row_id, origin)
      created = for {:ok, row} <- results, do: row
      socket = take_saved(socket, Enum.map(created, &{:upsert, &1}))

      index =
        case created do
          [first | _] ->
            Source.locate(socket.assigns.source, Value.to_wire(row_id.(first)), row_id)

          [] ->
            nil
        end

      {:reply,
       %{
         "revision" => socket.assigns.revision,
         "total" => socket.assigns.total,
         "index" => index,
         "results" =>
           Enum.map(results, fn
             {:ok, row} -> %{"id" => Value.to_wire(row_id.(row))}
             {:error, errors} -> %{"errors" => errors}
           end)
       }, socket}
    else
      {:reply, %{"error" => "This grid does not add rows."}, socket}
    end
  end

  # Rows deleted, by their ids, or the rows selected (`selection`). The
  # answer has an `undo` that brings them back, when the grid can.
  def handle_event("masu:delete", params, socket) when is_map(params) do
    with true <- Masu.Edit.deletes?(socket.assigns) || "This grid does not delete rows.",
         {:ok, ids} <- ids_to_delete(params, socket.assigns) do
      row_id = row_id(socket.assigns)
      places = places(socket.assigns.source, ids, row_id)
      default = if params["selection"] == true, do: :selection, else: :rows
      origin = Masu.Edit.origin(params["origin"], default)
      result = Masu.Edit.delete(ids, socket.assigns, row_id, origin)
      deleted = result.deleted

      socket =
        socket
        |> take_saved([], deleted)
        |> unselect(deleted)
        |> put_pending(result.token, %{kind: :write, op: :delete, ids: result.pending})

      {undo, socket} = put_trash(socket, deleted, places)

      {:reply,
       %{
         "revision" => socket.assigns.revision,
         "total" => socket.assigns.total,
         "deleted" => length(deleted),
         "errors" => result.errors,
         "undo" => undo,
         "async" => result.token,
         "saving" => result.pending
       }
       |> drop_nil("async"), socket}
    else
      message when is_binary(message) -> {:reply, %{"error" => message}, socket}
      {:error, message} -> {:reply, %{"error" => message}, socket}
    end
  end

  # Deleted rows back (an undo): the answer has their ids, for a redo.
  def handle_event("masu:restore", %{"undo" => token}, socket) when is_binary(token) do
    row_id = row_id(socket.assigns)

    case List.keytake(socket.assigns.trash, token, 0) do
      {{^token, rows, places}, trash} ->
        {restored, errors} = Masu.Edit.restore(rows, socket.assigns, row_id)

        socket =
          socket
          |> assign(trash: trash)
          |> reinsert(restored, places, row_id)
          |> take_saved(Enum.map(restored, &{:upsert, &1}))

        {:reply,
         %{
           "revision" => socket.assigns.revision,
           "total" => socket.assigns.total,
           "ids" => Enum.map(restored, &Value.to_wire(row_id.(&1))),
           "errors" => errors
         }, socket}

      nil ->
        {:reply, %{"error" => "These rows can no longer be brought back."}, socket}
    end
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

    place = %{
      cell: cell,
      range: range(params["range"]),
      editing: editing,
      top: top(params["top"])
    }

    cond do
      socket.assigns.issho ->
        _ = Masu.Issho.Live.put(socket.assigns.issho, socket.assigns.id, place)

      presence && topic ->
        :ok = Masu.Presence.update(presence, topic, user, place)

      true ->
        :ok
    end

    {:noreply, socket}
  end

  def handle_event("masu:query", params, socket) when is_map(params) do
    %{source: source, all_columns: columns, revision: revision} = socket.assigns

    case Query.from_wire(params, columns) do
      {:ok, query} ->
        # The rows the person opened stay open, and the groups they closed
        # closed; the rows they closed in a filter's tree open again with
        # a new filter.
        current = socket.assigns.query
        same_filter? = query.filters == current.filters and query.search == current.search

        query = %{
          query
          | expanded: current.expanded,
            collapsed:
              if(same_filter?, do: current.collapsed, else: closed_groups(current.collapsed)),
            open_groups: current.open_groups,
            sorts:
              if(socket.assigns.multi_sort, do: query.sorts, else: Enum.take(query.sorts, 1)),
            groups: if(controlled?(socket.assigns), do: [], else: query.groups)
        }

        pending_query(socket, query) || run_query(socket, source, query, columns, revision)

      {:error, reason} ->
        {:reply, %{"error" => reason, "revision" => revision}, socket}
    end
  end

  # The Export menu: a link to the file, for the browser to download from
  # the router's export route (Masu.Router), with a token of a ticket that
  # holds the export, good once. The file is not written here, nor sent
  # over the socket.
  def handle_event("masu:export", %{"format" => format}, socket) when format in ["csv", "xlsx"] do
    format = String.to_existing_atom(format)
    %{id: id, export: allowed} = socket.assigns

    cond do
      format not in export_formats(socket.assigns) ->
        {:reply, %{"error" => "format"}, socket}

      not function_exported?(socket.router || Masu, :__masu_export_path__, 0) ->
        raise ArgumentError,
              "the grid #{id} has export=#{inspect(allowed)}, and its LiveView's router has no " <>
                "export route: add `masu_exports \"/masu/exports\"` (import Masu.Router) to it"

      true ->
        export = %{export_of(socket.assigns) | name: "#{id}-#{Date.utc_today()}"}
        {:ok, ticket} = Ticket.start(self(), %{export: export, format: format})
        token = Download.token(socket.endpoint, ticket)
        path = socket.endpoint.path(socket.router.__masu_export_path__() <> "/" <> token)
        {:reply, %{"url" => path}, socket}
    end
  end

  # Rows selected (`selectable`): some rows by their ids (`on` or off), or
  # every row of the query (`all`), or none. A selection of every row is
  # of the query as it is when it is read (Masu.Live.selected/1), less the
  # rows taken out of it.
  def handle_event("masu:select", params, socket) when is_map(params) do
    %{selection: selection} = socket.assigns

    selection = change_selection(selection, params, socket.assigns.source)

    socket = assign(socket, selection: selection)
    summary = selection_summary(socket.assigns)
    if is_function(socket.assigns.on_select, 1), do: socket.assigns.on_select.(summary)
    {:reply, %{"count" => summary.count}, socket}
  end

  # A row of a tree opened or closed (`open`), or every row beside it
  # that has children (`siblings`, the `*` key). The rows below it move:
  # the answer has the rows from `from`.
  def handle_event("masu:toggle", %{"id" => id} = params, socket) do
    %{source: source, query: query} = socket.assigns

    ids =
      if params["siblings"] == true, do: Source.siblings(source, id), else: [id]

    open = params["open"] != false

    # A tree's rows in a filter are open unless closed (`collapsed`), and
    # without one closed unless opened (`expanded`). A group is either, as
    # its column starts (`expanded`): it goes in one set, out of the other.
    query =
      cond do
        Group.id?(id) -> query |> mark(:expanded, ids, open) |> mark(:collapsed, ids, not open)
        query.filters != [] or query.search != nil -> mark(query, :collapsed, ids, not open)
        true -> mark(query, :expanded, ids, open)
      end

    reprepare(socket, query, params["from"])
  end

  # An item of a menu of the app's own (Masu.Action), on a header or a
  # cell: run, or its panel opened. The cell's row and value are read
  # here, from the source; the browser gives only where it is.
  def handle_event(
        "masu:action",
        %{"kind" => kind, "action" => index, "key" => key} = params,
        socket
      )
      when kind in ["header", "cell"] and is_integer(index) and is_binary(key) do
    with {:ok, action, column} <- find_action(socket.assigns, kind, index, key, params["label"]),
         {:ok, context} <- action_context(socket.assigns, action, column, params) do
      if action.slot do
        panel = %{kind: action.kind, index: action.index, context: context}
        {:reply, %{"panel" => true}, assign(socket, action_panel: panel)}
      else
        run_action(socket, action, context)
      end
    else
      {:error, error} -> {:reply, %{"error" => error}, socket}
    end
  end

  # An action on the rows selected (`:action`), which the grid offers
  # while rows are selected.
  def handle_event("masu:action", %{"kind" => "selection", "action" => index} = params, socket)
      when is_integer(index) do
    assigns = socket.assigns
    summary = selection_summary(assigns)

    with %Action{} = action <- Enum.at(assigns.actions, index),
         true <- params["label"] in [nil, action.label],
         true <- assigns.selectable and summary.count > 0 do
      context =
        assigns
        |> base_context()
        |> Map.merge(%{selected: selected(assigns), count: summary.count})

      run_action(socket, action, context)
    else
      _other -> {:reply, %{"error" => "action"}, socket}
    end
  end

  # An action on a row (`:row_action`): the row read again from the
  # source, which must show the action, available.
  def handle_event("masu:action", %{"kind" => "row", "action" => index} = params, socket)
      when is_integer(index) do
    assigns = socket.assigns
    row_id = row_id(assigns)

    with %Action{} = action <- Enum.at(assigns.row_actions, index),
         true <- params["label"] in [nil, action.label],
         true <- action.on_action != nil or action.event != nil,
         {:row, [row | _]} <- {:row, fetch_row(assigns, params["id"], row_id)},
         true <- Action.shown?(action, row) and not Action.disabled?(action, row) do
      context =
        assigns
        |> base_context()
        |> Map.merge(%{id: row_id.(row), row: row, editors: editors(assigns, params["id"])})

      run_action(socket, action, context)
    else
      {:row, _none} -> {:reply, %{"error" => "row"}, socket}
      _other -> {:reply, %{"error" => "action"}, socket}
    end
  end

  # The history of a cell (`key`), or of a row, from the grid's
  # `history` (Masu.History), newest first; each entry with the size of
  # its batch, for a restore of all of it.
  def handle_event("masu:history", %{"id" => id} = params, %{assigns: %{history: store}} = socket)
      when store != nil do
    grid = socket.assigns.id

    # Only of a row the grid's query shows this person, and of a cell of
    # one of the grid's columns: a key of no column has no history.
    entries =
      case {params["key"], fetch_row(socket.assigns, id, row_id(socket.assigns))} do
        {_key, []} ->
          []

        {key, _row} when is_binary(key) ->
          if Column.find(socket.assigns.all_columns, key),
            do: store.for_cell(grid, id, key, limit: 50),
            else: []

        {_key, _row} ->
          store.for_row(grid, id, limit: 50)
      end

    sizes =
      for batch <- entries |> Enum.map(& &1.batch) |> Enum.uniq(), batch != nil, into: %{} do
        {batch, length(store.batch(grid, batch))}
      end

    wire =
      Enum.map(entries, fn entry ->
        Map.put(Masu.History.to_wire(entry), "batch_size", Map.get(sizes, entry.batch, 1))
      end)

    {:reply, %{"entries" => wire}, socket}
  end

  def handle_event("masu:history", _params, socket), do: {:reply, %{"entries" => []}, socket}

  # A value of the history back (`entry`), or every cell of a batch
  # (`batch`: someone's paste undone): an edit of the cells, through the
  # changeset and the read-only rules, refused for a cell that changed
  # since, and recorded as a restore.
  def handle_event("masu:history_restore", params, %{assigns: %{history: store}} = socket)
      when store != nil do
    grid = socket.assigns.id

    edits =
      case params do
        %{"entry" => id} -> grid |> store.entry(id) |> List.wrap() |> restore_value(store, grid)
        %{"batch" => batch} when is_binary(batch) -> restore_batch(store, grid, batch)
        _other -> []
      end

    result = Masu.Edit.update(edits, socket.assigns, row_id(socket.assigns), :restore)
    socket = take_saved(socket, Enum.map(result.saved, &{:upsert, &1}))

    {:reply,
     %{
       "revision" => socket.assigns.revision,
       "restored" => restored(edits, result.errors),
       "errors" => result.errors
     }, socket}
  end

  def handle_event("masu:history_restore", _params, socket),
    do: {:reply, %{"restored" => 0, "errors" => []}, socket}

  def handle_event("masu:action_panel", %{"open" => false}, socket),
    do: {:reply, %{}, assign(socket, action_panel: nil)}

  # The editor of a cell that is a form of the app's (a column's `editor`
  # function): rendered here, in a popover, with the cell's value as the
  # row has it now, and a version of it that the edit carries back.
  def handle_event("masu:cell_editor", %{"open" => false}, socket),
    do: {:reply, %{}, assign(socket, cell_editor: nil)}

  def handle_event("masu:cell_editor", %{"id" => id, "key" => key}, socket) when is_binary(key) do
    assigns = socket.assigns
    row_id = row_id(assigns)

    with %Column{editable: true, editor: {:form, _fun}} = column <-
           Column.find(assigns.columns, key),
         [row | _] <- fetch_row(assigns, id, row_id),
         true <- row_edits?(assigns, row, column) do
      value = Column.get(column, row)
      version = Masu.Edit.version(value)
      editor = %{id: id, key: key, row: row, value: value, version: version}
      {:reply, %{"version" => version}, assign(socket, cell_editor: editor)}
    else
      _other -> {:reply, %{"error" => "editor"}, assign(socket, cell_editor: nil)}
    end
  end

  # A row's detail (the `:detail` slot) opened or closed.
  def handle_event("masu:detail", %{"id" => id} = params, socket) do
    open = Enum.reject(socket.assigns.open_details, &(&1 == id))

    open =
      if params["open"] == false,
        do: open,
        else: Enum.take(open ++ [id], -@max_details)

    {:reply, %{}, socket |> assign(open_details: open) |> refresh_details()}
  end

  # The person moved, hid, pinned or resized columns. When the columns that
  # show changed, the browser drops its rows, and the answer has those
  # from `from`, in the new layout.
  def handle_event("masu:layout", params, socket) when is_map(params) do
    %{layout: layout, all_columns: all, columns: old, revision: revision} = socket.assigns
    layout = Layout.change(layout, params, all)
    columns = Layout.columns(layout, all)
    moved? = Enum.map(columns, & &1.key) != Enum.map(old, & &1.key)

    socket =
      socket
      |> assign(layout: layout, columns: columns)
      |> then(
        &if(moved?, do: assign(&1, revision: revision + 1, initial: nil, changed: []), else: &1)
      )
      |> view_changed()

    from = if is_integer(params["from"]), do: max(params["from"], 0), else: 0

    {reply, socket} =
      if moved?,
        do: block(socket, from, socket.assigns.block_size),
        else: {%{"revision" => socket.assigns.revision}, socket}

    {:reply, reply, socket}
  end

  # The views menu, and Masu.Test: a saved view, the grid's own, or one of
  # params; saving and deleting a named view.
  def handle_event("masu:view", %{"action" => "apply", "id" => id}, socket) do
    case Enum.find(socket.assigns.saved_views, &(&1.id == id)) do
      nil -> {:reply, %{"error" => "This view no longer exists."}, socket}
      saved -> apply_params(socket, saved.params)
    end
  end

  def handle_event("masu:view", %{"action" => "params", "params" => params}, socket)
      when is_map(params),
      do: apply_params(socket, params)

  def handle_event("masu:view", %{"action" => "reset"}, socket),
    do: apply_params(socket, %{})

  def handle_event("masu:view", %{"action" => "save", "name" => name} = params, socket)
      when is_binary(name) do
    %{views: views, user: user, view_params: view_params} = socket.assigns

    # The name as it is saved, trimmed, is the one checked.
    name = String.trim(name)

    case {name, Input.name(name)} do
      {"", _check} ->
        {:reply, %{"error" => "A view needs a name."}, socket}

      {_name, {:error, message}} ->
        {:reply, %{"error" => message}, socket}

      {_name, :ok} when is_nil(views) or is_nil(user) ->
        {:reply, %{"error" => "This grid does not keep views."}, socket}

      {name, :ok} ->
        case views.save(
               views_key(socket.assigns),
               user,
               name,
               view_params,
               params["shared"] == true
             ) do
          {:ok, saved} -> {:reply, %{"id" => saved.id}, list_views(socket)}
          {:error, message} -> {:reply, %{"error" => message}, socket}
        end
    end
  end

  def handle_event("masu:view", %{"action" => "delete", "id" => id}, socket) when is_binary(id) do
    %{views: views, user: user} = socket.assigns
    if views && user, do: :ok = views.delete(views_key(socket.assigns), user, id)
    {:reply, %{}, list_views(socket)}
  end

  # How many rows are selected, and whether they are every row of the query.
  defp change_selection(_selection, %{"all" => all}, _source) when is_boolean(all),
    do: %{all: all, ids: MapSet.new(), except: MapSet.new()}

  # An id that cannot be of a row is not selected: an action's `{:ids,
  # ids}` and the query of every row but some have only ids of rows.
  defp change_selection(selection, %{"ids" => ids, "on" => on}, source)
       when is_list(ids) and is_boolean(on) do
    ids = ids |> Enum.take(10_000) |> Enum.filter(&Source.id?(source, &1))

    case {selection.all, on} do
      {true, true} ->
        %{selection | except: Enum.reduce(ids, selection.except, &MapSet.delete(&2, &1))}

      {true, false} ->
        %{selection | except: Enum.reduce(ids, selection.except, &MapSet.put(&2, &1))}

      {false, true} ->
        %{selection | ids: Enum.reduce(ids, selection.ids, &MapSet.put(&2, &1))}

      {false, false} ->
        %{selection | ids: Enum.reduce(ids, selection.ids, &MapSet.delete(&2, &1))}
    end
  end

  defp change_selection(selection, _params, _source), do: selection

  defp selection_summary(%{selection: %{all: true, except: except}, total: total}),
    do: %{all: true, count: max(total - MapSet.size(except), 0)}

  defp selection_summary(%{selection: %{ids: ids}}), do: %{all: false, count: MapSet.size(ids)}

  defp selection_config(%{selectable: false}), do: nil

  defp selection_config(%{selection: selection} = assigns) do
    %{
      "all" => selection.all,
      "ids" => MapSet.to_list(selection.ids),
      "except" => MapSet.to_list(selection.except),
      "count" => selection_summary(assigns).count,
      "exact" => assigns.exact
    }
  end

  defp export_formats(%{export: true}), do: [:csv, :xlsx]
  defp export_formats(%{export: formats}) when is_list(formats), do: formats
  defp export_formats(_assigns), do: []

  # The rows selected, as Masu.Live.selected/1 gives them.
  defp selected(%{selection: %{all: true, except: except}} = assigns) do
    Source.select_all(
      assigns.source,
      assigns.query,
      assigns.all_columns,
      MapSet.to_list(except),
      row_id(assigns)
    )
  end

  defp selected(%{selection: %{ids: ids}}), do: {:ids, MapSet.to_list(ids)}

  # What the grid gives its LiveView (Masu.Live.export/1).
  defp export_of(assigns) do
    %Masu.Export{
      input: assigns.input,
      opts: source_opts(assigns),
      query: assigns.query,
      columns: assigns.columns,
      all_columns: assigns.all_columns,
      name: assigns.id
    }
  end

  # The same view with its rows again (a tree's rows opened or closed).
  defp reprepare(socket, query, from) do
    %{source: source, all_columns: all, revision: revision} = socket.assigns
    source = Source.prepare(source, query, all)

    socket =
      socket
      |> assign(
        query: query,
        source: source,
        revision: revision + 1,
        initial: nil,
        changed: []
      )
      |> recount()
      |> refresh_details()

    from = if is_integer(from), do: max(from, 0), else: 0
    {reply, socket} = block(socket, from, socket.assigns.block_size)
    {:reply, reply, socket}
  end

  # The item of the open panel, as the LiveView renders it now: none
  # when the LiveView no longer offers it (`:if`).
  defp panel_action(%{action_panel: nil}), do: nil

  defp panel_action(%{action_panel: %{kind: kind, index: index}} = assigns) do
    actions = if kind == :header, do: assigns.header_actions, else: assigns.cell_actions

    case Enum.at(actions, index) do
      %Action{slot: slot} = action when slot != nil -> action
      _other -> nil
    end
  end

  # The item `index` of the header or cell menus, if the grid offers it
  # for the column `key`, and it does something here (not only a JS
  # command). Its label, when the browser gives it, is the one it showed:
  # the items of a LiveView that changed (`:if`) are in other places.
  defp find_action(assigns, kind, index, key, label) do
    actions = if kind == "header", do: assigns.header_actions, else: assigns.cell_actions

    with %Action{} = action <- Enum.at(actions, index),
         true <- is_nil(label) or label == action.label,
         true <- Action.server?(action),
         %Column{} = column <- Column.find(assigns.columns, key),
         true <- Action.for?(action, column) do
      {:ok, action, column}
    else
      _other -> {:error, "action"}
    end
  end

  defp action_context(assigns, %Action{kind: :header}, column, _params),
    do: {:ok, Map.put(base_context(assigns), :column, column.key)}

  defp action_context(assigns, %Action{kind: :cell}, column, %{"id" => id} = params) do
    row_id = row_id(assigns)

    case Source.fetch(assigns.source, [id], row_id) do
      [row | _] ->
        context =
          Map.merge(base_context(assigns), %{
            column: column.key,
            id: row_id.(row),
            row: row,
            value: Column.get(column, row),
            range: action_range(assigns, params["range"])
          })

        {:ok, context}

      [] ->
        {:error, "row"}
    end
  end

  defp action_context(_assigns, _action, _column, _params), do: {:error, "row"}

  # A value of a cell's history back: its value before the entry, if the
  # cell still has the value of its latest entry (what the person saw).
  defp restore_value([%Masu.History.Entry{op: :update, key: key} = entry], store, grid)
       when key != nil do
    latest =
      case store.for_cell(grid, entry.row_id, key, limit: 1) do
        [latest | _] -> latest
        [] -> entry
      end

    [%{"id" => entry.row_id, "key" => key, "value" => entry.before, "before" => latest.after}]
  end

  defp restore_value(_entries, _store, _grid), do: []

  # The edits that bring cells back to their values before entries (as
  # the store gives them, in the order they were recorded): a cell's
  # value before the first of
  # them, if it still has the value after the last.
  defp restored(edits, errors) do
    refused = MapSet.new(errors, fn [id, key | _] -> {id, key} end)
    Enum.count(edits, &(not MapSet.member?(refused, {&1["id"], &1["key"]})))
  end

  # A batch is a token the grid made (16 characters): a text that is not
  # one is an unknown batch.
  defp restore_batch(store, grid, batch) do
    case Input.text(batch, "a batch", 64) do
      :ok -> grid |> store.batch(batch) |> restore_edits()
      {:error, _message} -> []
    end
  end

  defp restore_edits(entries) do
    entries
    |> Enum.filter(&(&1.op == :update and &1.key != nil))
    |> Enum.group_by(&{&1.row_id, &1.key})
    |> Enum.map(fn {{row_id, key}, cell} ->
      %{
        "id" => row_id,
        "key" => key,
        "value" => hd(cell).before,
        "before" => List.last(cell).after
      }
    end)
  end

  # Whether the row's state lets the column's cell edit.
  defp row_edits?(assigns, row, column) do
    (is_nil(assigns.row_editable) or assigns.row_editable.(row) != false) and
      Column.editable?(column, row)
  end

  # The open editor of a cell that is a form of the app's: the column, as
  # the grid shows it now (none, when it no longer edits with a form).
  defp cell_editor(%{cell_editor: nil}), do: nil

  defp cell_editor(%{cell_editor: %{key: key}, columns: columns}) do
    case Column.find(columns, key) do
      %Column{editable: true, editor: {:form, _fun}} = column -> column
      _other -> nil
    end
  end

  # What every action's context has: the grid, the scope, and a ref of
  # its own (for `:async`).
  defp base_context(assigns) do
    {ref, _token} = Masu.Ref.new(assigns.id)
    %{grid: assigns.id, scope: assigns.scope, ref: ref}
  end

  defp fetch_row(_assigns, nil, _row_id), do: []
  defp fetch_row(assigns, id, row_id), do: Source.fetch(assigns.source, [id], row_id)

  # The people whose editor is open on a cell of the row (Masu.Presence).
  defp editors(assigns, id) do
    for %{editing: true, cell: [^id | _]} = person <- assigns.people,
        do: Map.take(person, [:id, :name, :color])
  end

  # Runs an action that is not a panel, and answers with its result: done
  # (with a message), failed, or going on (`:async`) until Masu.reply/2.
  # An action on rows reads them again when it is done, and clears the
  # selection it was on.
  defp run_action(socket, action, context) do
    {_pid, _grid, token} = Masu.Ref.decode!(context.ref)

    case Action.run(action, context) do
      :async ->
        socket =
          socket
          |> put_pending(token, %{kind: :action, action: action})
          |> accepted(action)

        {:reply, %{"async" => token}, socket}

      {:error, message} ->
        {:reply, %{"failed" => message}, socket}

      done ->
        reply = with {:ok, message} <- done, do: %{"ok" => true, "message" => message}
        reply = if reply == :ok, do: %{"ok" => true}, else: reply
        {:reply, reply, socket |> accepted(action) |> done_action(action)}
    end
  end

  # An action on the selection, accepted: the selection is cleared,
  # unless the action keeps it.
  defp accepted(socket, %Action{kind: :selection, keep_selection: false}) do
    socket = assign(socket, selection: %{all: false, ids: MapSet.new(), except: MapSet.new()})

    if is_function(socket.assigns.on_select, 1),
      do: socket.assigns.on_select.(selection_summary(socket.assigns))

    socket
  end

  defp accepted(socket, _action), do: socket

  defp done_action(socket, %Action{kind: kind}) when kind in [:selection, :row],
    do: refresh(socket)

  defp done_action(socket, _action), do: socket

  defp put_pending(socket, nil, _entry), do: socket

  defp put_pending(socket, token, entry),
    do: assign(socket, pending: Map.put(socket.assigns.pending, token, entry))

  # A reply of a write or an action that went on later: to the browser,
  # which says it; the rows read again.
  defp replied(socket, token, entry, result) do
    {ok?, message} = outcome(result)

    socket =
      case entry do
        %{kind: :action, action: action} when ok? -> done_action(socket, action)
        %{kind: :action} -> socket
        %{op: :delete, ids: ids} when ok? -> socket |> unselect_ids(ids) |> refresh()
        _write -> refresh(socket)
      end

    push_event(socket, "masu:reply", %{
      "id" => socket.assigns.id,
      "token" => token,
      "ok" => ok?,
      "message" => message,
      "errors" => if(ok?, do: [], else: refused(entry, message)),
      "revision" => socket.assigns.revision,
      "total" => socket.assigns.total
    })
  end

  defp outcome(:ok), do: {true, nil}
  defp outcome({:ok, message}) when is_binary(message), do: {true, message}
  defp outcome({:error, message}) when is_binary(message), do: {false, message}
  defp outcome(other), do: {false, "It failed: #{inspect(other)}"}

  # What a write that failed later refused: its cells, or its rows.
  defp refused(%{kind: :write, op: :update, cells: cells}, message),
    do: for([id, key] <- cells, do: [id, key, message])

  defp refused(%{kind: :write, op: :delete, ids: ids}, message),
    do: for(id <- ids, do: [id, message])

  defp refused(_entry, _message), do: []

  # The rows again, as the source has them now (an action changed them):
  # the LiveView of a controlled grid gives its own.
  defp refresh(socket) do
    %{source: source, query: query, all_columns: all, revision: revision} = socket.assigns

    cond do
      controlled?(socket.assigns) ->
        socket

      async?(socket.assigns) ->
        read_async(socket, source, query, socket.assigns.page, false)

      true ->
        socket
        |> assign(
          source: Source.prepare(source, query, all),
          revision: revision + 1,
          initial: nil,
          changed: []
        )
        |> recount(keep: true)
        |> refresh_details()
    end
  end

  defp drop_nil(map, key), do: if(is_nil(map[key]), do: Map.delete(map, key), else: map)

  # A range of rows and columns, as the browser has it: the columns that
  # the grid shows, and no more rows than a copy takes.
  defp action_range(assigns, %{"ids" => ids, "keys" => keys})
       when is_list(ids) and is_list(keys) do
    shown = Enum.map(assigns.columns, & &1.key)
    %{ids: Enum.take(ids, 10_000), columns: Enum.filter(keys, &(&1 in shown))}
  end

  defp action_range(_assigns, _range), do: nil

  # The rows of the open details, read again, with their places in the
  # person's order (nil: their filters leave the row out).
  defp refresh_details(%{assigns: %{detail: []}} = socket), do: socket

  defp refresh_details(%{assigns: %{open_details: []}} = socket),
    do: assign(socket, detail_rows: [])

  defp refresh_details(socket) do
    %{source: source, open_details: open} = socket.assigns
    row_id = row_id(socket.assigns)
    rows = source |> Source.fetch(open, row_id) |> Map.new(&{Value.to_wire(row_id.(&1)), &1})

    detail_rows =
      for id <- open, row = rows[id], index = Source.locate(source, id, row_id), index != nil do
        {id, row, index}
      end

    assign(socket, detail_rows: detail_rows)
  end

  defp apply_params(socket, params) do
    %{all_columns: all, default_view: default} = socket.assigns
    {view, dropped} = View.from_params(params, all, default)
    socket = apply_view(socket, view, dropped)
    {:reply, %{"revision" => socket.assigns.revision, "dropped" => dropped}, socket}
  end

  # A selected range goes to the others as its rows' ids (at most 500) and
  # its columns' keys: the rows are where each person's order puts them.
  defp range(%{"rows" => rows, "keys" => keys}) when is_list(rows) and is_list(keys),
    do: %{"rows" => Enum.take(rows, 500), "keys" => Enum.filter(keys, &is_binary/1)}

  defp range(_other), do: nil

  # The first row on the person's screen, by its id.
  defp top(id) when is_binary(id) or is_integer(id), do: id
  defp top(_other), do: nil

  defp share_view(%{assigns: %{issho: issho} = assigns} = socket) when issho != nil do
    _ = Masu.Issho.Live.put(issho, assigns.id, %{view: shared_view(assigns)})
    socket
  end

  defp share_view(%{assigns: %{presence: presence, tracked: topic} = assigns} = socket)
       when presence != nil and is_binary(topic) do
    case shared_view(assigns) do
      nil -> :ok
      view -> :ok = Masu.Presence.update(presence, topic, assigns.user, %{view: view})
    end

    socket
  end

  defp share_view(socket), do: socket

  # A block of rows, and what it says of the count (`learn/4`): the
  # answer, and the socket that knows it.
  defp block(socket, from, count) do
    %{source: source} = socket.assigns

    {rows, socket} =
      cond do
        count == 0 ->
          {[], socket}

        nodes = Source.nodes(source, from, count) ->
          {encode_rows(nodes, socket.assigns, from), socket}

        true ->
          {rows, known} = Source.window(source, from, count)
          socket = if known, do: put_count(socket, {known, true}), else: socket
          socket = assign(socket, source: Source.seen(source, from, rows))
          {encode_rows(rows, socket.assigns, from), socket}
      end

    socket = learn(socket, from, length(rows), count)
    %{total: total, exact: exact, revision: revision} = socket.assigns

    {%{
       "from" => from,
       "rows" => rows,
       "total" => total,
       "exact" => exact,
       "revision" => revision
     }, socket}
  end

  # A query that a controlled grid's LiveView runs, or a task: the answer
  # says so, and the rows come after it; or nil, for a query read now.
  defp pending_query(socket, query) do
    cond do
      controlled?(socket.assigns) ->
        socket = socket |> assign(query: query, page: 0) |> report() |> view_changed()
        {:reply, pending_reply(socket, query), socket}

      async?(socket.assigns) and connected?(socket) ->
        socket = read_async(socket, socket.assigns.source, query, 0, true)
        {:reply, pending_reply(socket, query), socket}

      true ->
        nil
    end
  end

  defp pending_reply(socket, query),
    do: %{
      "pending" => true,
      "revision" => socket.assigns.revision,
      "query" => Query.to_wire(query)
    }

  # A query read now: its first rows in the answer.
  defp run_query(socket, source, query, columns, revision) do
    source = Source.prepare(source, query, columns)

    socket =
      socket
      |> assign(
        source: source,
        query: query,
        page: 0,
        revision: revision + 1,
        initial: nil,
        changed: []
      )
      |> recount()
      |> refresh_details()

    {from, count} = first_rows(socket.assigns)
    {reply, socket} = block(socket, from, count)
    reply = Map.put(reply, "query", Query.to_wire(query))

    {:reply, reply, view_changed(socket)}
  end

  # A block of rows in a task (`load={:async}`).
  defp read_block(socket, from, count) do
    %{source: source, revision: revision} = socket.assigns
    name = {:masu_block, from, count, revision}

    task = fn -> guarded(fn -> read_window(source, from, count) end) end

    socket |> start_async(name, task) |> time_out(name)
  end

  # A block read in a task, as block/3 answers it.
  defp take_block(socket, window, from, count) do
    {rows, socket} =
      case window do
        {:nodes, nodes} ->
          {encode_rows(nodes, socket.assigns, from), socket}

        {:rows, {rows, known}} ->
          socket = if known, do: put_count(socket, {known, true}), else: socket
          socket = assign(socket, source: Source.seen(socket.assigns.source, from, rows))
          {encode_rows(rows, socket.assigns, from), socket}
      end

    socket = learn(socket, from, length(rows), count)
    %{total: total, exact: exact, revision: revision} = socket.assigns

    {%{
       "from" => from,
       "rows" => rows,
       "total" => total,
       "exact" => exact,
       "revision" => revision
     }, socket}
  end

  # The count (`count`): `:exact` counts with the query; `:deferred` reads
  # the rows first, and counts in a task; `:none` counts when the person
  # goes to the end (`masu:count`). A source may not know its count
  # (`{:at_least, n}`, `:unknown`): the grid then knows the rows it read,
  # and more (`learn/4`). `keep: true` keeps the count it had as a lower
  # bound while it does not know (the same query, its rows changed).
  defp recount(socket, opts \\ []) do
    %{source: source, count_ref: ref} = socket.assigns
    ref = ref + 1
    known = if Keyword.get(opts, :keep, false), do: socket.assigns.total, else: 0
    socket = assign(socket, count_ref: ref)

    case socket.assigns.count do
      :none ->
        assign(socket, total: known, exact: false)

      :deferred ->
        socket |> assign(total: known, exact: false) |> count_later(ref, source)

      _exact ->
        put_count(socket, Source.counted(source))
    end
  end

  # The count in a task, in the connected LiveView; its answer is taken
  # if no other count came after it (`count_ref`).
  defp count_later(socket, ref, source) do
    if connected?(socket),
      do: start_async(socket, :masu_count, fn -> {ref, Source.counted(source)} end),
      else: socket
  end

  defp put_count(socket, {n, true}), do: assign(socket, total: n, exact: true)

  defp put_count(socket, {n, false}),
    do: assign(socket, total: max(n, socket.assigns.total), exact: false)

  # Rows read from `from` (`got` of the `asked`) say where the rows end
  # when there are fewer, and that there are at least as many as they
  # reach. A block past the end (none, from a place past it) asks the
  # source for its count.
  defp learn(%{assigns: %{exact: true}} = socket, _from, _got, _asked), do: socket

  defp learn(socket, from, 0, asked) when from > 0 and asked > 0,
    do: put_count(assign(socket, total: 0), Source.counted(socket.assigns.source))

  defp learn(socket, from, got, asked) when got < asked,
    do: assign(socket, total: from + got, exact: true)

  defp learn(socket, from, got, _asked),
    do: assign(socket, total: max(socket.assigns.total, from + got))

  # The first rows of a view: of its page (`paging={:pages}`), or of the
  # top.
  defp first_rows(%{paging: :pages, page: page, page_size: size}), do: {page * size, size}
  defp first_rows(assigns), do: {0, assigns.block_size}

  # A row as the browser gets it: its id, its cells, then its read-only
  # cells (`locks?/1`), then its row actions (`[id, disabled, href]` of
  # each it shows), then its place in the tree (Masu.Tree). `from` is
  # the place of the first row: a row's id with `row_id={:position}`, or
  # of a row without one in a grid that needs none.
  defp encode_rows(rows, assigns, from \\ 0) do
    id_of = id_of(assigns)
    locks? = locks?(assigns)

    rows
    |> Enum.with_index(from)
    |> Enum.map(fn
      # A group's row: its totals in their columns, read-only, then its
      # place and [key, value, count] (Masu.Group).
      {{%Group{} = group, info}, _index} ->
        cells =
          [Group.id(group) | Enum.map(assigns.columns, &Value.to_wire(group.aggregates[&1.key]))]

        cells = if locks?, do: cells ++ [true], else: cells
        cells = if assigns.row_actions != [], do: cells ++ [[]], else: cells
        cells ++ [Tree.to_wire(info), [group.key, Value.to_wire(group.value), group.count]]

      {row_or_node, index} ->
        {row, info} =
          case row_or_node do
            {row, %{level: _} = info} -> {row, info}
            row -> {row, nil}
          end

        cells = [id_of.(row, index) | cells(assigns.columns, row)]
        cells = if locks?, do: cells ++ [locks(assigns, row)], else: cells

        cells =
          if assigns.row_actions != [],
            do: cells ++ [Action.row_wire(assigns.row_actions, row)],
            else: cells

        if info, do: cells ++ [Tree.to_wire(info)], else: cells
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

  # Rows saved, created, restored or deleted here: the source takes them,
  # and the query applies again; the LiveViews of the grid's topic get
  # them, and the LiveView's own callbacks.
  defp take_saved(socket, upserts, deleted \\ [])
  defp take_saved(socket, [], []), do: socket

  defp take_saved(socket, upserts, deleted) do
    %{source: source, query: query, all_columns: columns, revision: revision} = socket.assigns
    row_id = row_id(socket.assigns)
    changes = upserts ++ Enum.map(deleted, &{:delete, &1})
    source = source |> Source.change(changes, row_id) |> Source.prepare(query, columns)
    saved = for {:upsert, row} <- upserts, do: row

    broadcast(socket.assigns.live, saved, socket.assigns.user)
    broadcast_deleted(socket.assigns.live, deleted)

    socket
    |> assign(
      source: source,
      revision: revision + 1,
      initial: nil,
      changed: []
    )
    |> recount(keep: true)
    |> refresh_details()
  end

  defp ids_to_delete(%{"ids" => ids}, _assigns) when is_list(ids), do: {:ok, ids}

  defp ids_to_delete(%{"selection" => true}, assigns) do
    max = Masu.Edit.max_rows()

    ids =
      case selected(assigns) do
        {:ids, ids} -> ids
        {:query, query} -> EctoSource.ids_of(assigns.source.state, query, max + 1)
      end

    if length(ids) > max,
      do: {:error, "Too many rows to delete at once: #{max} at most."},
      else: {:ok, Enum.map(ids, &Value.to_wire/1)}
  end

  defp ids_to_delete(_params, _assigns), do: {:error, "No rows to delete."}

  # Deleted rows leave the selection.
  defp unselect(socket, []), do: socket

  defp unselect(socket, deleted) do
    row_id = row_id(socket.assigns)
    unselect_ids(socket, Enum.map(deleted, &Value.to_wire(row_id.(&1))))
  end

  defp unselect_ids(socket, ids) do
    %{selection: selection} = socket.assigns

    assign(socket,
      selection: %{
        selection
        | ids: Enum.reduce(ids, selection.ids, &MapSet.delete(&2, &1)),
          except: Enum.reduce(ids, selection.except, &MapSet.delete(&2, &1))
      }
    )
  end

  # The rows of the last deletes, for an undo: a token for each.
  @max_trash 20

  defp put_trash(socket, [], _places), do: {nil, socket}

  defp put_trash(socket, deleted, places) do
    if Masu.Edit.restores?(socket.assigns) do
      token = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
      trash = Enum.take([{token, deleted, places} | socket.assigns.trash], @max_trash)
      {token, assign(socket, trash: trash)}
    else
      {nil, socket}
    end
  end

  # The places of rows in a list, so that an undo puts them back there
  # (an upsert of a row a list does not have puts it at its end).
  defp places(%Source{module: ListSource, state: state}, ids, row_id),
    do: ListSource.places(state, ids, row_id)

  defp places(_source, _ids, _row_id), do: %{}

  defp reinsert(
         %{assigns: %{source: %Source{module: ListSource} = source}} = socket,
         rows,
         places,
         row_id
       ) do
    placed =
      for row <- rows, index = Map.get(places, Value.to_wire(row_id.(row))), do: {index, row}

    assign(socket, source: %{source | state: ListSource.reinsert(source.state, placed)})
  end

  defp reinsert(socket, _rows, _places, _row_id), do: socket

  defp broadcast_deleted(nil, _rows), do: :ok

  defp broadcast_deleted({pubsub, topic}, rows) do
    for row <- rows, do: Masu.Live.broadcast_delete_from(self(), pubsub, topic, row)
    :ok
  end

  defp broadcast(nil, _rows, _user), do: :ok

  defp broadcast({pubsub, topic}, rows, user) do
    by = if user, do: %{name: Map.get(user, :name), color: Masu.Presence.color(user)}
    for row <- rows, do: Masu.Live.broadcast_upsert_from(self(), pubsub, topic, row, by)
    :ok
  end

  defp row_id(%{row_id: fun}) when is_function(fun, 1), do: fun
  defp row_id(_assigns), do: &default_row_id/1

  # A row's id as the browser has it. With `row_id={:position}`, its place
  # in the query. A row with no id is given its place in a grid that needs
  # none (a table that shows rows); a grid that needs ids says which.
  defp id_of(%{row_id: :position}), do: fn _row, index -> index end

  defp id_of(assigns) do
    row_id = row_id(assigns)

    features = stable_id_features(assigns)

    fn row, index ->
      case Value.to_wire(row_id.(row)) do
        nil when features == [] -> index
        nil -> raise ArgumentError, missing_id(assigns.id, features)
        id -> id
      end
    end
  end

  @doc false
  # What a grid does that needs its rows' ids to stay the same from one
  # query to the next: the attributes that turn it on.
  @spec stable_id_features(map()) :: [String.t()]
  def stable_id_features(assigns) do
    [
      edit: assigns[:changeset] != nil or assigns[:on_update] != nil,
      create: assigns[:on_create] != nil or assigns[:struct] != nil,
      delete: assigns[:on_delete] != nil or assigns[:deletable] not in [nil, false],
      row_action: assigns[:row_action] not in [nil, []],
      selectable: assigns[:selectable] == true,
      live: assigns[:live] != nil,
      presence: assigns[:presence] != nil or assigns[:issho] != nil,
      detail: assigns[:detail] not in [nil, []],
      tree: assigns[:tree] != nil
    ]
    |> Enum.filter(&elem(&1, 1))
    |> Enum.map(fn
      {:edit, _on} -> "changeset or on_update"
      {:create, _on} -> "on_create or struct"
      {:delete, _on} -> "on_delete or deletable"
      {:row_action, _on} -> ":row_action"
      {:detail, _on} -> ":detail"
      {key, _on} -> Atom.to_string(key)
    end)
  end

  defp missing_id(grid, features) do
    "a row of the grid #{grid} has no id, and its #{Enum.join(features, ", ")} needs one: " <>
      "give its rows an `id`, or give the grid `row_id`, a function of a row that gives its id"
  end

  defp cells(columns, row) do
    Enum.map(columns, fn
      %Column{slot: nil} = column ->
        Column.wire(column, row)

      # An editable column of HEEx sends its value too, for the editor.
      %Column{slot: slot, editable: true} = column ->
        [slot_html(slot, row), Column.wire(column, row)]

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
    # The grid as its LiveView may read it (Masu.Live.export/1).
    :ok =
      Masu.Live.put_grid(assigns.id, %{
        export: export_of(assigns),
        selected: fn -> selected(assigns) end
      })

    assigns =
      assigns
      |> assign(:messages, Map.merge(@messages, stringify(assigns.messages)))
      |> assign(:cols, Enum.map_join(assigns.columns, " ", &"#{&1.width}px"))

    ~H"""
    <div
      id={@id}
      class={["masu", @density != :normal && "masu-density-#{@density}", @class]}
      phx-hook="Masu"
      phx-target={@myself}
      data-issho-doc={@issho && Masu.Issho.Live.doc(@issho, @id)}
      data-masu={config(assigns)}
      data-masu-messages={JSON.encode!(@messages)}
      style={"height: #{@height}"}
      {@rest}
    >
      <div
        :if={(@presence || @issho_config) && @show_people}
        class="masu-people"
        role="group" aria-label={@messages["people"]}>
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
      </div>
      <%!-- Always there, as the panels' (below). A read that runs: its state,
           and Stop; one that failed: its error, and Run again. --%>
      <div id={"#{@id}-state"} class="masu-state">
        <div :if={running?(assigns)} class="masu-running" role="status">
          <span class="masu-running-text">{@messages["running"]}</span>
          <button
            :if={async?(assigns) and @running != :connecting}
            type="button"
            class="masu-state-button"
            phx-click="masu:cancel"
            phx-target={@myself}
          >
            {@messages["stop"]}
          </button>
        </div>
        <div :if={@error && !running?(assigns)} class="masu-error" role="alert">
          <span class="masu-error-text">{@error}</span>
          <button
            type="button"
            class="masu-state-button"
            phx-click="masu:retry"
            phx-target={@myself}
          >
            {@messages["retry"]}
          </button>
        </div>
      </div>
      <%!-- Always there: a panel that comes or goes moves no element beside it. --%>
      <div id={"#{@id}-panels"} class="masu-panels">
        <div
          :if={panel = panel_action(assigns)}
          id={"#{@id}-action-panel"}
          class="masu-menu masu-panel masu-action-panel"
          popover="manual"
          role="dialog"
          aria-label={panel.label}
          tabindex="-1"
          data-kind={panel.kind}
          data-key={@action_panel.context.column}
          data-id={Map.has_key?(@action_panel.context, :id) && JSON.encode!(Value.to_wire(@action_panel.context.id))}
        >
          {render_slot([panel.slot], @action_panel.context)}
        </div>
        <.live_component
          :if={column = cell_editor(assigns)}
          module={Masu.CellEditor}
          id={"#{@id}-cell-editor"}
          grid={@id}
          column={column}
          editor={@cell_editor}
          scope={@scope}
        />
      </div>
      <%!-- The scroll box is the server's, for the details it renders in it;
           its rows are the browser's (phx-update="ignore"). --%>
      <div
        id={"#{@id}-grid"}
        class="masu-grid"
        role={if @tree || @query.groups != [], do: "treegrid", else: "grid"}
        tabindex="0"
        aria-label={@label}
        aria-labelledby={@label_id}
        aria-rowcount={if @exact, do: @total + 1, else: -1}
        aria-colcount={length(@columns)}
        aria-multiselectable="true"
        style={"--masu-row-height: #{@row_height}px"}
      >
        <div
          id={"#{@id}-content"}
          class="masu-content"
          phx-update="ignore"
          style={"--masu-cols: #{@cols}"}
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
          <div class="masu-body" role="rowgroup" style={"height: #{body_rows(assigns) * @row_height}px"}>
            <div
              :for={{row, index} <- Enum.with_index(first_shown(@initial))}
              class={["masu-row", rem(@initial_from + index, 2) == 1 && "masu-row-even"]}
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
                  {Column.wire(column, row)}
                <% end %>
              </div>
            </div>
          </div>
          <div class="masu-empty" hidden={@total > 0 or running?(assigns)}>
            <%= if @empty != [] do %>
              {render_slot(@empty)}
            <% else %>
              {@messages["empty"]}
            <% end %>
          </div>
        </div>
        <div :if={@detail != []} id={"#{@id}-details"} class="masu-details">
          <div
            :for={{id, row, _index} <- @detail_rows}
            id={"#{@id}-detail-#{:erlang.phash2(id)}"}
            class="masu-detail"
            role="region"
            aria-label={@messages["detail"]}
            data-id={JSON.encode!(id)}
          >
            {render_slot(@detail, row)}
          </div>
        </div>
      </div>
      <nav :if={@paging == :pages} class="masu-pager" aria-label={@messages["pages"]}>
        <span class="masu-pager-range">{pager_range(assigns)}</span>
        <button
          type="button"
          class="masu-pager-previous"
          phx-click="masu:goto"
          phx-value-page={@page}
          phx-target={@myself}
          disabled={@page == 0}
        >
          {@messages["previous"]}
        </button>
        <form class="masu-pager-form" phx-submit="masu:goto" phx-target={@myself}>
          <label>
            {@messages["page"]}
            <input
              type="number"
              name="page"
              min="1"
              max={last_page(assigns) && last_page(assigns) + 1}
              value={@page + 1}
              inputmode="numeric"
            />
          </label>
          <span :if={last_page(assigns)}>{pager_of(assigns)}</span>
        </form>
        <button
          type="button"
          class="masu-pager-next"
          phx-click="masu:goto"
          phx-value-page={@page + 2}
          phx-target={@myself}
          disabled={not next_page?(assigns)}
        >
          {@messages["next"]}
        </button>
      </nav>
      <div id={"#{@id}-status"} class="masu-status" role="status" aria-live="polite" phx-update="ignore">
      </div>
    </div>
    """
  end

  # The pager (`paging={:pages}`): "1–50 of 1,234", or of "1,000+" while
  # the count is not known; the last page, when it is; a next page while
  # the page is full.
  defp pager_range(%{page: page, page_size: size, total: total, exact: exact} = assigns) do
    first = page * size
    shown = min(size, max(total - first, 0))
    shown = if exact, do: shown, else: max(shown, length(assigns.initial || []))

    if shown == 0 do
      assigns.messages["empty"]
    else
      of = if exact, do: number(total), else: number(total) <> "+"

      assigns.messages["range"]
      |> String.replace("{first}", number(first + 1))
      |> String.replace("{last}", number(first + shown))
      |> String.replace("{count}", of)
    end
  end

  defp pager_of(assigns),
    do: String.replace(assigns.messages["of_pages"], "{count}", number(last_page(assigns) + 1))

  defp last_page(%{exact: true, total: total, page_size: size}),
    do: max(div(max(total, 1) - 1, size), 0)

  defp last_page(_assigns), do: nil

  defp next_page?(%{exact: true} = assigns), do: assigns.page < last_page(assigns)

  defp next_page?(%{total: total, page: page, page_size: size}),
    do: total >= (page + 1) * size

  # A number with its thousands, as the pager shows it (the browser's
  # locale is the browser's; the pager's is plain).
  defp number(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  # The rows the server renders of the first block it read.
  defp first_shown(rows), do: Enum.take(rows || [], @initial_rows)

  # The rows the body is tall for, before the browser takes over: a
  # page's, or the count's.
  defp body_rows(%{paging: :pages} = assigns), do: length(assigns.initial || [])
  defp body_rows(assigns), do: assigns.total

  defp aria_sort(%Query{sorts: [%{key: key, direction: direction} | _]}, %Column{key: key}),
    do: if(direction == :asc, do: "ascending", else: "descending")

  defp aria_sort(_query, %Column{sortable: true}), do: "none"
  defp aria_sort(_query, _column), do: nil

  defp config(assigns) do
    JSON.encode!(%{
      "v" => 1,
      "columns" => Enum.map(assigns.columns, &column_config(&1, assigns)),
      "rowHeight" => assigns.row_height,
      "total" => assigns.total,
      "exact" => assigns.exact,
      "paging" => Atom.to_string(assigns.paging),
      "pageSize" => assigns.page_size,
      "blockSize" =>
        if(assigns.paging == :pages, do: assigns.page_size, else: assigns.block_size),
      "page" => assigns.page,
      "revision" => assigns.revision,
      "query" => Query.to_wire(assigns.query),
      "locale" => assigns.locale,
      "searchable" => assigns.searchable,
      "changed" => assigns.changed,
      "changedBy" => assigns.changed_by,
      "locks" => locks?(assigns),
      "presence" => assigns.presence != nil or assigns.issho_config != nil,
      "catalog" => Enum.map(Layout.all(assigns.layout, assigns.all_columns), &catalog_entry/1),
      "columnsMenu" => assigns.columns_menu,
      "view" => assigns.view_params,
      "views" => views_config(assigns),
      "notice" => assigns.notice,
      "tree" => assigns.tree != nil or assigns.query.groups != [],
      "totals" => totals(assigns),
      # A controlled grid's app runs the query, and has no groups.
      "groupable" => assigns.tree == nil and not controlled?(assigns),
      "export" => Enum.map(export_formats(assigns), &Atom.to_string/1),
      "cellMenu" => Enum.map(assigns.cell_menu, &Atom.to_string/1),
      "history" => assigns.history != nil,
      "actions" => Action.to_wire(assigns.actions),
      "rowActions" => Action.to_wire(assigns.row_actions),
      "running" => running?(assigns),
      "multiSort" => assigns.multi_sort,
      "selection" => selection_config(assigns),
      "creates" => creates?(assigns),
      "deletes" => Masu.Edit.deletes?(assigns),
      "restores" => Masu.Edit.restores?(assigns),
      "detail" => assigns.detail != [],
      "details" => for({id, _row, index} <- assigns.detail_rows, do: [id, index]),
      "initial" =>
        assigns.initial && %{"from" => assigns.initial_from, "rows" => encode_initial(assigns)}
    })
  end

  defp encode_initial(%{initial_nodes: nil} = assigns),
    do: encode_rows(assigns.initial, assigns, assigns.initial_from)

  defp encode_initial(assigns),
    do:
      assigns.initial
      |> Enum.zip(assigns.initial_nodes)
      |> encode_rows(assigns, assigns.initial_from)

  defp column_config(%Column{} = column, assigns) do
    %{
      "headerActions" => Action.to_wire(assigns.header_actions, column),
      "cellActions" => Action.to_wire(assigns.cell_actions, column),
      "key" => column.key,
      "label" => column.label,
      "type" => Atom.to_string(column.type),
      "width" => column.width,
      "minWidth" => column.min_width,
      "align" => Atom.to_string(column.align),
      "sortable" => column.sortable,
      "filterable" => column.filterable,
      "filters" => column.filter_ops && Enum.map(column.filter_ops, &Atom.to_string/1),
      "many" => column.many == true,
      "editable" => column.editable,
      "editor" => editor_config(column.editor),
      "creatable" => column.creatable,
      "values" => column.values && Enum.map(column.values, &Value.to_wire/1),
      "decimals" => column.decimals,
      "raw" => column.raw,
      "html" => column.slot != nil,
      "pinned" => column.pinned && Atom.to_string(column.pinned),
      "aggregate" => aggregate_name(column.aggregate)
    }
  end

  # An editor of the app's: its form, rendered here, or the browser's own,
  # by name, with its options.
  defp editor_config(nil), do: nil
  defp editor_config({:form, _fun}), do: %{"kind" => "form"}

  defp editor_config({:js, name, options}),
    do: %{"kind" => "js", "name" => name, "options" => options}

  defp aggregate_name(nil), do: nil
  defp aggregate_name(aggregate) when is_atom(aggregate), do: Atom.to_string(aggregate)
  defp aggregate_name(_fun), do: "custom"

  # The totals of the query in the columns that show, or nil: no column
  # has an aggregate (Masu.Group).
  defp totals(%{source: source, columns: columns}) do
    if Enum.any?(columns, & &1.aggregate) do
      totals = Source.totals(source)

      for %Column{aggregate: a, key: key} <- columns,
          a != nil,
          into: %{},
          do: {key, Value.to_wire(totals[key])}
    end
  end

  defp catalog_entry(%Column{} = column) do
    %{
      "key" => column.key,
      "label" => column.label,
      "type" => Atom.to_string(column.type),
      "hidden" => column.hidden,
      "pinned" => column.pinned && Atom.to_string(column.pinned),
      "filterable" => column.filterable,
      "width" => column.width
    }
  end

  # The named views for the views menu; nil for a grid that keeps none.
  defp views_config(%{views: nil}), do: nil
  defp views_config(%{user: nil}), do: nil

  defp views_config(assigns) do
    for saved <- assigns.saved_views do
      %{
        "id" => saved.id,
        "name" => saved.name,
        "shared" => saved.shared,
        "mine" => saved.mine,
        "current" => saved.params == assigns.view_params
      }
    end
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end

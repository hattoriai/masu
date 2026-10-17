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

  alias Masu.{Column, Group, Layout, Query, Source, Tree, Value, View}
  alias Phoenix.HTML.Safe

  @max_block 500
  @first_block 100
  @initial_rows 60
  # Rows open on their detail at once: opening one more closes the first.
  @max_details 50

  @messages %{
    "search" => "Search",
    "empty" => "No rows",
    "row" => "{count} row",
    "rows" => "{count} rows",
    "loading" => "Loading",
    "people" => "Also here",
    "follow" => "Follow {label}",
    "view_dropped" => "Part of this view no longer applies: {label}",
    "detail" => "Details"
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
       download: nil,
       selection: %{all: false, ids: MapSet.new(), except: MapSet.new()}
     )}
  end

  @impl true
  def update(%{masu_presence: true}, socket), do: {:ok, refresh_people(socket)}

  # An export writing in a task: how far it got (Masu.Live).
  def update(%{masu_export_progress: {done, total}}, socket) do
    {:ok,
     push_event(socket, "masu:export", %{
       "id" => socket.assigns.id,
       "done" => done,
       "total" => total
     })}
  end

  # The file of an export goes to the browser a part at a time.
  def update(%{masu_download: true}, socket), do: {:ok, download(socket)}

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
    socket = assign(socket, Map.drop(assigns, [:input]))
    columns = Enum.map(assigns.col, &Column.new/1)

    socket =
      cond do
        is_nil(socket.assigns.source) -> start(socket, assigns.input, columns)
        assigns.input != socket.assigns.input -> restart(socket, assigns.input, columns)
        true -> relayout(socket, supported(socket.assigns.source, columns, socket.assigns))
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
      :ok = Masu.Presence.track(presence, topic, user, shared_view(socket.assigns))
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
      "people" =>
        Enum.map(
          people,
          &Map.take(&1, [:id, :name, :color, :cell, :range, :editing, :view, :top])
        )
    })
  end

  defp refresh_people(socket), do: socket

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
      total: Source.count(source),
      revision: revision + 1,
      initial: nil,
      changed: changed,
      changed_by: changed_by
    )
    |> refresh_details()
  end

  # A change from a grid's edit says who saved it; the source does not need it.
  defp without_by({:upsert, row, _by}), do: {:upsert, row}
  defp without_by(change), do: change

  # The grid's first view: of the URL (`url`), else the person's last
  # (`views`), else the grid's own, of its attributes.
  defp start(socket, input, columns) do
    source = Source.new(input, source_opts(socket.assigns))
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
    expanded = MapSet.new(socket.assigns.expanded || [], &Value.to_wire/1)
    view = %{view | query: %{view.query | expanded: expanded}}
    source = Source.prepare(source, view.query, all)

    socket
    |> assign(input: input, source: source, uri: uri, notice: notice(dropped, 1))
    |> put_view(view)
    |> assign(total: Source.count(source))
    |> put_initial()
    |> list_views()
  end

  # The first rows, which the server renders and the browser starts with
  # (in a tree, with their places).
  defp put_initial(%{assigns: %{source: source}} = socket) do
    case Source.nodes(source, 0, @initial_rows) do
      nil ->
        assign(socket, initial: Source.rows(source, 0, @initial_rows), initial_nodes: nil)

      nodes ->
        assign(socket,
          initial: Enum.map(nodes, &elem(&1, 0)),
          initial_nodes: Enum.map(nodes, &elem(&1, 1))
        )
    end
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
  # and the browser drops the rows it has.
  defp restart(socket, input, columns) do
    source = Source.new(input, source_opts(socket.assigns))
    all = supported(source, columns, socket.assigns)
    source = Source.prepare(source, socket.assigns.query, all)

    socket
    |> relayout(all)
    |> assign(
      input: input,
      source: source,
      total: Source.count(source),
      revision: socket.assigns.revision + 1,
      initial: nil,
      changed: []
    )
    |> refresh_details()
  end

  # The columns again (the LiveView rendered the grid again): the person's
  # layout, fitted to them.
  defp relayout(socket, all) do
    layout = Layout.fit(socket.assigns.layout, all)
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
      columns: Layout.columns(layout, socket.assigns.all_columns),
      view_params: View.to_params(view, socket.assigns.default_view)
    )
  end

  # A whole view at once (a saved view, the grid's own, or the URL's):
  # its rows from the first.
  defp apply_view(socket, %View{} = view, dropped, opts \\ []) do
    %{source: source, all_columns: all, revision: revision, query: current} = socket.assigns
    view = %{view | query: %{view.query | expanded: current.expanded}}
    source = Source.prepare(source, view.query, all)

    socket
    |> assign(
      source: source,
      total: Source.count(source),
      revision: revision + 1,
      changed: [],
      notice: notice(dropped, revision + 1)
    )
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
    %{query: query, layout: layout, default_view: default} = socket.assigns
    params = View.to_params(%View{query: query, layout: layout}, default)
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

  defp views_key(assigns), do: assigns.views_key || assigns.id

  defp source_opts(assigns) do
    [
      repo: assigns.repo,
      repo_opts: assigns.repo_opts,
      grid: assigns.id,
      tree: assigns.tree,
      row_id: row_id(assigns)
    ]
  end

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
    %{source: source, query: query, all_columns: columns} = socket.assigns

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
        %{source: source, query: query, all_columns: columns, revision: revision} =
          socket.assigns

        source =
          source
          |> Source.change(Enum.map(saved, &{:upsert, &1}), row_id)
          |> Source.prepare(query, columns)

        broadcast(socket.assigns.live, saved, socket.assigns.user)
        if is_function(socket.assigns.on_save, 1), do: socket.assigns.on_save.(saved)

        socket
        |> assign(
          source: source,
          total: Source.count(source),
          revision: revision + 1,
          initial: nil,
          changed: []
        )
        |> refresh_details()
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

    place = %{
      cell: cell,
      range: range(params["range"]),
      editing: editing,
      top: top(params["top"])
    }

    if presence && topic, do: :ok = Masu.Presence.update(presence, topic, user, place)

    {:noreply, socket}
  end

  def handle_event("masu:query", params, socket) when is_map(params) do
    %{source: source, all_columns: columns, revision: revision} = socket.assigns

    case Query.from_wire(params, columns) do
      {:ok, query} ->
        # The rows the person opened stay open; those they closed in a
        # filter's tree open again with a new filter.
        current = socket.assigns.query
        same_filter? = query.filters == current.filters and query.search == current.search

        query = %{
          query
          | expanded: current.expanded,
            collapsed: if(same_filter?, do: current.collapsed, else: MapSet.new())
        }

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

        socket = refresh_details(socket)

        reply =
          socket
          |> block(0, @first_block)
          |> Map.put("query", Query.to_wire(query))

        {:reply, reply, view_changed(socket)}

      {:error, reason} ->
        {:reply, %{"error" => reason, "revision" => revision}, socket}
    end
  end

  # The Export menu: the file is written in a task, and goes to the
  # browser when it is done. How far it got goes to the browser too, when
  # the LiveView has the Masu.Live hook to hear it.
  def handle_event("masu:export", %{"format" => format}, socket) when format in ["csv", "xlsx"] do
    format = String.to_existing_atom(format)

    if socket.assigns.download || format not in export_formats(socket.assigns) do
      {:reply, %{"error" => "busy"}, socket}
    else
      export = export_of(socket.assigns)
      lv = self()
      grid = socket.assigns.id
      hook? = Process.get(Masu.Live) != nil
      {_type, ext} = Masu.Export.type(format)

      path =
        Path.join(System.tmp_dir!(), "masu-export-#{System.unique_integer([:positive])}.#{ext}")

      progress =
        if hook?, do: [progress: &send(lv, {Masu.Live.Export, grid, &1, &2})], else: []

      socket =
        socket
        |> assign(download: %{format: format, path: path, offset: 0, ready: false})
        |> start_async(:masu_export, fn ->
          :ok = Masu.Export.write(export, format, path, progress)
          path
        end)

      {:reply, %{}, socket}
    end
  end

  # Rows selected (`selectable`): some rows by their ids (`on` or off), or
  # every row of the query (`all`), or none. A selection of every row is
  # of the query as it is when it is read (Masu.Live.selected/1), less the
  # rows taken out of it.
  def handle_event("masu:select", params, socket) when is_map(params) do
    %{selection: selection} = socket.assigns

    selection = change_selection(selection, params)

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
    # A tree's rows in a filter are open unless closed; groups are closed
    # unless opened.
    filtered? = (query.filters != [] or query.search != nil) and not Group.id?(id)

    query =
      cond do
        filtered? and open ->
          %{query | collapsed: Enum.reduce(ids, query.collapsed, &MapSet.delete(&2, &1))}

        filtered? ->
          %{query | collapsed: Enum.reduce(ids, query.collapsed, &MapSet.put(&2, &1))}

        open ->
          %{query | expanded: Enum.reduce(ids, query.expanded, &MapSet.put(&2, &1))}

        true ->
          %{query | expanded: Enum.reduce(ids, query.expanded, &MapSet.delete(&2, &1))}
      end

    reprepare(socket, query, params["from"])
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

    reply =
      if moved?,
        do: block(socket, from, @first_block),
        else: %{"revision" => socket.assigns.revision}

    {:reply, reply, socket}
  end

  # The views menu, and Masu.Test: a saved view, the grid's own, or one of
  # params; saving and deleting a named view.
  def handle_event("masu:view", %{"action" => "apply", "id" => id}, socket) do
    case Enum.find(socket.assigns.saved_views, &(&1.id == id)) do
      nil -> {:reply, %{"error" => "no such view"}, socket}
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

    case String.trim(name) do
      "" ->
        {:reply, %{"error" => "A view needs a name."}, socket}

      _name when is_nil(views) or is_nil(user) ->
        {:reply, %{"error" => "This grid does not keep views."}, socket}

      name ->
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

  @impl true
  def handle_async(:masu_export, {:ok, _path}, socket) do
    send_update(__MODULE__, id: socket.assigns.id, masu_download: true)
    {:noreply, update_in_download(socket, &%{&1 | ready: true})}
  end

  def handle_async(:masu_export, {:exit, reason}, socket) do
    File.rm(socket.assigns.download.path)

    {:noreply,
     socket
     |> assign(download: nil)
     |> push_event("masu:export", %{"id" => socket.assigns.id, "error" => inspect(reason)})}
  end

  defp update_in_download(socket, fun),
    do: assign(socket, download: fun.(socket.assigns.download))

  @chunk 512 * 1024

  defp download(%{assigns: %{download: %{ready: true} = d, id: id}} = socket) do
    # A part from the offset; no file stays open between the parts.
    size = File.stat!(d.path).size

    part =
      case File.open(d.path, [:read, :binary], &:file.pread(&1, d.offset, @chunk)) do
        {:ok, {:ok, part}} -> part
        {:ok, :eof} -> ""
      end

    last? = d.offset + byte_size(part) >= size
    {type, ext} = Masu.Export.type(d.format)
    name = "#{id}-#{Date.utc_today()}.#{ext}"

    socket =
      push_event(socket, "masu:download", %{
        "id" => id,
        "name" => name,
        "type" => type,
        "data" => Base.encode64(part),
        "last" => last?
      })

    if last? do
      File.rm(d.path)
      assign(socket, download: nil)
    else
      send_update(__MODULE__, id: id, masu_download: true)
      update_in_download(socket, &%{&1 | offset: d.offset + byte_size(part)})
    end
  end

  defp download(socket), do: socket

  # How many rows are selected, and whether they are every row of the query.
  defp change_selection(_selection, %{"all" => all}) when is_boolean(all),
    do: %{all: all, ids: MapSet.new(), except: MapSet.new()}

  defp change_selection(selection, %{"ids" => ids, "on" => on})
       when is_list(ids) and is_boolean(on) do
    ids = Enum.take(ids, 10_000)

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

  defp change_selection(selection, _params), do: selection

  defp selection_summary(%{selection: %{all: true, except: except}, total: total}),
    do: %{all: true, count: max(total - MapSet.size(except), 0)}

  defp selection_summary(%{selection: %{ids: ids}}), do: %{all: false, count: MapSet.size(ids)}

  defp selection_config(%{selectable: false}), do: nil

  defp selection_config(%{selection: selection} = assigns) do
    %{
      "all" => selection.all,
      "ids" => MapSet.to_list(selection.ids),
      "except" => MapSet.to_list(selection.except),
      "count" => selection_summary(assigns).count
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
        total: Source.count(source),
        revision: revision + 1,
        initial: nil,
        changed: []
      )
      |> refresh_details()

    from = if is_integer(from), do: max(from, 0), else: 0
    {:reply, block(socket, from, @first_block), socket}
  end

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

  defp share_view(%{assigns: %{presence: presence, tracked: topic} = assigns} = socket)
       when presence != nil and is_binary(topic) do
    case shared_view(assigns) do
      nil -> :ok
      view -> :ok = Masu.Presence.update(presence, topic, assigns.user, %{view: view})
    end

    socket
  end

  defp share_view(socket), do: socket

  defp block(socket, from, count) do
    %{source: source, total: total, revision: revision} = socket.assigns

    rows =
      cond do
        count == 0 -> []
        nodes = Source.nodes(source, from, count) -> encode_rows(nodes, socket.assigns)
        true -> source |> Source.rows(from, count) |> encode_rows(socket.assigns)
      end

    %{"from" => from, "rows" => rows, "total" => total, "revision" => revision}
  end

  # A row as the browser gets it: its id, its cells, then its read-only
  # cells (`locks?/1`), then its place in the tree (Masu.Tree).
  defp encode_rows(rows, assigns) do
    row_id = row_id(assigns)
    locks? = locks?(assigns)

    Enum.map(rows, fn
      # A group's row: its totals in their columns, read-only, then its
      # place and [key, value, count] (Masu.Group).
      {%Group{} = group, info} ->
        cells =
          [Group.id(group) | Enum.map(assigns.columns, &Value.to_wire(group.aggregates[&1.key]))]

        cells = if locks?, do: cells ++ [true], else: cells
        cells ++ [Tree.to_wire(info), [group.key, Value.to_wire(group.value), group.count]]

      row_or_node ->
        {row, info} =
          case row_or_node do
            {row, %{level: _} = info} -> {row, info}
            row -> {row, nil}
          end

        cells = [Value.to_wire(row_id.(row)) | cells(assigns.columns, row)]
        cells = if locks?, do: cells ++ [locks(assigns, row)], else: cells
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
        aria-rowcount={@total + 1}
        aria-colcount={length(@columns)}
        aria-multiselectable="true"
        style={"--masu-row-height: #{@row_height}px; height: #{@height}"}
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
      <div id={"#{@id}-status"} class="masu-status" role="status" aria-live="polite" phx-update="ignore">
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
      "catalog" => Enum.map(Layout.all(assigns.layout, assigns.all_columns), &catalog_entry/1),
      "columnsMenu" => assigns.columns_menu,
      "view" => assigns.view_params,
      "views" => views_config(assigns),
      "notice" => assigns.notice,
      "tree" => assigns.tree != nil or assigns.query.groups != [],
      "totals" => totals(assigns),
      "groupable" => assigns.tree == nil,
      "export" => Enum.map(export_formats(assigns), &Atom.to_string/1),
      "selection" => selection_config(assigns),
      "detail" => assigns.detail != [],
      "details" => for({id, _row, index} <- assigns.detail_rows, do: [id, index]),
      "initial" => assigns.initial && %{"from" => 0, "rows" => encode_initial(assigns)}
    })
  end

  defp encode_initial(%{initial_nodes: nil} = assigns), do: encode_rows(assigns.initial, assigns)

  defp encode_initial(assigns),
    do: assigns.initial |> Enum.zip(assigns.initial_nodes) |> encode_rows(assigns)

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
      "html" => column.slot != nil,
      "pinned" => column.pinned && Atom.to_string(column.pinned),
      "aggregate" => aggregate_name(column.aggregate)
    }
  end

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

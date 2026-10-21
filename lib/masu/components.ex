defmodule Masu.Components do
  @moduledoc """
  The grid component.

      import Masu.Components

      <.data_grid id="users" rows={@users} label="Users">
        <:col field={:name} />
        <:col field={:email} />
        <:col field={:inserted_at} type={:datetime} label="Joined" />
      </.data_grid>

  `data_grid/1` goes in a LiveView. It needs the `Masu` hook in the
  LiveSocket and the Masu CSS (see the README). The rows come from a
  list (`rows`), or from an Ecto query or schema and a repo (`source` and
  `repo`), which then sorts, filters and counts in the database; see the
  [Sources](sources.md) guide.
  """

  use Phoenix.Component

  @doc """
  Renders a data grid.

  The browser draws only the rows on the screen, and asks the grid for
  the others as the person scrolls. A click on a column's header sorts by
  it (with Shift, by it too); the edge of a header resizes its column,
  and a double click there fits the column to its content. The arrow keys
  move between the cells, Shift with them selects a range, and ⌘C (Ctrl+C)
  copies the range as text that a spreadsheet pastes.

  ## Columns

  Each `:col` is a column (see `Masu.Column`):

    * `field` - the key of the row's value (a map key or a struct field);
    * `value` - a function of the row that computes the value instead;
      it needs a `key`, and does not sort or filter with an Ecto source;
    * `key` - the name of the column in `Masu.Test` and in filters; the
      field as a string unless given;
    * `label` - the header; the field in words unless given;
    * `type` - `:text` (the default), `:enum`, `:integer`, `:number`,
      `:decimal`, `:date`, `:datetime`, `:time` or `:boolean`;
    * `width` and `min_width` - in pixels;
    * `align` - `:start`, `:center` or `:end` (numbers are at the end);
    * `sortable`, `filterable` and `searchable` - `false` to turn off,
      `searchable` is on for text and enums;
    * `editable` - in a grid that edits: `false` for a read-only column, or
      a function of the row that says whether its cell edits;
    * `values` - the values of an `:enum` column, which its editor offers;
    * `decimals` - the digits after the point of a `:decimal` or `:number`
      column, whatever the value has;
    * `filters` - the `Masu.Filter` operators the column offers, of its
      type: those the app runs, in a controlled grid (`on_query`).
    * `editor` - an editor of your own for its cells: a function component
      of a form field (a Koyomi picker, a Kotoba editor, any HEEx), or the
      name of an editor of the browser's; see the Editors of your own
      guide.

  A `:col` with content renders each cell, with the row as `:let`:

      <:col :let={user} field={:name}>
        <.link navigate={~p"/users/\#{user}"}>{user.name}</.link>
      </:col>

  ## Writes and actions

  A grid with a `changeset` edits its cells, and with `struct` and
  `deletable` adds and deletes rows, its own way; `on_update`,
  `on_create`, `on_delete` and `on_restore` write them your way, each a
  function of a `Masu.Write`; see the [Editing](editing.md) guide.
  `history` keeps who changed each cell, when, and from what, and brings
  a value back; see `Masu.History` and the [History](history.md) guide.
  `:action` acts on the rows selected, and `:row_action` on a row; see
  `Masu.Action` and the [Actions](actions.md) guide. `scope` is in every
  write and every action.

  ## Menus

  `cell_menu` gives each cell a menu (a right click, or the context-menu
  key or Shift+F10 on the active cell): copy, filter by the cell's value,
  sort. `:header_action` and `:cell_action` add items of your own to the
  header menus and to the menu of the cells; see `Masu.Action` and the
  [Menus of your own](menus.md) guide.
  """
  attr :id, :string, required: true, doc: "the id of the grid"

  attr :rows, :list,
    default: nil,
    doc:
      "the rows: maps or structs, or lists of values (see `columns`), up to about 10,000; past that, an Ecto `source` (see the Sources guide)"

  attr :columns, :list,
    default: nil,
    doc:
      "for a grid with no `:col` slots: its columns, each a key, or a keyword list or map of a `:col`'s attributes; without a `field`, a column reads the row at its place (rows as lists), and without a `type`, it takes the type of its values (`:auto`); see the Columns guide"

  attr :source, :any,
    default: nil,
    doc: "an Ecto query or schema (with `repo`), or `{module, opts}` of a `Masu.Source`"

  attr :repo, :atom, default: nil, doc: "the repo of an Ecto source"
  attr :repo_opts, :list, default: [], doc: "options for each call to the repo"

  attr :read, :any,
    default: nil,
    doc:
      "an Ecto source's read of a block of rows, your own: a function of the query (with the grid's filters, search and order) and `%{offset:, limit:, order:, after:}`, which gives the rows; see the Sources guide"

  attr :changeset, :any,
    default: nil,
    doc:
      "a function of a row and params that gives a changeset: the person edits the cells, which the grid saves its own way (`Masu.Write.save/1`), see the Editing guide"

  attr :struct, :any,
    default: nil,
    doc:
      "with `changeset`: the struct of a new row (or a function that gives it), which the changeset casts and the repo inserts; the person adds rows"

  attr :create_with, :any,
    default: nil,
    doc:
      "fields every new row gets, as a map or keyword list (`%{account_id: @current_scope.account.id}`): put on `struct` before the changeset and again after it, so params cannot change them; the person neither sets nor edits a cell of these fields"

  attr :on_update, :any,
    default: nil,
    doc:
      "a function of a `Masu.Write` of edited cells, which saves them and gives the write back with their results; the person edits the cells, see `Masu.Write`"

  attr :on_create, :any,
    default: nil,
    doc: "a function of a `Masu.Write` of new rows, as `on_update`; the person adds rows"

  attr :on_delete, :any,
    default: nil,
    doc: "a function of a `Masu.Write` of rows to delete, as `on_update`; the person deletes rows"

  attr :on_restore, :any,
    default: nil,
    doc:
      "a function of a `Masu.Write` of deleted rows to bring back (an undo), as `on_update`; a grid that deletes its own way brings them back its own way"

  attr :deletable, :any,
    default: nil,
    doc:
      "`true` to delete rows (the grid's own way: with the repo of an Ecto source, or from a list; or with `on_delete`), `false` never, or a function of a row that says whether it deletes"

  attr :row_editable, :any,
    default: nil,
    doc: "a function of a row: `false` makes every cell of the row read-only"

  attr :history, :atom,
    default: nil,
    doc:
      "a `Masu.History` store: the grid records who changed each cell, when, from what to what, and a person sees a cell's history and brings a value back; `user` says who"

  attr :scope, :any,
    default: nil,
    doc:
      "what your app knows of the person (`@current_scope`): every `Masu.Write` and every action's context has it"

  attr :live, :any,
    default: nil,
    doc:
      "`{pubsub, topic}`: shows the rows that change on the topic as they change, see `Masu.Live`"

  attr :presence, :atom,
    default: nil,
    doc:
      "your app's `Phoenix.Presence` module: shows the other people who have the grid open, see `Masu.Presence`"

  attr :issho, :any,
    default: nil,
    doc:
      "the grid's people in an Issho room, instead of `presence`: `[instance: MyApp.Issho, room: \"notebook:42\"]`, and `actor` (the person as the room knows them; `user` unless given), `can`, `claims` and `on_behalf_of`; agents in the room are among them; see the Collaboration guide"

  attr :people, :boolean,
    default: true,
    doc:
      "with `presence` or `issho`: `false` hides the avatars above the grid (a page that lists its people itself); the cells still show where each person is"

  attr :user, :map,
    default: nil,
    doc:
      "with `presence` or `issho`: this person, `%{id: ..., name: ..., color: ..., avatar: ...}`"

  attr :url, :boolean,
    default: false,
    doc:
      "when `true`, the person's view (order, filters, search, columns) goes into the URL's params, under the grid's id, and a link opens it; see `Masu.View`"

  attr :views, :atom,
    default: nil,
    doc:
      "a `Masu.Views` store: the grid keeps each person's last view, and a views menu saves named views; needs `user`"

  attr :views_key, :string,
    default: nil,
    doc: "with `views`: the name of the grid in the store; its id unless given"

  attr :views_scope, :any,
    default: nil,
    doc:
      "with `views`: whose views these are, such as the account's id; the store keeps each scope's views apart, so a view shared in one is not offered in another"

  attr :columns_menu, :boolean,
    default: false,
    doc: "when `true`, a columns menu to show, hide, pin and move columns"

  attr :share_view, :boolean,
    default: true,
    doc:
      "with `presence`: whether the person's order, filters and search go to the others, who see them when they follow the person"

  attr :selectable, :boolean,
    default: false,
    doc:
      "rows with a box to select them, and every row of the query at once; see `Masu.Live.selected/1`"

  attr :on_select, :any,
    default: nil,
    doc: "a function called with `%{count: n, all: boolean}` when the selection changes"

  attr :export, :any,
    default: false,
    doc:
      "an Export menu: `true` for CSV and XLSX, or a list of `:csv` and `:xlsx`; `false` (the default) has none, and the server exports nothing; see `Masu.Export`"

  attr :cell_menu, :any,
    default: false,
    doc:
      "a menu on each cell (a right click, or the context-menu key or Shift+F10 on the active cell): `true` for its built-in items, or a list of `:copy`, `:filter` and `:sort`; `false` (the default) has only the `:cell_action` items, if any; see `Masu.Action`"

  attr :group_by, :any,
    default: [],
    doc:
      "the keys of the columns the rows start grouped by, the first the outermost; see `Masu.Group`"

  attr :tree, :any,
    default: nil,
    doc:
      "rows in a tree: the field of a row that holds its parent's id (or a function of the row); see `Masu.Tree`"

  attr :expanded, :any,
    default: [],
    doc:
      "the rows that start open: with `tree`, the ids of the rows; with groups, `:all` for every group at every level, or the keys of the columns whose groups start open (`[:status]`); see `Masu.Group`"

  attr :count, :atom,
    default: :exact,
    values: [:exact, :deferred, :none],
    doc:
      "how the grid counts its rows: `:exact` with the query, `:deferred` after the first rows (in a task), `:none` only when the person goes to the end; see the Export, selection and large tables guide"

  attr :count_limit, :integer,
    default: nil,
    doc:
      "the most rows an Ecto source counts: past it, the grid says it has at least that many (\"10,000+\"), and counts them all when the person goes to the end; see the Export, selection and large tables guide"

  attr :paging, :atom,
    default: :scroll,
    values: [:scroll, :pages],
    doc:
      "`:pages` shows a page of rows at a time, with a pager below the grid, and the page in the view"

  attr :page_size, :integer,
    default: 50,
    doc:
      "with `paging={:pages}`: the rows of a page, read from the source at once (at most `max_block`)"

  attr :block_size, :integer,
    default: 100,
    doc:
      "the rows the grid reads from its source at once as the person scrolls (at most `max_block`)"

  attr :max_block, :integer,
    default: 500,
    doc:
      "the most rows of one read from the source: higher for a source where a read is costly and rows are small; see the Export, selection and large tables guide"

  attr :load, :atom,
    default: :inline,
    values: [:inline, :async],
    doc:
      "how the grid reads its source: `:inline` (the default) in the event, `:async` in a task, for a slow source: the LiveView answers meanwhile, the grid says it runs, with Stop; see the Sources guide"

  attr :timeout, :integer,
    default: nil,
    doc:
      "with `load={:async}`: the milliseconds a read may take, then it stops and the grid says so"

  attr :on_query, :any,
    default: nil,
    doc:
      "a controlled grid: the LiveView runs the query. The grid shows `rows` as they are, and calls this function with `%{query: %Masu.Query{}, page: n, offset: n, limit: n}` when the person sorts, filters, searches or goes to a page; see the Sources guide"

  attr :total, :integer,
    default: nil,
    doc: "with `on_query`: how many rows the LiveView's query has (its rows are a page of them)"

  attr :loading, :boolean,
    default: false,
    doc:
      "with `on_query`: the LiveView runs its query; the grid says so, and keeps its rows until the new ones come"

  attr :multi_sort, :boolean,
    default: true,
    doc: "`false` sorts by one column at a time: Shift adds none"

  attr :row_id, :any,
    default: nil,
    doc:
      "a function that gives a row's id; the `id` of the row unless given, or its place in the query for a row without one in a grid that needs no ids. `:position`: the place in the query, always, for a read-only grid of rows with no id; see the Sources guide"

  attr :sort, :list,
    default: [],
    doc: "the first order: keys, `{key, :asc | :desc}` or `Masu.Sort` structs"

  attr :filters, :list,
    default: [],
    doc: "the first filters: `{key, op, value}` or `Masu.Filter` structs"

  attr :searchable, :boolean, default: false, doc: "when `true`, a search box above the grid"
  attr :label, :string, default: nil, doc: "the name of the grid for a screen reader"
  attr :label_id, :string, default: nil, doc: "the id of an element that names the grid"

  attr :density, :atom,
    default: :normal,
    values: [:compact, :normal, :comfortable],
    doc:
      "the room around a cell's text: rows of 28, 36 or 48 pixels and their padding, unless `row_height` is given"

  attr :row_height, :integer,
    default: nil,
    doc: "the height of a row, in pixels; of the `density` unless given"

  attr :height, :string,
    default: "32rem",
    doc:
      "the height of the whole grid, as CSS (`100%` fills its container); the rows take what its toolbar leaves"

  attr :locale, :string,
    default: nil,
    doc: "the locale that formats numbers and dates; the browser's unless given"

  attr :messages, :map,
    default: %{},
    doc:
      "words that replace the built-in ones, by key (`search`, `empty`, `rows`...): `Masu.Messages` has every key, for a grid in another language"

  attr :class, :any, default: nil, doc: "classes for the grid element"
  attr :rest, :global, doc: "attributes for the grid element"

  slot :col, doc: "a column; without any, the columns are `columns`, or the source's" do
    attr :field, :any
    attr :value, :any
    attr :key, :string
    attr :label, :string
    attr :type, :atom
    attr :width, :integer
    attr :min_width, :integer
    attr :align, :atom
    attr :sortable, :boolean
    attr :filterable, :boolean
    attr :searchable, :boolean
    attr :editable, :any
    attr :values, :list
    attr :decimals, :integer
    attr :raw, :boolean
    attr :hidden, :boolean
    attr :pinned, :atom
    attr :aggregate, :any
    attr :filters, :list
    attr :editor, :any
  end

  slot :header_action,
    doc:
      "an item of each column's header menu: a function, an event to the LiveView, a JS command, or a panel of its content; see `Masu.Action`" do
    attr :label, :string, required: true
    attr :on_action, :any
    attr :event, :string
    attr :js, :any
    attr :columns, :list
    attr :types, :list
    attr :show, :any
  end

  slot :cell_action,
    doc: "an item of the menu of a cell, as `:header_action`; see `Masu.Action`" do
    attr :label, :string, required: true
    attr :on_action, :any
    attr :event, :string
    attr :js, :any
    attr :columns, :list
    attr :types, :list
    attr :show, :any
  end

  slot :action,
    doc:
      "an action on the rows selected, a button of the bar above the grid while rows are selected; needs `selectable`; see `Masu.Action`" do
    attr :label, :string, required: true
    attr :on_action, :any
    attr :event, :string
    attr :confirm, :string
    attr :danger, :boolean
    attr :keep_selection, :boolean
  end

  slot :row_action,
    doc:
      "an action on a row, in the menu at the end of each row and in the menu of its cells: a function, an event, or a link (`navigate`, `patch`); see `Masu.Action`" do
    attr :label, :string, required: true
    attr :on_action, :any
    attr :event, :string
    attr :navigate, :any
    attr :patch, :any
    attr :show, :any
    attr :disabled, :any
    attr :confirm, :string
    attr :danger, :boolean
  end

  slot :empty, doc: "what the grid shows when it has no rows"

  slot :detail,
    doc:
      "what a row shows when it opens, under it: any HEEx, another `data_grid` too; it gets the row"

  slot :person,
    doc:
      "draws a person who has the grid open (`:let`), see `Masu.Presence`; initials in their color unless given"

  def data_grid(assigns) do
    if is_nil(assigns.rows) and is_nil(assigns.source) do
      raise ArgumentError, "<.data_grid id=#{inspect(assigns.id)}> needs rows or a source"
    end

    check_blocks!(assigns)
    check_row_id!(assigns)
    check_controlled!(assigns)

    check_declared!(assigns)

    check_people!(assigns)

    ~H"""
    <.live_component
      module={Masu.Grid}
      id={@id}
      input={if is_nil(@rows), do: @source, else: @rows}
      column_specs={@columns}
      repo={@repo}
      repo_opts={@repo_opts}
      source_read={@read}
      count_limit={@count_limit}
      live={@live}
      changeset={@changeset}
      struct={@struct}
      create_with={create_with!(@id, @create_with)}
      on_update={@on_update}
      on_create={@on_create}
      on_delete={@on_delete}
      on_restore={@on_restore}
      deletable={@deletable}
      row_editable={@row_editable}
      scope={@scope}
      history={@history}
      presence={@presence}
      issho_config={@issho}
      show_people={@people}
      user={@user}
      share_view={@share_view}
      tree={@tree}
      group_by={@group_by}
      export={@export}
      load={@load}
      timeout={@timeout}
      on_query={@on_query}
      given_total={@total}
      given_loading={@loading}
      multi_sort={@multi_sort}
      cell_menu={cell_menu!(@id, @cell_menu)}
      header_action={@header_action}
      cell_action={@cell_action}
      action={@action}
      row_action={@row_action}
      selectable={@selectable}
      on_select={@on_select}
      expanded={expanded!(@id, @tree, @expanded)}
      detail={@detail}
      url={@url}
      views={@views}
      views_key={@views_key}
      views_scope={@views_scope}
      columns_menu={@columns_menu}
      person={@person}
      row_id={@row_id}
      count={@count}
      paging={@paging}
      page_size={@page_size}
      block_size={@block_size}
      max_block={@max_block}
      sort={@sort}
      filters={@filters}
      searchable={@searchable}
      label={@label}
      label_id={@label_id}
      row_height={@row_height || density_height(@density)}
      density={@density}
      height={@height}
      locale={@locale}
      messages={@messages}
      class={@class}
      rest={@rest}
      col={@col}
      empty={@empty}
    />
    """
  end

  # A block, and a page, are one read of the source: no larger than the
  # most rows of a read.
  # Views and people need to know who the person is.
  defp check_people!(assigns) do
    if assigns.views && is_nil(assigns.user) do
      raise ArgumentError, "<.data_grid id=#{inspect(assigns.id)}> with views needs user"
    end

    if assigns.issho && is_nil(assigns.user) do
      raise ArgumentError, "<.data_grid id=#{inspect(assigns.id)}> with issho needs user"
    end

    if assigns.presence && (is_nil(assigns.user) or is_nil(assigns.live)) do
      raise ArgumentError,
            "<.data_grid id=#{inspect(assigns.id)}> with presence needs live and user"
    end
  end

  defp check_blocks!(%{id: id, block_size: block, max_block: max} = assigns) do
    unless is_integer(max) and max > 0 do
      raise ArgumentError, "<.data_grid id=#{inspect(id)}> max_block must be a positive integer"
    end

    unless is_integer(block) and block > 0 and block <= max do
      raise ArgumentError,
            "<.data_grid id=#{inspect(id)}> block_size is #{inspect(block)}: it must be from 1 to max_block (#{max})"
    end

    if assigns.paging == :pages and
         not (is_integer(assigns.page_size) and assigns.page_size in 1..max) do
      raise ArgumentError,
            "<.data_grid id=#{inspect(id)}> page_size is #{inspect(assigns.page_size)}: a page is one read, " <>
              "from 1 to max_block (#{max}); raise max_block for larger pages"
    end
  end

  # A row's place is not its id from one query to the next: what needs
  # an id that stays does not take it.
  defp check_row_id!(%{row_id: :position, id: id} = assigns) do
    case Masu.Grid.stable_id_features(assigns) do
      [] ->
        :ok

      features ->
        raise ArgumentError,
              "<.data_grid id=#{inspect(id)}> has row_id={:position}, and #{Enum.join(features, ", ")}, " <>
                "which needs a row's id to stay the same from one query to the next: give `row_id` a function " <>
                "of a row that gives its id"
    end
  end

  defp check_row_id!(%{row_id: row_id, id: id})
       when not is_nil(row_id) and not is_function(row_id, 1),
       do:
         raise(
           ArgumentError,
           "<.data_grid id=#{inspect(id)}> row_id is a function of a row, or :position"
         )

  defp check_row_id!(_assigns), do: :ok

  defp create_with!(_id, nil), do: %{}
  defp create_with!(_id, fields) when is_map(fields), do: fields

  defp create_with!(id, fields) do
    if Keyword.keyword?(fields) do
      Map.new(fields)
    else
      raise ArgumentError,
            "<.data_grid id=#{inspect(id)}> create_with is a map or a keyword list of fields"
    end
  end

  # A controlled grid's rows are the LiveView's page: what reads the
  # source's rows beyond them, or writes them, is not for it.
  # What a grid of Masu 0.1 took, and what takes its place.
  @renamed [
    update: "on_update, a function of a Masu.Write",
    create: "on_create, a function of a Masu.Write",
    delete: "on_delete, a function of a Masu.Write",
    restore: "on_restore, a function of a Masu.Write",
    on_save: "gone: save in on_update (Masu.Write.save/1), and do more there"
  ]

  defp check_declared!(assigns) do
    if assigns.action != [] and not assigns.selectable do
      raise ArgumentError,
            "<.data_grid id=#{inspect(assigns.id)}> has :action, which acts on the rows selected: it needs selectable"
    end

    for {old, new} <- @renamed, Map.has_key?(assigns, old) do
      raise ArgumentError, "<.data_grid id=#{inspect(assigns.id)}> has #{old}: it is #{new} now"
    end

    :ok
  end

  @not_controlled [
    changeset: "changeset",
    on_update: "on_update",
    on_create: "on_create",
    struct: "struct",
    on_delete: "on_delete",
    deletable: "deletable",
    selectable: "selectable",
    export: "export",
    live: "live",
    tree: "tree",
    read: "read"
  ]

  defp check_controlled!(%{on_query: nil}), do: :ok

  defp check_controlled!(%{on_query: on_query, id: id} = assigns) do
    unless is_function(on_query, 1) do
      raise ArgumentError, "<.data_grid id=#{inspect(id)}> on_query is a function of one argument"
    end

    on =
      for {key, name} <- @not_controlled, assigns[key] not in [nil, false, []], do: name

    on = if assigns.group_by != [], do: on ++ ["group_by"], else: on

    if on != [] do
      raise ArgumentError,
            "<.data_grid id=#{inspect(id)}> has on_query (the LiveView runs its query) and #{Enum.join(on, ", ")}, " <>
              "which reads or writes the rows beyond those the LiveView gives: a controlled grid does not take them"
    end
  end

  @cell_menu [:copy, :filter, :sort]

  defp cell_menu!(_id, true), do: @cell_menu
  defp cell_menu!(_id, false), do: []
  defp cell_menu!(_id, nil), do: []

  defp cell_menu!(id, items) when is_list(items) do
    case items -- @cell_menu do
      [] ->
        Enum.filter(@cell_menu, &(&1 in items))

      unknown ->
        raise ArgumentError,
              "<.data_grid id=#{inspect(id)}> cell_menu has #{inspect(unknown)}: its items are #{inspect(@cell_menu)}"
    end
  end

  defp cell_menu!(id, other),
    do:
      raise(
        ArgumentError,
        "<.data_grid id=#{inspect(id)}> cell_menu is true, false or a list of #{inspect(@cell_menu)}, got: #{inspect(other)}"
      )

  defp expanded!(id, tree, :all) when tree != nil,
    do:
      raise(
        ArgumentError,
        "<.data_grid id=#{inspect(id)}> expanded={:all} is for groups: a tree's expanded is the ids of the rows that start open"
      )

  defp expanded!(_id, _tree, expanded) when expanded == :all or is_list(expanded), do: expanded
  defp expanded!(_id, _tree, nil), do: []

  defp expanded!(id, _tree, other),
    do:
      raise(
        ArgumentError,
        "<.data_grid id=#{inspect(id)}> expanded is a list, or :all for groups, got: #{inspect(other)}"
      )

  defp density_height(:compact), do: 28
  defp density_height(:comfortable), do: 48
  defp density_height(_normal), do: 36
end

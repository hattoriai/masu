defmodule Masu.Sheet do
  @moduledoc """
  A grid outside the LiveView: its rows, and its writes, for a job, a
  test, or an agent (`Masu.Issho`). The writes go the grid's way: its
  changeset or its `on_update`, its read-only rules, the compare of a
  cell someone changed meanwhile, its history, and its `live` topic, so
  the people who have the grid open see each change as it lands.

  Define a grid once, as the attributes of `Masu.Components.data_grid/1`,
  and use it in both places:

      defmodule MyApp.Grids do
        def tasks(scope) do
          [
            id: "tasks",
            source: MyApp.Tasks.query(scope),
            repo: MyApp.Repo,
            changeset: &MyApp.Tasks.Task.changeset/2,
            struct: %MyApp.Tasks.Task{},
            create_with: %{account_id: scope.account.id},
            deletable: true,
            history: MyApp.GridHistory,
            live: {MyApp.PubSub, "tasks:\#{scope.account.id}"},
            columns: [
              [field: :title],
              [field: :status, type: :enum],
              [field: :due, type: :date]
            ]
          ]
        end
      end

  ```heex
  <.data_grid {MyApp.Grids.tasks(@current_scope)} scope={@current_scope} user={@user} />
  ```

      sheet = Masu.Sheet.new(MyApp.Grids.tasks(scope))
      Masu.Sheet.rows(sheet, filters: [{"status", :eq, "open"}], limit: 20)
      Masu.Sheet.update(sheet, [%{"id" => 7, "key" => "status", "value" => "done"}],
        scope: scope, user: %{id: "agent:1", name: "Assistant"})

  The columns of a sheet are those of `columns`, or its source's: a
  `:col` slot is of the HEEx that renders the grid, and a sheet has
  none. A grid given `rows` (a list) is a sheet of that list, which its
  writes do not change.
  """

  alias Masu.{Column, Edit, Query, Source, Value}

  @enforce_keys [:id, :source, :columns, :attrs]
  defstruct [:id, :source, :columns, :attrs]

  @type t :: %__MODULE__{
          id: String.t(),
          source: Source.t(),
          columns: [Column.t()],
          attrs: map()
        }

  @type error :: [term()]

  # The attributes of a data_grid, by the names the grid's component
  # takes them, and their defaults.
  @defaults %{
    rows: nil,
    source: nil,
    columns: nil,
    repo: nil,
    repo_opts: [],
    read: nil,
    count_limit: nil,
    changeset: nil,
    struct: nil,
    create_with: nil,
    on_update: nil,
    on_create: nil,
    on_delete: nil,
    on_restore: nil,
    deletable: nil,
    row_editable: nil,
    history: nil,
    live: nil,
    row_id: nil,
    tree: nil,
    block_size: 100
  }

  @doc """
  A sheet of a grid's attributes (a keyword list or a map, as
  `data_grid/1` takes them). The attributes of the LiveView alone
  (`issho`, `views`, `url`...) are left out.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = Map.new(attrs)
    id = Map.get(attrs, :id) || raise ArgumentError, "Masu.Sheet.new/1 needs the grid's id"
    given = Map.merge(@defaults, Map.take(attrs, Map.keys(@defaults)))

    if given.row_id == :position,
      do: raise(ArgumentError, "the grid #{id} has row_id={:position}: a sheet needs row ids")

    input =
      given.rows || given.source || raise ArgumentError, "the grid #{id} needs rows or a source"

    assigns =
      Map.merge(given, %{
        id: to_string(id),
        input: input,
        column_specs: given.columns,
        source_read: given.read,
        on_query: nil,
        create_with: Map.new(given.create_with || %{})
      })

    {source, columns} = Masu.Grid.setup(assigns)
    %__MODULE__{id: assigns.id, source: source, columns: columns, attrs: assigns}
  end

  @doc "The columns of the sheet."
  @spec columns(t()) :: [Column.t()]
  def columns(%__MODULE__{columns: columns}), do: columns

  @doc """
  Rows of the sheet, in an order, filtered and searched as a person
  would (`Masu.Query.new/2`: `sort`, `filters`, `search`), from `offset`,
  at most `limit` (50 unless given, 500 at most): `{:ok, %{rows:, total:}}`,
  or what is wrong with the query. `total` is how many rows the query
  has, or `{:at_least, n}` for a count the source caps.
  """
  @spec rows(t(), keyword()) :: {:ok, %{rows: [term()], total: term()}} | {:error, String.t()}
  def rows(%__MODULE__{} = sheet, opts \\ []) do
    offset = max(Keyword.get(opts, :offset, 0), 0)
    limit = opts |> Keyword.get(:limit, 50) |> min(500) |> max(1)

    with {:ok, query} <- Query.new(Keyword.take(opts, [:sort, :filters, :search]), sheet.columns) do
      source = Source.prepare(sheet.source, query, sheet.columns)

      {:ok,
       %{
         rows: Source.rows(source, offset, limit),
         total:
           case Source.count(source) do
             :unknown -> nil
             count -> count
           end
       }}
    end
  end

  @doc "The rows of these ids that the sheet has (its source may show)."
  @spec fetch(t(), [term()]) :: [term()]
  def fetch(%__MODULE__{} = sheet, ids),
    do: Source.fetch(sheet.source, Enum.map(ids, &Value.to_wire/1), row_id(sheet))

  @doc "A row's id, as `update/3` and `delete/3` take it."
  @spec id(t(), term()) :: term()
  def id(%__MODULE__{} = sheet, row), do: Value.to_wire(row_id(sheet).(row))

  @doc """
  A row as a person reads it in the grid: each column's key and value,
  with the row's `"id"`.
  """
  @spec to_map(t(), term()) :: map()
  def to_map(%__MODULE__{} = sheet, row) do
    sheet.columns
    |> Map.new(&{&1.key, Column.wire(&1, row)})
    |> Map.put("id", id(sheet, row))
  end

  @doc """
  Edits cells, as a person types in them: each `%{"id" => id, "key" =>
  key, "value" => value}`, with `"before"`, the value seen, to refuse an
  edit of a cell someone changed since. Options: `scope` (in the
  `Masu.Write`), `user` (who, for the history and the people who see the
  rows change: `%{id:, name:}`), `by` (who, as the write's `by` says
  them; `user` unless given), and `origin` (`:edit`, `:paste`...).

  Gives the rows saved, and the errors, each `[id, key, message]` or,
  for a cell changed meanwhile, `[id, key, message, value]`.
  """
  @spec update(t(), [map()], keyword()) :: %{saved: [term()], errors: [error()], saving: [list()]}
  def update(%__MODULE__{} = sheet, edits, opts \\ []) when is_list(edits) do
    result =
      Edit.update(edits, assigns(sheet, opts), row_id(sheet), Keyword.get(opts, :origin, :edit))

    broadcast(sheet, result.saved, opts[:user])
    %{saved: result.saved, errors: result.errors, saving: result.pending}
  end

  @doc """
  New rows, each the values of its cells by key: for each, `{:ok, row}`
  or `{:error, errors}` (`[key, message]`, a key of nil for the row).
  Options as `update/3`.
  """
  @spec create(t(), [map()], keyword()) :: [{:ok, term()} | {:error, [list()]}]
  def create(%__MODULE__{} = sheet, drafts, opts \\ []) when is_list(drafts) do
    results =
      Edit.create(drafts, assigns(sheet, opts), row_id(sheet), Keyword.get(opts, :origin, :draft))

    broadcast(sheet, for({:ok, row} <- results, do: row), opts[:user])
    results
  end

  @doc """
  Deletes rows, by their ids: the rows deleted, and the errors, each
  `[id, message]`. Options as `update/3`.
  """
  @spec delete(t(), [term()], keyword()) :: %{deleted: [term()], errors: [list()]}
  def delete(%__MODULE__{} = sheet, ids, opts \\ []) when is_list(ids) do
    assigns = assigns(sheet, opts)

    if Edit.deletes?(assigns) do
      ids = Enum.map(ids, &Value.to_wire/1)
      result = Edit.delete(ids, assigns, row_id(sheet), Keyword.get(opts, :origin, :rows))

      with {pubsub, topic} <- sheet.attrs.live,
           do: Enum.each(result.deleted, &Masu.Live.broadcast_delete(pubsub, topic, &1))

      %{deleted: result.deleted, errors: result.errors}
    else
      %{deleted: [], errors: Enum.map(ids, &[&1, "This grid does not delete rows."])}
    end
  end

  @doc "Whether the sheet edits cells, adds rows, deletes rows."
  @spec can(t()) :: %{edit: boolean(), create: boolean(), delete: boolean()}
  def can(%__MODULE__{attrs: attrs, columns: columns}) do
    %{
      edit: Enum.any?(columns, & &1.editable),
      create: Enum.any?(columns, & &1.creatable),
      delete: Edit.deletes?(attrs)
    }
  end

  # The grid's assigns, as Masu.Edit takes them.
  defp assigns(sheet, opts) do
    Map.merge(sheet.attrs, %{
      source: sheet.source,
      all_columns: sheet.columns,
      columns: sheet.columns,
      scope: opts[:scope],
      user: opts[:user],
      by: opts[:by],
      issho_event: opts[:issho]
    })
  end

  defp row_id(%__MODULE__{attrs: %{row_id: fun}}) when is_function(fun, 1), do: fun
  defp row_id(_sheet), do: &default_row_id/1

  defp default_row_id(%{id: id}), do: id
  defp default_row_id(%{"id" => id}), do: id
  defp default_row_id(_row), do: nil

  # The people who have the grid open see the rows change, in the color
  # of who changed them.
  defp broadcast(%__MODULE__{attrs: %{live: {pubsub, topic}}}, rows, user) do
    by = Masu.Live.by(user)
    for row <- rows, do: Masu.Live.broadcast_upsert_from(self(), pubsub, topic, row, by)
    :ok
  end

  defp broadcast(_sheet, _rows, _user), do: :ok
end

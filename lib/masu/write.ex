defmodule Masu.Write do
  @moduledoc """
  A write of a grid's rows: cells edited, new rows, rows deleted or
  brought back. Every change a person makes to the rows goes through one,
  whoever saves it.

  The grid builds the write, and hands it to your function for its
  operation (`on_update`, `on_create`, `on_delete`, `on_restore` on
  `Masu.Components.data_grid/1`), which gives it back with a result for
  each change. Without one, the grid saves it its own way
  (`Masu.Write.save/1`: the repo of an Ecto source, or its copy of a
  list), with `changeset`.

      <.data_grid id="orders" source={Order} repo={Repo} scope={@current_scope}
        on_update={&OrdersGrid.update/1}>

      defmodule MyAppWeb.OrdersGrid do
        alias MyApp.Orders

        # A context function, row by row.
        def update(write) do
          Masu.Write.each(write, &Orders.update_order(write.scope, &1.row, &1.params))
        end
      end

  By the time your function gets it, the grid has done its part: each
  row is found again through the grid's own query (a person writes only
  the rows they may see), the cells that do not edit, or that the row's
  state makes read-only (`row_editable`, a column's `editable`), are
  refused, and so are the cells someone changed meanwhile (see
  "Two people, one cell" in the Editing guide). A change has only what
  is left.

  ## What a write has

    * `op` - `:update`, `:create`, `:delete` or `:restore`;
    * `changes` - the `Masu.Write.Change`s, one for each row;
    * `origin` - what the person did: `:edit` (typed in a cell),
      `:paste`, `:fill`, `:clear`, `:undo`, `:redo` (cells); `:draft` (a
      new row), `:paste` (rows of a paste); `:rows` (the rows of a
      range), `:selection` (the rows selected), `:redo` (a delete again);
      `:undo` (rows back); `:test` from `Masu.Test`;
    * `scope` - the grid's `scope`: the current user, their
      organization, as your app has it (`@current_scope`);
    * `grid` - the id of the grid;
    * `ref` - the write's reference, for `async/1` and `Masu.reply/2`.

  ## Results

  Each change gets one, from the function that writes it:

    * `each/2` - a function of each change, `{:ok, row}` or
      `{:error, reason}` (`:ok` for a delete);
    * `all/2` - one function of every change, for a transaction of the
      whole batch (`Ecto.Multi`): `{:ok, rows}`, in the order of the
      changes, or `{:error, reason}`, which refuses them all;
    * `ok/3` and `error/3` - a result for one change;
    * `save/1` - the grid's own way, for the changes without a result;
    * `async/1` - the changes without a result are saved later, by a job
      of yours: the grid shows them saving until `Masu.reply/2`.

  A reason is an `Ecto.Changeset` (its errors go on the cells of its
  fields), a message (on every cell of the row), or `[{key, message}]`
  of column keys. A change left without a result is a mistake, and the
  grid raises.

  The results compose. Your function may save the grid's way and do
  more, or save each row its own way and the rest the grid's:

      def update(write) do
        write
        |> Masu.Write.save()
        |> tap(&Audit.log(&1.scope, Masu.Write.saved(&1)))
      end

      def update(%Masu.Write{origin: :paste} = write) do
        Masu.Write.all(write, &Orders.update_many(write.scope, &1))
      end

      def update(write), do: Masu.Write.save(write)

  ## Later: a job

  A write that takes long (a paste of 5,000 cells into a system that
  takes its time, an import of new rows through a queue) can be saved by
  a job. `async/1` says that the changes without a result will be
  saved; `ref` reaches the grid from any process (an Oban job, on any
  node of the cluster):

      def update(write) do
        %{ref: write.ref, changes: Enum.map(write.changes, &Map.take(&1, [:id, :params]))}
        |> MyApp.Workers.SaveCells.new()
        |> Oban.insert!()

        Masu.Write.async(write)
      end

      # In the job:
      Masu.reply(ref, :ok)
      Masu.reply(ref, {:error, "The ledger is closed."})

  The cells show saving until the reply; then the grid reads its rows
  again, and an error refuses the changes, which show their old values.
  New rows and rows brought back need their ids at once: they cannot be
  saved later.
  """

  alias Masu.{Column, Source, Value}
  alias Masu.Source.Ecto, as: EctoSource

  defmodule Change do
    @moduledoc """
    A change of a row in a `Masu.Write`:

      * `index` - its place in the write;
      * `id` - the row's id (nil for a new row);
      * `row` - the row, as the grid's source reads it now (nil for a new
        row; for `:restore`, the row as it was deleted);
      * `params` - for `:update` and `:create`, the values by the
        columns' fields, as strings, as the browser sends them
        (`%{"total" => "11.50"}`), which a changeset casts as it does a
        form's; an empty value is nil;
      * `keys` - the keys of the columns the params are of;
      * `before` - for `:update`, the value of each cell that the person
        saw, by the column's key.
    """

    @type t :: %__MODULE__{
            index: non_neg_integer() | nil,
            id: term(),
            row: term(),
            params: %{String.t() => term()},
            keys: [String.t()],
            before: %{String.t() => term()}
          }

    defstruct [:index, :id, :row, params: %{}, keys: [], before: %{}]
  end

  @type op :: :update | :create | :delete | :restore
  @type reason :: Ecto.Changeset.t() | String.t() | [{String.t() | atom(), String.t()}]
  @type result :: {:ok, term()} | {:error, reason()} | :pending | saved_stale()

  # The grid's own update of a row whose other cells changed meanwhile:
  # saved, with those cells refused; or none saved.
  @typep saved_stale ::
           {:ok, term(), {:stale, term(), [String.t()]}}
           | {:error, {:stale, term(), [String.t()]}}

  @type t :: %__MODULE__{
          grid: String.t(),
          op: op(),
          origin: atom(),
          scope: term(),
          ref: String.t(),
          changes: [Change.t()],
          results: %{non_neg_integer() => result()},
          grid_config: map()
        }

  @enforce_keys [:grid, :op]
  defstruct [
    :grid,
    :op,
    :scope,
    :ref,
    origin: :edit,
    changes: [],
    results: %{},
    grid_config: %{}
  ]

  @doc """
  Gives each change without a result the result of `fun`: `{:ok, row}`,
  with the row as saved, or `{:error, reason}`. For `:delete`, `:ok` or
  `{:ok, _}` is the row deleted.
  """
  @spec each(t(), (Change.t() -> term())) :: t()
  def each(%__MODULE__{} = write, fun) when is_function(fun, 1) do
    Enum.reduce(open(write), write, fn change, write ->
      put(write, change, result!(write, fun.(change), change))
    end)
  end

  @doc """
  Gives the changes without a result one result, of `fun` of all of
  them: `{:ok, rows}`, the rows as saved in the order of the changes (or
  `:ok` for a delete), or `{:error, reason}`, which refuses every one
  (the whole batch, as a transaction does). `{:error, change, reason}`
  says which change it was: the others say that they were not saved.
  """
  @spec all(t(), ([Change.t()] -> term())) :: t()
  def all(%__MODULE__{} = write, fun) when is_function(fun, 1) do
    changes = open(write)

    case {changes, fun.(changes)} do
      {[], _result} ->
        write

      {_changes, :ok} when write.op == :delete ->
        Enum.reduce(changes, write, &put(&2, &1, {:ok, &1.row}))

      {_changes, {:ok, rows}} when is_list(rows) and length(rows) == length(changes) ->
        changes
        |> Enum.zip(rows)
        |> Enum.reduce(write, fn {c, row}, w -> put(w, c, {:ok, row}) end)

      {_changes, {:error, %Change{} = failed, reason}} ->
        Enum.reduce(changes, write, &put(&2, &1, blamed(&1, failed, reason)))

      {_changes, {:error, reason}} ->
        Enum.reduce(changes, write, &put(&2, &1, {:error, reason}))

      {_changes, other} ->
        raise ArgumentError,
              "Masu.Write.all/2 of the grid #{write.grid} got #{inspect(other)}, not {:ok, rows} " <>
                "(a row for each of the #{length(changes)} changes) or {:error, reason}"
    end
  end

  defp blamed(%Change{index: index}, %Change{index: index}, reason), do: {:error, reason}

  defp blamed(_change, _failed, _reason),
    do: {:error, "Not saved: another row of the batch has an error."}

  @doc "The result of one change: saved, as `row`."
  @spec ok(t(), Change.t(), term()) :: t()
  def ok(%__MODULE__{} = write, %Change{} = change, row \\ nil),
    do: put(write, change, {:ok, row || change.row})

  @doc "The result of one change: refused, for `reason`."
  @spec error(t(), Change.t(), reason()) :: t()
  def error(%__MODULE__{} = write, %Change{} = change, reason),
    do: put(write, change, {:error, reason})

  @doc """
  The changes without a result are saved later, by a process of yours,
  which says how it went with `Masu.reply(write.ref, result)`: `:ok`,
  `{:ok, message}` or `{:error, message}`. Not for `:create` and
  `:restore`, whose rows need their ids at once.
  """
  @spec async(t()) :: t()
  def async(%__MODULE__{op: op} = write) when op in [:create, :restore] do
    raise ArgumentError,
          "a #{op} of the grid #{write.grid} cannot be saved later: its rows need their ids at once"
  end

  def async(%__MODULE__{} = write),
    do: Enum.reduce(open(write), write, &put(&2, &1, :pending))

  @doc "The changes without a result yet."
  @spec open(t()) :: [Change.t()]
  def open(%__MODULE__{changes: changes, results: results}),
    do: Enum.reject(changes, &Map.has_key?(results, &1.index))

  @doc "The rows saved: as saved, in the order of their changes."
  @spec saved(t()) :: [term()]
  def saved(%__MODULE__{} = write) do
    for change <- write.changes, {:ok, row} <- [result(write, change)], do: row
  end

  @doc "The changes refused, with their reasons."
  @spec failed(t()) :: [{Change.t(), reason()}]
  def failed(%__MODULE__{} = write) do
    for change <- write.changes, {:error, reason} <- [result(write, change)], do: {change, reason}
  end

  @doc "The result of a change, or nil."
  @spec result(t(), Change.t()) :: result() | nil
  def result(%__MODULE__{results: results}, %Change{index: index}) do
    case Map.get(results, index) do
      {:ok, row, _refused} -> {:ok, row}
      result -> result
    end
  end

  defp put(write, change, result),
    do: %{write | results: Map.put(write.results, change.index, result)}

  defp result!(_write, {:ok, row}, _change), do: {:ok, row}
  defp result!(%{op: :delete}, :ok, change), do: {:ok, change.row}
  defp result!(_write, {:error, reason}, _change), do: {:error, reason}

  defp result!(write, other, _change) do
    raise ArgumentError,
          "Masu.Write.each/2 of the grid #{write.grid} got #{inspect(other)}, not {:ok, row} or {:error, reason}"
  end

  @doc """
  Saves the changes without a result the grid's own way:

    * `:update` - `row |> changeset.(params)`, then `Repo.update` for an
      Ecto source, each row read, compared again and saved in a
      transaction that locks it; for a list, the changeset applied;
    * `:create` - `changeset.(struct, params)`, inserted by the repo, or
      applied for a list;
    * `:delete` - `Repo.delete`, in a transaction that locks the row; a
      list's row taken out of its copy;
    * `:restore` - the row inserted again; a list's put back.

  An update and a new row need the grid's `changeset` (and `struct`).
  """
  @spec save(t()) :: t()
  def save(%__MODULE__{} = write) do
    Enum.reduce(open(write), write, fn change, write ->
      %{write | results: Map.put(write.results, change.index, save_one(write, change))}
    end)
  end

  defp save_one(%{op: :update, grid_config: config} = write, change) do
    changeset = config.changeset || missing(write, "changeset")

    case config.source do
      %Source{module: EctoSource, state: state} ->
        EctoSource.locked(state, change.id, &update_locked(&1, change, changeset, config))

      _source ->
        Ecto.Changeset.apply_action(changeset.(change.row, change.params), :update)
    end
  end

  defp save_one(%{op: :create, grid_config: config} = write, change) do
    changeset = config.changeset || missing(write, "changeset")
    struct = config.struct || missing(write, "struct")
    changeset = changeset.(new_struct(struct), change.params)

    case config.source do
      %Source{module: EctoSource} -> config.repo.insert(changeset, config.repo_opts)
      _source -> Ecto.Changeset.apply_action(changeset, :insert)
    end
  end

  defp save_one(%{op: :delete, grid_config: config}, change) do
    case config.source do
      %Source{module: EctoSource, state: state} ->
        EctoSource.locked(state, change.id, fn
          nil -> {:error, "Changed or deleted by someone else meanwhile."}
          row -> repo_delete(row, config)
        end)

      _source ->
        {:ok, change.row}
    end
  end

  defp save_one(%{op: :restore, grid_config: config}, change) do
    case config.source do
      %Source{module: EctoSource} -> repo_restore(change.row, config)
      _source -> {:ok, change.row}
    end
  end

  defp missing(write, attr) do
    raise ArgumentError,
          "Masu.Write.save/1 of a #{write.op} of the grid #{write.grid} needs the grid's #{attr}"
  end

  defp new_struct(fun) when is_function(fun, 0), do: fun.()
  defp new_struct(struct), do: struct

  # The row as it is now, locked: the cells someone changed since the
  # person saw them are refused, the others saved.
  defp update_locked(nil, _change, _changeset, _config),
    do: {:error, "This row is not in the grid."}

  defp update_locked(row, change, changeset, config) do
    stale = Enum.reject(change.keys, &current?(row, change, &1, config.columns))

    case change.keys -- stale do
      [] ->
        {:error, {:stale, row, stale}}

      keys ->
        params = Map.take(change.params, fields(keys, config.columns))

        case repo_update(changeset.(row, params), config) do
          {:ok, row} when stale == [] -> {:ok, row}
          {:ok, saved} -> {:ok, saved, {:stale, row, stale}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc false
  # Whether a cell still has the value the person saw. A change without
  # it (from Masu.Test, say) is not compared. The values compare by the
  # column's type: "120.50" is 120.5, a date is its day.
  @spec current?(term(), Change.t(), String.t(), [Column.t()]) :: boolean()
  def current?(row, %Change{before: before}, key, columns) do
    case Map.fetch(before, key) do
      :error ->
        true

      # An editor's form: a version of the value the person saw.
      {:ok, {:version, version}} ->
        Masu.Edit.version(Column.get(Column.find(columns, key), row)) == version

      {:ok, seen} ->
        column = Column.find(columns, key)
        now = Column.get(column, row)

        case Value.cast(column.type, seen) do
          {:ok, seen} -> same?(now, seen)
          :error -> Value.to_wire(now) == seen
        end
    end
  end

  defp same?(nil, nil), do: true
  defp same?(nil, _seen), do: false
  defp same?(_now, nil), do: false
  defp same?(now, seen), do: Value.compare(now, seen) == :eq

  @doc false
  # The fields of the params of columns, by their keys.
  @spec fields([String.t()], [Column.t()]) :: [String.t()]
  def fields(keys, columns), do: Enum.map(keys, &to_string(Column.find(columns, &1).field))

  # A schema with Ecto's optimistic_lock (a lock_version) refuses a row
  # that changed since it was read.
  defp repo_update(changeset, %{source: %Source{module: EctoSource}} = config) do
    config.repo.update(changeset, config.repo_opts)
  rescue
    error in [Ecto.StaleEntryError] ->
      _ = error
      {:error, "Changed by someone else meanwhile."}
  end

  defp repo_update(changeset, _config), do: Ecto.Changeset.apply_action(changeset, :update)

  defp repo_delete(row, config) do
    if is_struct(row) and function_exported?(row.__struct__, :__schema__, 1) do
      config.repo.delete(row, config.repo_opts)
    else
      {:error, "This row cannot be deleted: it is not a schema's struct."}
    end
  rescue
    error in [Ecto.StaleEntryError] ->
      _ = error
      {:error, "Changed or deleted by someone else meanwhile."}

    error in [Ecto.ConstraintError] ->
      _ = error
      {:error, "Other records refer to this row."}
  end

  defp repo_restore(row, config) do
    row |> Ecto.put_meta(state: :built) |> config.repo.insert(config.repo_opts)
  rescue
    error in [Ecto.ConstraintError] ->
      _ = error
      {:error, "The row could not be brought back."}
  end
end

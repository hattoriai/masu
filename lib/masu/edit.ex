defmodule Masu.Edit do
  @moduledoc false
  # A batch of edits from the browser: a cell typed in, a paste, a fill
  # down or an undo. Each edit is `%{"id" => id, "key" => key, "value" =>
  # value}`. The edits of a row are saved together, through the grid's
  # `update` function or its `changeset` (with the repo of an Ecto
  # source, or applied to a row of a list). A row is found among the rows
  # its source may show (`Masu.Source.fetch/3`), and only the editable
  # columns take a value.
  #
  # An edit may carry `"before"`, the value the person saw: when the
  # cell's value is no longer that one, someone changed it meanwhile, and
  # the edit is refused (optimistic concurrency, a compare-and-swap of the
  # cell). For an Ecto source, the row is read, compared and saved in one
  # transaction that locks it (`SELECT ... FOR UPDATE`, where the database
  # has it), so that two saves cannot both pass the comparison.
  #
  # Returns the rows saved, and the errors as `[id, key, message]`, or
  # `[id, key, message, value]` for a cell changed meanwhile, with its
  # value now.
  #
  # New rows (`create/2`) and deleted ones (`delete/3`, `restore/2`) go
  # through the grid's functions, or Ecto's.

  alias Masu.{Column, Source, Value}
  alias Masu.Source.Ecto, as: EctoSource

  @max_edits 5_000

  @type error :: [term()]

  @spec run([map()], map(), (term() -> term())) :: {[term()], [error()]}
  def run(edits, assigns, row_id) when is_list(edits) do
    {edits, refused} =
      edits
      |> Enum.take(@max_edits)
      |> Enum.split_with(&editable?(&1, assigns.columns))

    errors = Enum.map(refused, &[&1["id"], &1["key"], "This cell cannot be edited."])
    by_id = Enum.group_by(edits, & &1["id"])
    ids = by_id |> Map.keys()
    save = saver(ids, assigns, row_id)

    Enum.reduce(ids, {[], errors}, fn id, {saved, errors} ->
      case save.(id, Map.fetch!(by_id, id)) do
        {:ok, row} -> {[row | saved], errors}
        {:partial, row, row_errors} -> {[row | saved], errors ++ row_errors}
        {:error, row_errors} -> {saved, errors ++ row_errors}
      end
    end)
    |> then(fn {saved, errors} -> {Enum.reverse(saved), errors} end)
  end

  # An Ecto source reads, compares and saves each row in a transaction
  # that locks it; another source finds the rows of the batch at once.
  defp saver(_ids, %{source: %{module: EctoSource} = source} = assigns, _row_id) do
    fn id, edits ->
      EctoSource.locked(source.state, id, &save_row(&1, id, edits, assigns))
    end
  end

  defp saver(ids, assigns, row_id) do
    rows =
      assigns.source |> Source.fetch(ids, row_id) |> Map.new(&{Value.to_wire(row_id.(&1)), &1})

    fn id, edits -> save_row(Map.get(rows, id), id, edits, assigns) end
  end

  defp save_row(nil, id, edits, _assigns),
    do: {:error, Enum.map(edits, &[id, &1["key"], "This row is not in the grid."])}

  # The cells that the row's state makes read-only (`row_editable`, or a
  # column's `editable` function) are refused; the others are saved.
  # A cell changed meanwhile is refused, with its value now.
  defp save_row(row, id, edits, assigns) do
    {edits, locked} = Enum.split_with(edits, &cell_editable?(row, &1, assigns))
    {edits, stale} = Enum.split_with(edits, &current?(row, &1, assigns.columns))

    refused =
      Enum.map(locked, &[id, &1["key"], "This cell cannot be edited."]) ++
        Enum.map(stale, &conflict(row, id, &1, assigns))

    case edits do
      [] ->
        {:error, refused}

      edits ->
        case save(row, params(edits, assigns.columns), assigns) do
          {:ok, row} when refused == [] -> {:ok, row}
          {:ok, row} -> {:partial, row, refused}
          {:error, reason} -> {:error, refused ++ errors_of(reason, id, edits, assigns.columns)}
        end
    end
  end

  # Whether the cell still has the value the person saw. An edit without
  # `"before"` (from Masu.Test, say) is not compared. The values compare by
  # the column's type: "120.50" is 120.5, a date is its day.
  defp current?(_row, edit, _columns) when not is_map_key(edit, "before"), do: true

  defp current?(row, %{"key" => key, "before" => before}, columns) do
    column = Column.find(columns, key)
    now = Column.get(column, row)

    case Value.cast(column.type, before) do
      {:ok, before} -> same?(now, before)
      :error -> Value.to_wire(now) == before
    end
  end

  defp same?(nil, nil), do: true
  defp same?(nil, _before), do: false
  defp same?(_now, nil), do: false
  defp same?(now, before), do: Value.compare(now, before) == :eq

  # The refusal names who saved the row, when the grid knows (from its
  # live topic).
  defp conflict(row, id, %{"key" => key}, assigns) do
    value = assigns.columns |> Column.find(key) |> Column.get(row) |> Value.to_wire()

    message =
      case Map.get(Map.get(assigns, :saved_by, %{}), id) do
        nil -> "Changed by someone else meanwhile."
        name -> "Changed by #{name} meanwhile."
      end

    [id, key, message, value]
  end

  defp cell_editable?(row, %{"key" => key}, assigns) do
    row_editable = Map.get(assigns, :row_editable)

    (row_editable == nil or row_editable.(row) != false) and
      Column.editable?(Column.find(assigns.columns, key), row)
  end

  defp editable?(%{"id" => _id, "key" => key, "value" => value} = edit, columns)
       when is_binary(key) do
    match?(%Column{editable: true}, Column.find(columns, key)) and value?(value) and
      value?(Map.get(edit, "before"))
  end

  defp editable?(_edit, _columns), do: false

  defp value?(value),
    do: is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)

  # The params of a changeset: the column's field as a string, and an
  # empty value as nil.
  defp params(edits, columns) do
    Map.new(edits, fn %{"key" => key, "value" => value} ->
      column = Column.find(columns, key)
      {to_string(column.field), if(value == "", do: nil, else: value)}
    end)
  end

  defp save(row, params, %{update: update}) when is_function(update, 2) do
    case update.(row, params) do
      {:ok, row} ->
        {:ok, row}

      {:error, reason} ->
        {:error, reason}

      other ->
        raise ArgumentError,
              "a Masu grid's update gave #{inspect(other)}, not {:ok, row} or {:error, reason}"
    end
  end

  defp save(row, params, %{changeset: changeset} = assigns) when is_function(changeset, 2) do
    changeset = changeset.(row, params)

    if assigns.source.module == EctoSource,
      do: repo_update(changeset, assigns),
      else: Ecto.Changeset.apply_action(changeset, :update)
  end

  # A schema with Ecto's optimistic_lock (a lock_version) refuses a row
  # that changed since it was read.
  defp repo_update(changeset, assigns) do
    assigns.repo.update(changeset, assigns.repo_opts)
  rescue
    error in [Ecto.StaleEntryError] ->
      _ = error
      {:error, "Changed by someone else meanwhile."}
  end

  # The errors of a changeset go on the cells of their fields; an error
  # of a field that was not edited goes on the row's first edited cell.
  defp errors_of(%{__struct__: Ecto.Changeset} = changeset, id, edits, columns) do
    edited = Enum.map(edits, & &1["key"])
    first = hd(edited)

    errors =
      for {field, {message, opts}} <- changeset.errors do
        key =
          case Enum.find(columns, &(&1.field == field and &1.key in edited)) do
            nil -> first
            column -> column.key
          end

        [id, key, interpolate(message, opts)]
      end

    errors = if errors == [], do: [[id, first, "The row could not be saved."]], else: errors

    # The row is saved whole or not at all: its other edited cells say so.
    with_error = MapSet.new(errors, fn [_id, key | _] -> key end)

    errors ++
      for key <- edited,
          not MapSet.member?(with_error, key),
          do: [id, key, "Not saved: the row has an error."]
  end

  defp errors_of(message, id, edits, _columns) when is_binary(message),
    do: Enum.map(edits, &[id, &1["key"], message])

  defp errors_of(reason, id, [edit | _], _columns),
    do: [[id, edit["key"], "The row could not be saved: #{inspect(reason)}"]]

  defp interpolate(message, opts) do
    Enum.reduce(opts, message, fn {key, value}, message ->
      String.replace(message, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  @max_rows 1_000

  @doc false
  # The most rows a grid creates or deletes at once.
  def max_rows, do: @max_rows

  # New rows, each the values of its cells by column key: through the
  # grid's `create` function, or its `changeset` of its `struct` (inserted
  # by the repo of an Ecto source, applied for a list). Gives, for each,
  # `{:ok, row}`, or `{:error, [[key, message]]}`: its errors on its cells.
  @spec create([map()], map(), (term() -> term())) :: [{:ok, term()} | {:error, [list()]}]
  def create(drafts, assigns, row_id) when is_list(drafts) do
    drafts
    |> Enum.take(@max_rows)
    |> Enum.map(fn draft -> create_one(draft, assigns, row_id) end)
  end

  defp create_one(draft, assigns, row_id) when is_map(draft) do
    {cells, refused} =
      draft
      |> Enum.filter(fn {_key, value} -> value != "" and not is_nil(value) end)
      |> Enum.split_with(fn {key, value} ->
        match?(%Column{creatable: true}, Column.find(assigns.columns, key)) and value?(value)
      end)

    edits = Enum.map(cells, fn {key, value} -> %{"key" => key, "value" => value} end)

    case refused do
      [] ->
        params = params(edits, assigns.columns)
        keys = Enum.map(edits, & &1["key"])

        case insert(params, assigns) do
          {:ok, row} -> check_id(row, row_id)
          {:error, reason} -> {:error, new_errors(reason, keys, assigns.columns)}
        end

      refused ->
        {:error, Enum.map(refused, fn {key, _value} -> [key, "This cell cannot be set."] end)}
    end
  end

  defp create_one(_draft, _assigns, _row_id), do: {:error, [[nil, "Not a row."]]}

  # A new row of a list must have an id, as every row of a grid does.
  defp check_id(row, row_id) do
    if is_nil(row_id.(row)),
      do: {:error, [[nil, "The new row has no id."]]},
      else: {:ok, row}
  end

  defp insert(params, %{create: create}) when is_function(create, 1) do
    case create.(params) do
      {:ok, row} ->
        {:ok, row}

      {:error, reason} ->
        {:error, reason}

      other ->
        raise ArgumentError,
              "a Masu grid's create gave #{inspect(other)}, not {:ok, row} or {:error, reason}"
    end
  end

  defp insert(params, %{changeset: changeset, struct: struct} = assigns)
       when is_function(changeset, 2) and struct != nil do
    changeset = changeset.(new_struct(struct), params)

    if assigns.source.module == EctoSource,
      do: assigns.repo.insert(changeset, assigns.repo_opts),
      else: Ecto.Changeset.apply_action(changeset, :insert)
  end

  defp new_struct(fun) when is_function(fun, 0), do: fun.()
  defp new_struct(struct), do: struct

  # The errors of a new row, on its cells: an error of a field the person
  # did not fill goes on that field's column when it shows, else on the
  # row (`nil`).
  defp new_errors(%{__struct__: Ecto.Changeset} = changeset, keys, columns) do
    errors =
      for {field, {message, opts}} <- changeset.errors do
        key =
          case Enum.find(columns, &(&1.field == field)) do
            nil -> nil
            column -> column.key
          end

        [key, interpolate(message, opts)]
      end

    if errors == [], do: [[List.first(keys), "The row could not be saved."]], else: errors
  end

  defp new_errors(message, _keys, _columns) when is_binary(message), do: [[nil, message]]

  defp new_errors(reason, _keys, _columns),
    do: [[nil, "The row could not be saved: #{inspect(reason)}"]]

  # Rows deleted by their ids: through the grid's `delete` function, or
  # the repo of an Ecto source (in a transaction that locks the row), or
  # out of a list. A row is found among the rows its source may show, and
  # `deletable` (a function of the row) may refuse it. Gives the rows
  # deleted, and the errors as `[id, message]`.
  @spec delete([term()], map(), (term() -> term())) :: {[term()], [list()]}
  def delete(ids, assigns, row_id) when is_list(ids) do
    ids = Enum.take(ids, @max_rows)
    remove = remover(ids, assigns, row_id)

    {deleted, errors} =
      Enum.reduce(ids, {[], []}, fn id, {deleted, errors} ->
        case remove.(id) do
          {:ok, row} -> {[row | deleted], errors}
          {:error, message} -> {deleted, [[id, message] | errors]}
        end
      end)

    {Enum.reverse(deleted), Enum.reverse(errors)}
  end

  defp remover(_ids, %{source: %{module: EctoSource} = source} = assigns, _row_id) do
    fn id -> EctoSource.locked(source.state, id, &delete_row(&1, assigns)) end
  end

  defp remover(ids, assigns, row_id) do
    rows =
      assigns.source |> Source.fetch(ids, row_id) |> Map.new(&{Value.to_wire(row_id.(&1)), &1})

    fn id -> delete_row(Map.get(rows, id), assigns) end
  end

  defp delete_row(nil, _assigns), do: {:error, "This row is not in the grid."}

  defp delete_row(row, assigns) do
    if deletable?(assigns, row),
      do: remove(row, assigns),
      else: {:error, "This row cannot be deleted."}
  end

  @doc false
  # Whether the grid deletes the row: `deletable` (or a `delete`
  # function) says it deletes, and a `deletable` function says so for the
  # row.
  @spec deletable?(map(), term()) :: boolean()
  def deletable?(%{deletable: fun}, row) when is_function(fun, 1), do: fun.(row) == true
  def deletable?(assigns, _row), do: deletes?(assigns)

  @doc false
  @spec deletes?(map()) :: boolean()
  def deletes?(%{deletable: false}), do: false

  def deletes?(%{deletable: deletable}) when deletable == true or is_function(deletable, 1),
    do: true

  def deletes?(%{delete: delete}), do: is_function(delete, 1)

  defp remove(row, %{delete: delete}) when is_function(delete, 1) do
    case delete.(row) do
      :ok ->
        {:ok, row}

      {:ok, _deleted} ->
        {:ok, row}

      {:error, reason} ->
        {:error, delete_message(reason)}

      other ->
        raise ArgumentError,
              "a Masu grid's delete gave #{inspect(other)}, not :ok, {:ok, row} or {:error, reason}"
    end
  end

  defp remove(row, %{source: %{module: EctoSource}} = assigns) do
    if is_struct(row) and function_exported?(row.__struct__, :__schema__, 1) do
      case assigns.repo.delete(row, assigns.repo_opts) do
        {:ok, _deleted} -> {:ok, row}
        {:error, reason} -> {:error, delete_message(reason)}
      end
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

  # A list: the grid takes the row out of its copy.
  defp remove(row, _assigns), do: {:ok, row}

  defp delete_message(%{__struct__: Ecto.Changeset, errors: [{_field, {message, opts}} | _]}),
    do: interpolate(message, opts)

  defp delete_message(message) when is_binary(message), do: message
  defp delete_message(reason), do: "The row could not be deleted: #{inspect(reason)}"

  @doc false
  # Whether the grid brings deleted rows back (an undo): with its
  # `restore` function, by inserting them again into an Ecto source's
  # repo (when it deletes with the repo), or into a list.
  @spec restores?(map()) :: boolean()
  def restores?(%{restore: restore}) when is_function(restore, 1), do: true
  def restores?(%{delete: delete}) when is_function(delete, 1), do: false
  def restores?(assigns), do: deletes?(assigns)

  # Deleted rows, back: `{rows, errors}`, the errors as `[id, message]`.
  @spec restore([term()], map(), (term() -> term())) :: {[term()], [list()]}
  def restore(rows, assigns, row_id) do
    {restored, errors} =
      Enum.reduce(rows, {[], []}, fn row, {restored, errors} ->
        case restore_row(row, assigns) do
          {:ok, row} ->
            {[row | restored], errors}

          {:error, reason} ->
            {restored, [[Value.to_wire(row_id.(row)), delete_message(reason)] | errors]}
        end
      end)

    {Enum.reverse(restored), Enum.reverse(errors)}
  end

  defp restore_row(row, %{restore: restore}) when is_function(restore, 1), do: restore.(row)

  defp restore_row(row, %{source: %{module: EctoSource}} = assigns) do
    row |> Ecto.put_meta(state: :built) |> assigns.repo.insert(assigns.repo_opts)
  rescue
    error in [Ecto.ConstraintError] ->
      _ = error
      {:error, "The row could not be brought back."}
  end

  defp restore_row(row, _assigns), do: {:ok, row}
end

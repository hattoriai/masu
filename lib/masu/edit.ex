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
        Enum.map(stale, &conflict(row, id, &1, assigns.columns))

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

  defp conflict(row, id, %{"key" => key}, columns) do
    value = columns |> Column.find(key) |> Column.get(row) |> Value.to_wire()
    [id, key, "Changed by someone else meanwhile.", value]
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
end

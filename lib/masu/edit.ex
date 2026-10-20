defmodule Masu.Edit do
  @moduledoc false
  # The writes of the browser, as `Masu.Write`s: cells edited (a cell
  # typed in, a paste, a fill or an undo, each `%{"id" => id, "key" =>
  # key, "value" => value}`), new rows, rows deleted, rows back.
  #
  # The grid does its part here: each row is found among the rows its
  # source may show (`Masu.Source.fetch/3`), only the editable columns
  # take a value, the cells that the row's state makes read-only are
  # refused, and so are those someone changed meanwhile. An edit may
  # carry `"before"`, the value the person saw: when the cell's value is
  # no longer that one, the edit is refused (optimistic concurrency, a
  # compare-and-swap of the cell). The rest goes to the grid's function
  # for the write (`on_update`...), or Masu.Write.save/1, which for an
  # Ecto source reads, compares and saves each row again in a
  # transaction that locks it.
  #
  # The errors go back as the browser takes them: `[id, key, message]`,
  # or `[id, key, message, value]` for a cell changed meanwhile, with its
  # value now.

  alias Masu.{Column, Source, Value, Write}
  alias Masu.Write.Change

  @max_edits 5_000
  @max_rows 1_000

  @type error :: [term()]

  @doc false
  # The most rows a grid creates or deletes at once.
  def max_rows, do: @max_rows

  @origins Map.new(
             ~w(edit paste fill clear undo redo draft rows selection restore test)a,
             &{Atom.to_string(&1), &1}
           )

  @doc false
  # What the person did, as the browser says it.
  @spec origin(term(), atom()) :: atom()
  def origin(origin, default), do: Map.get(@origins, origin, default)

  @doc false
  # The grid's part of a write, for Masu.Write.save/1.
  @spec config(map(), (term() -> term())) :: map()
  def config(assigns, row_id) do
    %{
      source: assigns.source,
      repo: assigns.repo,
      repo_opts: assigns.repo_opts,
      changeset: assigns[:changeset],
      struct: assigns[:struct],
      create_with: assigns[:create_with] || %{},
      columns: assigns.all_columns,
      row_id: row_id,
      grid: assigns.id,
      history: assigns[:history],
      user: assigns[:user],
      batch: nil
    }
  end

  # A write, through the grid's function for it or the grid's own way.
  # A change left without a result is a mistake of the function.
  defp run(%Write{changes: []} = write, _handler), do: write

  defp run(%Write{} = write, handler) do
    case (handler || (&Write.save/1)).(write) do
      %Write{} = done ->
        case Write.open(done) do
          [] ->
            Write.record_rest(done)

          open ->
            raise ArgumentError,
                  "the on_#{write.op} of the grid #{write.grid} left #{length(open)} of its changes " <>
                    "without a result: give each one with Masu.Write.each/2, all/2, ok/3, error/3, " <>
                    "save/1 or async/1"
        end

      other ->
        raise ArgumentError,
              "the on_#{write.op} of the grid #{write.grid} gave #{inspect(other)}, not the Masu.Write"
    end
  end

  defp new_write(op, assigns, row_id, origin, changes) do
    {ref, token} = Masu.Ref.new(assigns.id)

    write = %Write{
      grid: assigns.id,
      op: op,
      origin: origin,
      scope: assigns[:scope],
      ref: ref,
      changes: changes,
      grid_config: %{config(assigns, row_id) | batch: token}
    }

    {write, token}
  end

  ## Cells

  @doc false
  # Edits of cells: the rows saved, the errors, and the cells that are
  # saved later (`Masu.Write.async/1`), with the write's token.
  @spec update([map()], map(), (term() -> term()), atom()) :: %{
          saved: [term()],
          errors: [error()],
          pending: [[term()]],
          token: String.t() | nil
        }
  def update(edits, assigns, row_id, origin) when is_list(edits) do
    {edits, refused} =
      edits
      |> Enum.take(@max_edits)
      |> Enum.split_with(&editable?(&1, assigns.columns))

    errors = Enum.map(refused, &[&1["id"], &1["key"], "This cell cannot be edited."])
    by_id = Enum.group_by(edits, & &1["id"])
    ids = Map.keys(by_id)

    rows =
      assigns.source |> Source.fetch(ids, row_id) |> Map.new(&{Value.to_wire(row_id.(&1)), &1})

    {changes, errors} =
      ids
      |> Enum.reduce({[], errors}, fn id, {changes, errors} ->
        case change(Map.get(rows, id), id, Map.fetch!(by_id, id), assigns, length(changes)) do
          {nil, refused} -> {changes, errors ++ refused}
          {change, refused} -> {[change | changes], errors ++ refused}
        end
      end)
      |> then(fn {changes, errors} -> {Enum.reverse(changes), errors} end)

    {write, token} = new_write(:update, assigns, row_id, origin, changes)
    write = run(write, assigns[:on_update])

    Enum.reduce(
      write.changes,
      %{saved: [], errors: errors, pending: [], token: nil},
      fn change, acc ->
        case Map.fetch!(write.results, change.index) do
          {:ok, row} ->
            %{acc | saved: acc.saved ++ [row]}

          {:ok, row, {:stale, now, keys}} ->
            %{
              acc
              | saved: acc.saved ++ [row],
                errors: acc.errors ++ conflicts(now, change, keys, assigns)
            }

          {:error, {:stale, now, keys}} ->
            %{acc | errors: acc.errors ++ conflicts(now, change, keys, assigns)}

          {:error, reason} ->
            %{
              acc
              | errors: acc.errors ++ errors_of(reason, change.id, change.keys, assigns.columns)
            }

          :pending ->
            %{acc | pending: acc.pending ++ Enum.map(change.keys, &[change.id, &1]), token: token}
        end
      end
    )
  end

  # The change of a row, of its edits that are left: the cells that the
  # row's state makes read-only are refused, and so are those changed
  # meanwhile.
  defp change(nil, id, edits, _assigns, _index),
    do: {nil, Enum.map(edits, &[id, &1["key"], "This row is not in the grid."])}

  defp change(row, id, edits, assigns, index) do
    # What the person saw: the value, or, for an editor's form, a version
    # of it (version/1).
    before =
      for edit <- edits, Map.has_key?(edit, "before") or is_integer(edit["version"]), into: %{} do
        case edit do
          %{"key" => key, "version" => version} when is_integer(version) ->
            {key, {:version, version}}

          %{"key" => key, "before" => seen} ->
            {key, seen}
        end
      end

    probe = %Change{before: before}

    {edits, locked} = Enum.split_with(edits, &cell_editable?(row, &1, assigns))

    {edits, stale} =
      Enum.split_with(edits, &Write.current?(row, probe, &1["key"], assigns.columns))

    refused =
      Enum.map(locked, &[id, &1["key"], "This cell cannot be edited."]) ++
        conflicts(row, %Change{id: id}, Enum.map(stale, & &1["key"]), assigns)

    case edits do
      [] ->
        {nil, refused}

      edits ->
        keys = Enum.map(edits, & &1["key"])

        change = %Change{
          index: index,
          id: id,
          row: row,
          params: params(edits, assigns.columns),
          keys: keys,
          before: Map.take(before, keys)
        }

        {change, refused}
    end
  end

  # The refusal names who saved the row, when the grid knows (from its
  # live topic).
  defp conflicts(row, change, keys, assigns) do
    message =
      case Map.get(Map.get(assigns, :saved_by, %{}), change.id) do
        nil -> "Changed by someone else meanwhile."
        name -> "Changed by #{name} meanwhile."
      end

    for key <- keys do
      value = assigns.columns |> Column.find(key) |> Column.get(row) |> Value.to_wire()
      [change.id, key, message, value]
    end
  end

  defp cell_editable?(row, %{"key" => key}, assigns) do
    row_editable = Map.get(assigns, :row_editable)

    (row_editable == nil or row_editable.(row) != false) and
      Column.editable?(Column.find(assigns.columns, key), row)
  end

  defp editable?(%{"id" => _id, "key" => key, "value" => value} = edit, columns)
       when is_binary(key) do
    case Column.find(columns, key) do
      %Column{editable: true} = column ->
        value?(value, column) and value?(Map.get(edit, "before"))

      _other ->
        false
    end
  end

  defp editable?(_edit, _columns), do: false

  defp value?(value),
    do: is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)

  # An editor's form posts params: text, and maps and lists of them (a
  # range's `from` and `to`, a list of tags).
  defp value?(value, %Column{editor: {:form, _fun}}), do: params?(value, 4)
  defp value?(value, _column), do: value?(value)

  defp params?(_value, 0), do: false

  defp params?(value, depth) when is_map(value),
    do: Enum.all?(value, fn {k, v} -> is_binary(k) and params?(v, depth - 1) end)

  defp params?(value, depth) when is_list(value), do: Enum.all?(value, &params?(&1, depth - 1))
  defp params?(value, _depth), do: value?(value)

  @doc false
  # A version of a cell's value, for an editor's form: an edit of the cell
  # carries it, and the cell is refused when its value is no longer the
  # one of that version.
  @spec version(term()) :: non_neg_integer()
  def version(value), do: :erlang.phash2(value)

  # The params of a changeset: the column's field as a string, and an
  # empty value as nil.
  defp params(edits, columns) do
    Map.new(edits, fn %{"key" => key, "value" => value} ->
      column = Column.find(columns, key)
      {to_string(column.field), if(value == "", do: nil, else: value)}
    end)
  end

  # The errors of a row's change, on its cells: a changeset's go on the
  # cells of their fields, and an error of a field that was not edited
  # on the row's first edited cell; the row is saved whole or not at all,
  # so its other edited cells say so.
  defp errors_of(%{__struct__: Ecto.Changeset} = changeset, id, keys, columns) do
    first = hd(keys)

    errors =
      for {field, {message, opts}} <- changeset.errors do
        key =
          case Enum.find(columns, &(&1.field == field and &1.key in keys)) do
            nil -> first
            column -> column.key
          end

        [id, key, interpolate(message, opts)]
      end

    errors = if errors == [], do: [[id, first, "The row could not be saved."]], else: errors
    errors ++ not_saved(errors, id, keys)
  end

  defp errors_of(message, id, keys, _columns) when is_binary(message),
    do: Enum.map(keys, &[id, &1, message])

  defp errors_of([{_key, message} | _] = list, id, keys, _columns) when is_binary(message) do
    errors =
      for {key, message} <- list do
        key = to_string(key)
        [id, if(key in keys, do: key, else: hd(keys)), message]
      end

    errors ++ not_saved(errors, id, keys)
  end

  defp errors_of(reason, id, [key | _], _columns),
    do: [[id, key, "The row could not be saved: #{inspect(reason)}"]]

  defp not_saved(errors, id, keys) do
    with_error = MapSet.new(errors, fn [_id, key | _] -> key end)

    for key <- keys,
        not MapSet.member?(with_error, key),
        do: [id, key, "Not saved: the row has an error."]
  end

  defp interpolate(message, opts) do
    Enum.reduce(opts, message, fn {key, value}, message ->
      String.replace(message, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  ## New rows

  @doc false
  # New rows, each the values of its cells by column key. Gives, for
  # each, `{:ok, row}`, or `{:error, [[key, message]]}`: its errors on its
  # cells (a key of nil for the row).
  @spec create([map()], map(), (term() -> term()), atom()) :: [
          {:ok, term()} | {:error, [list()]}
        ]
  def create(drafts, assigns, row_id, origin) when is_list(drafts) do
    drafts = Enum.take(drafts, @max_rows)

    built =
      drafts
      |> Enum.with_index()
      |> Enum.map(fn {draft, index} -> new_change(draft, index, assigns) end)

    changes = for %Change{} = change <- built, do: change
    {write, _token} = new_write(:create, assigns, row_id, origin, changes)
    write = run(write, assigns[:on_create])

    Enum.map(built, fn
      {:error, errors} ->
        {:error, errors}

      %Change{} = change ->
        case Map.fetch!(write.results, change.index) do
          {:ok, row} -> check_id(row, row_id)
          {:error, reason} -> {:error, new_errors(reason, change.keys, assigns.columns)}
        end
    end)
  end

  defp new_change(draft, index, assigns) when is_map(draft) do
    {cells, refused} =
      draft
      |> Enum.filter(fn {_key, value} -> value != "" and not is_nil(value) end)
      |> Enum.split_with(fn {key, value} ->
        match?(%Column{creatable: true}, Column.find(assigns.columns, key)) and value?(value)
      end)

    case refused do
      [] ->
        edits = Enum.map(cells, fn {key, value} -> %{"key" => key, "value" => value} end)

        %Change{
          index: index,
          params: params(edits, assigns.columns),
          keys: Enum.map(edits, & &1["key"])
        }

      refused ->
        {:error, Enum.map(refused, fn {key, _value} -> [key, "This cell cannot be set."] end)}
    end
  end

  defp new_change(_draft, _index, _assigns), do: {:error, [[nil, "Not a row."]]}

  # A new row must have an id, as every row of a grid does.
  defp check_id(row, row_id) do
    if is_nil(row_id.(row)),
      do: {:error, [[nil, "The new row has no id."]]},
      else: {:ok, row}
  end

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

  defp new_errors([{_key, message} | _] = list, _keys, _columns) when is_binary(message),
    do: Enum.map(list, fn {key, message} -> [key && to_string(key), message] end)

  defp new_errors(reason, _keys, _columns),
    do: [[nil, "The row could not be saved: #{inspect(reason)}"]]

  ## Deleted rows

  @doc false
  # Rows deleted by their ids: a row is found among the rows its source
  # may show, and `deletable` (a function of the row) may refuse it.
  # Gives the rows deleted, the errors as `[id, message]`, and the ids of
  # those deleted later, with the write's token.
  @spec delete([term()], map(), (term() -> term()), atom()) :: %{
          deleted: [term()],
          errors: [list()],
          pending: [term()],
          token: String.t() | nil
        }
  def delete(ids, assigns, row_id, origin) when is_list(ids) do
    ids = Enum.take(ids, @max_rows)

    rows =
      assigns.source |> Source.fetch(ids, row_id) |> Map.new(&{Value.to_wire(row_id.(&1)), &1})

    {changes, errors} =
      Enum.reduce(ids, {[], []}, fn id, {changes, errors} ->
        case to_delete(Map.get(rows, id), id, assigns, length(changes)) do
          {:ok, change} -> {changes ++ [change], errors}
          {:error, error} -> {changes, errors ++ [error]}
        end
      end)

    {write, token} = new_write(:delete, assigns, row_id, origin, changes)
    write = run(write, assigns[:on_delete])

    Enum.reduce(
      write.changes,
      %{deleted: [], errors: errors, pending: [], token: nil},
      fn change, acc ->
        case Map.fetch!(write.results, change.index) do
          {:ok, row} -> %{acc | deleted: acc.deleted ++ [row || change.row]}
          {:error, reason} -> %{acc | errors: acc.errors ++ [[change.id, delete_message(reason)]]}
          :pending -> %{acc | pending: acc.pending ++ [change.id], token: token}
        end
      end
    )
  end

  defp to_delete(nil, id, _assigns, _index), do: {:error, [id, "This row is not in the grid."]}

  defp to_delete(row, id, assigns, index) do
    if deletable?(assigns, row),
      do: {:ok, %Change{index: index, id: id, row: row}},
      else: {:error, [id, "This row cannot be deleted."]}
  end

  @doc false
  # Whether the grid deletes the row: it deletes, and a `deletable`
  # function says so for the row.
  @spec deletable?(map(), term()) :: boolean()
  def deletable?(%{deletable: fun}, row) when is_function(fun, 1), do: fun.(row) == true
  def deletable?(assigns, _row), do: deletes?(assigns)

  @doc false
  # Whether the grid deletes rows: `deletable` (`true`, or a function of
  # the row), or an `on_delete` of its own; `deletable={false}` never.
  @spec deletes?(map()) :: boolean()
  def deletes?(%{deletable: false}), do: false

  def deletes?(%{deletable: deletable}) when deletable == true or is_function(deletable, 1),
    do: true

  def deletes?(assigns), do: is_function(assigns[:on_delete], 1)

  defp delete_message(%{__struct__: Ecto.Changeset, errors: [{_field, {message, opts}} | _]}),
    do: interpolate(message, opts)

  defp delete_message(message) when is_binary(message), do: message
  defp delete_message([{_key, message} | _]) when is_binary(message), do: message
  defp delete_message(reason), do: "The row could not be deleted: #{inspect(reason)}"

  ## Rows back

  @doc false
  # Whether the grid brings deleted rows back (an undo): with its
  # `on_restore`, or its own way, when it deletes its own way too.
  @spec restores?(map()) :: boolean()
  def restores?(assigns) do
    cond do
      is_function(assigns[:on_restore], 1) -> true
      is_function(assigns[:on_delete], 1) -> false
      true -> deletes?(assigns)
    end
  end

  @doc false
  # Deleted rows, back: `{rows, errors}`, the errors as `[id, message]`.
  @spec restore([term()], map(), (term() -> term())) :: {[term()], [list()]}
  def restore(rows, assigns, row_id) do
    changes =
      rows
      |> Enum.with_index()
      |> Enum.map(fn {row, index} ->
        %Change{index: index, id: Value.to_wire(row_id.(row)), row: row}
      end)

    {write, _token} = new_write(:restore, assigns, row_id, :undo, changes)
    write = run(write, assigns[:on_restore])

    Enum.reduce(write.changes, {[], []}, fn change, {restored, errors} ->
      case Map.fetch!(write.results, change.index) do
        {:ok, row} -> {restored ++ [row], errors}
        {:error, reason} -> {restored, errors ++ [[change.id, delete_message(reason)]]}
      end
    end)
  end
end

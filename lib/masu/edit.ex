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
  # Returns the rows saved, and the errors as `[id, key, message]`.

  alias Masu.{Column, Source, Value}

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

    rows =
      assigns.source |> Source.fetch(ids, row_id) |> Map.new(&{Value.to_wire(row_id.(&1)), &1})

    Enum.reduce(ids, {[], errors}, fn id, {saved, errors} ->
      case save_row(Map.get(rows, id), id, Map.fetch!(by_id, id), assigns) do
        {:ok, row} -> {[row | saved], errors}
        {:error, row_errors} -> {saved, errors ++ row_errors}
      end
    end)
    |> then(fn {saved, errors} -> {Enum.reverse(saved), errors} end)
  end

  defp save_row(nil, id, edits, _assigns),
    do: {:error, Enum.map(edits, &[id, &1["key"], "This row is not in the grid."])}

  defp save_row(row, id, edits, assigns) do
    case save(row, params(edits, assigns.columns), assigns) do
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:error, errors_of(reason, id, edits, assigns.columns)}
    end
  end

  defp editable?(%{"id" => _id, "key" => key, "value" => value}, columns) when is_binary(key) do
    match?(%Column{editable: true}, Column.find(columns, key)) and
      (is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value))
  end

  defp editable?(_edit, _columns), do: false

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

    if assigns.source.module == Masu.Source.Ecto,
      do: assigns.repo.update(changeset, assigns.repo_opts),
      else: Ecto.Changeset.apply_action(changeset, :update)
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
    with_error = MapSet.new(errors, fn [_id, key, _message] -> key end)

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

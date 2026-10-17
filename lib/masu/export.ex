defmodule Masu.Export do
  @moduledoc """
  A grid's rows as a file: CSV or XLSX, of every row of the person's
  query (their order, filters and search), with the columns that show,
  in their order, and their labels as the first row.

  A grid with `export` has an Export menu. The file is not written in the
  LiveView, nor sent over its socket: the menu gives the browser a link,
  good once and for five minutes, to the route `Masu.Router.masu_exports/1`
  mounts, and the browser downloads it from there as the rows are read, a
  block at a time, with its own progress. See the [Export
  guide](export.md).

  An app exports a grid itself with `Masu.Live.export/1`, in the
  LiveView: it gives the export as data, which `write/4` writes anywhere,
  in a task or a background job, and `stream/2` streams, to a
  controller's response, say:

      def handle_event("email_report", _params, socket) do
        export = Masu.Live.export("orders")
        Task.start(fn ->
          path = Path.join(System.tmp_dir!(), "orders.xlsx")
          :ok = Masu.Export.write(export, :xlsx, path)
          MyApp.Mailer.deliver_report(path)
        end)
        {:noreply, socket}
      end

  The rows are read from the source a block at a time; an export of an
  Ecto source never holds more than a block. Grouped rows and a tree's
  rows are exported as rows, every one of them.

  ## Values

  CSV: values as the browser gets them (numbers, decimals with their
  digits, dates and times in ISO 8601, `true` and `false`), in UTF-8.
  Text that starts with `=`, `+`, `-`, `@` or a tab starts with `'`, so
  that a spreadsheet does not run it as a formula.

  XLSX: numbers and decimals as numbers, dates, times and datetimes as
  dates (in UTC), booleans as booleans, text as text. A column with
  content of its own exports its value, not its HTML. A sheet has
  1,048,576 rows at most (Excel's limit): an XLSX export stops there; a
  CSV one does not.
  """

  alias Masu.{Column, Query, Source, Value}
  alias Masu.Export.Xlsx

  @block 500

  # Excel's rows, less the labels' row.
  @xlsx_rows 1_048_575

  @type format :: :csv | :xlsx

  @type t :: %__MODULE__{
          input: term(),
          opts: keyword(),
          query: Query.t(),
          columns: [Column.t()],
          all_columns: [Column.t()],
          name: String.t()
        }

  defstruct [:input, :opts, :query, :name, columns: [], all_columns: []]

  @doc """
  The file of an export, a block of rows at a time (iodata): CSV, the
  labels first, or XLSX.
  """
  @spec stream(t(), format()) :: Enumerable.t()
  def stream(%__MODULE__{} = export, format \\ :csv), do: encode(export, format, blocks(export))

  @doc """
  Writes an export to `path`. Options: `:progress`, a function of the
  rows written and the rows there are, called after each block.
  """
  @spec write(t(), format(), Path.t(), keyword()) :: :ok
  def write(%__MODULE__{} = export, format, path, opts \\ []) when format in [:csv, :xlsx] do
    blocks =
      case Keyword.get(opts, :progress) do
        nil -> blocks(export)
        fun -> counted(blocks(export), fun, count(export))
      end

    File.open!(path, [:write, :binary], fn file ->
      export |> encode(format, blocks) |> Enum.each(&IO.binwrite(file, &1))
    end)

    :ok
  end

  defp encode(export, :csv, blocks) do
    header = [Enum.map_join(export.columns, ",", &csv_text(&1.label)), "\r\n"]
    lines = Stream.map(blocks, fn rows -> Enum.map(rows, &csv_line(&1, export.columns)) end)
    Stream.concat([header], lines)
  end

  defp encode(export, :xlsx, blocks), do: Xlsx.stream(export, take(blocks, @xlsx_rows))

  # The blocks of `blocks`, up to `limit` rows.
  defp take(blocks, limit) do
    Stream.transform(blocks, limit, fn
      _rows, 0 -> {:halt, 0}
      rows, left when length(rows) <= left -> {[rows], left - length(rows)}
      rows, left -> {[Enum.take(rows, left)], 0}
    end)
  end

  # The blocks, and how far they got after each, and at their end.
  defp counted(blocks, fun, total) do
    Stream.transform(
      blocks,
      fn -> 0 end,
      fn rows, done ->
        done = done + length(rows)
        fun.(min(done, total), total)
        {[rows], done}
      end,
      fn done ->
        fun.(total, total)
        {[], done}
      end,
      fn _done -> :ok end
    )
  end

  @doc false
  # The media type and extension of a format.
  @spec type(format()) :: {String.t(), String.t()}
  def type(:csv), do: {"text/csv", "csv"}

  def type(:xlsx),
    do: {"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "xlsx"}

  # Every row of the query, a block at a time (a list each): not grouped,
  # every row of a tree.
  @doc false
  @spec blocks(t()) :: Enumerable.t()
  def blocks(%__MODULE__{} = export) do
    Stream.resource(
      fn -> {source(export), 0} end,
      fn
        :done ->
          {:halt, :done}

        {source, offset} ->
          case Source.rows(source, offset, @block) do
            [] -> {:halt, :done}
            rows when length(rows) < @block -> {[rows], :done}
            rows -> {[rows], {source, offset + @block}}
          end
      end,
      fn _state -> :ok end
    )
  end

  defp source(export) do
    export.input
    |> Source.new(Keyword.delete(export.opts, :tree))
    |> Source.prepare(%{export.query | groups: []}, export.all_columns)
  end

  defp count(export), do: export |> source() |> Source.count()

  defp csv_line(row, columns) do
    [Enum.map_join(columns, ",", &csv_value(&1, Column.get(&1, row))), "\r\n"]
  end

  defp csv_value(_column, nil), do: ""

  defp csv_value(%Column{type: type}, value) when type in [:text, :enum],
    do: value |> to_string() |> guard() |> csv_text()

  defp csv_value(_column, value), do: value |> Value.to_wire() |> to_string() |> csv_text()

  # A spreadsheet runs text that starts with these as a formula.
  defp guard(<<first, _rest::binary>> = text) when first in [?=, ?+, ?-, ?@, ?\t, ?\r],
    do: "'" <> text

  defp guard(text), do: text

  defp csv_text(text) do
    if String.contains?(text, [",", "\"", "\n", "\r"]),
      do: ["\"", String.replace(text, "\"", "\"\""), "\""],
      else: text
  end
end

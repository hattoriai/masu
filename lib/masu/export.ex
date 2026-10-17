defmodule Masu.Export do
  @moduledoc """
  A grid's rows as a file: CSV or XLSX, of every row of the person's
  query (their order, filters and search), with the columns that show,
  in their order, and their labels as the first row.

  A grid with `export` has an Export menu: the file is written in a task
  (the LiveView goes on), the grid says how far it got, and the browser
  downloads it when it is done.

  An app exports a grid itself with `Masu.Live.export/1`, in the
  LiveView: it gives the export as data, which `write/4` writes anywhere,
  in a task or a background job, and `stream/1` streams as CSV, to a
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

  The rows are read from the source a block at a time; a grid of an Ecto
  source never holds more than a block. Grouped rows and a tree's rows
  are exported as rows, every one of them.

  ## Values

  CSV: values as the browser gets them (numbers, decimals with their
  digits, dates and times in ISO 8601, `true` and `false`). Text that
  starts with `=`, `+`, `-`, `@` or a tab starts with `'`, so that a
  spreadsheet does not run it as a formula.

  XLSX: numbers and decimals as numbers, dates, times and datetimes as
  dates (in UTC), booleans as booleans, text as text. A column with
  content of its own exports its value, not its HTML.
  """

  alias Masu.{Column, Query, Source, Value}
  alias Masu.Export.Xlsx

  @block 500

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
  The rows of an export as CSV, a line at a time (iodata), the labels
  first.
  """
  @spec stream(t()) :: Enumerable.t()
  def stream(%__MODULE__{columns: columns} = export) do
    header = [Enum.map_join(columns, ",", &csv_text(&1.label)), "\r\n"]
    Stream.concat([header], export |> rows() |> Stream.map(&csv_line(&1, columns)))
  end

  @doc """
  Writes an export to `path`. Options: `:progress`, a function of the
  rows written and the rows there are, called after each block.
  """
  @spec write(t(), format(), Path.t(), keyword()) :: :ok
  def write(export, format, path, opts \\ [])

  def write(%__MODULE__{} = export, :csv, path, opts) do
    progress = progress(export, opts)

    File.open!(path, [:write, :binary], fn file ->
      export
      |> stream()
      |> Stream.with_index()
      |> Enum.each(&write_line(file, &1, progress))
    end)

    progress.(:done)
    :ok
  end

  def write(%__MODULE__{} = export, :xlsx, path, opts) do
    progress = progress(export, opts)
    Xlsx.write(export, rows(export), path, progress)
    progress.(:done)
    :ok
  end

  defp write_line(file, {line, i}, progress) do
    IO.binwrite(file, line)
    if i > 0 and rem(i, @block) == 0, do: progress.(i)
  end

  @doc false
  # The media type and extension of a format.
  @spec type(format()) :: {String.t(), String.t()}
  def type(:csv), do: {"text/csv", "csv"}

  def type(:xlsx),
    do: {"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "xlsx"}

  # Every row of the query, a block at a time: not grouped, every row of
  # a tree.
  @doc false
  @spec rows(t()) :: Enumerable.t()
  def rows(%__MODULE__{} = export) do
    Stream.resource(
      fn ->
        source =
          export.input
          |> Source.new(Keyword.delete(export.opts, :tree))
          |> Source.prepare(%{export.query | groups: []}, export.all_columns)

        {source, 0}
      end,
      fn
        :done ->
          {:halt, :done}

        {source, offset} ->
          case Source.rows(source, offset, @block) do
            [] -> {:halt, :done}
            rows when length(rows) < @block -> {rows, :done}
            rows -> {rows, {source, offset + @block}}
          end
      end,
      fn _state -> :ok end
    )
  end

  defp progress(export, opts) do
    case Keyword.get(opts, :progress) do
      nil ->
        fn _done -> :ok end

      fun ->
        total = count(export)

        fn
          :done -> fun.(total, total)
          done -> fun.(min(done, total), total)
        end
    end
  end

  defp count(export) do
    export.input
    |> Source.new(Keyword.delete(export.opts, :tree))
    |> Source.prepare(%{export.query | groups: []}, export.all_columns)
    |> Source.count()
  end

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

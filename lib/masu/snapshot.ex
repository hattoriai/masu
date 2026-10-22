defmodule Masu.Snapshot do
  @moduledoc """
  A grid's rows as they are now, as a table that reads without the grid:
  Markdown, for a document exported with a grid in it (a Kotoba embed),
  and HTML, for a page or an email that shows the document.

      sheet = Masu.Sheet.new(MyApp.Grids.tasks(scope))
      Masu.Snapshot.markdown(sheet, view: saved_view.params, rows: 20)

  ```markdown
  | Task | Due | Done |
  | :--- | :--- | :---: |
  | Write the guide | 2026-11-02 | false |

  _And 37 more rows._
  ```

  Options:

    * `:view` - a view's params (`Masu.View`, a saved view's `params`):
      its order, filters, search, and columns that show. The grid's own
      view unless given.
    * `:rows` - how many rows, at most (20 unless given, 500 at most).
    * `:more` - what follows the rows when the query has more, a function
      of how many more (`"And 37 more rows."` unless given), or `nil` for
      nothing.

  A cell is its value as text: a date in ISO 8601, a decimal to its last
  digit. Cells of your own HEEx are their column's value.
  """

  alias Masu.{Column, Layout, Query, Sheet, Source, Value, View}

  @type table :: %{
          columns: [Column.t()],
          rows: [[String.t()]],
          more: non_neg_integer() | nil
        }

  @doc """
  The rows and columns of the snapshot, as text: `%{columns:, rows:,
  more:}`, `more` the rows of the query past those, or `nil` when the
  source does not count.
  """
  @spec table(Sheet.t(), keyword()) :: table()
  def table(%Sheet{} = sheet, opts \\ []) do
    limit = opts |> Keyword.get(:rows, 20) |> max(1) |> min(500)
    {:ok, query} = Query.new([], sheet.columns)
    default = %View{query: query, layout: Layout.new(sheet.columns)}
    {view, _dropped} = View.from_params(Keyword.get(opts, :view) || %{}, sheet.columns, default)
    columns = Layout.columns(view.layout, sheet.columns)
    source = Source.prepare(sheet.source, %{view.query | groups: []}, sheet.columns)
    rows = Source.rows(source, 0, limit)

    more =
      case Source.counted(source) do
        {count, true} -> max(count - length(rows), 0)
        {_count, false} -> nil
      end

    %{
      columns: columns,
      rows: Enum.map(rows, fn row -> Enum.map(columns, &text(&1, row)) end),
      more: more
    }
  end

  @doc "The snapshot as a Markdown table."
  @spec markdown(Sheet.t(), keyword()) :: String.t()
  def markdown(%Sheet{} = sheet, opts \\ []) do
    %{columns: columns, rows: rows, more: more} = table(sheet, opts)

    lines =
      [
        line(Enum.map(columns, &cell(&1.label))),
        line(Enum.map(columns, &rule(&1.align)))
        | Enum.map(rows, fn row -> line(Enum.map(row, &cell/1)) end)
      ]

    case more_text(more, opts) do
      nil -> Enum.join(lines, "\n")
      text -> Enum.join(lines, "\n") <> "\n\n_" <> cell(text) <> "_"
    end
  end

  @doc "The snapshot as an HTML table (`table.masu-snapshot`), safe HTML."
  @spec html(Sheet.t(), keyword()) :: Phoenix.HTML.safe()
  def html(%Sheet{} = sheet, opts \\ []) do
    %{columns: columns, rows: rows, more: more} = table(sheet, opts)
    aligns = Enum.map(columns, & &1.align)

    head =
      for column <- columns,
          do: [~s(<th class="masu-align-#{column.align}">), escape(column.label), "</th>"]

    body =
      for row <- rows do
        cells =
          for {text, align} <- Enum.zip(row, aligns),
              do: [~s(<td class="masu-align-#{align}">), escape(text), "</td>"]

        ["<tr>", cells, "</tr>"]
      end

    more =
      case more_text(more, opts) do
        nil -> []
        text -> [~s(<p class="masu-snapshot-more">), escape(text), "</p>"]
      end

    {:safe,
     [
       ~s(<table class="masu-snapshot"><thead><tr>),
       head,
       "</tr></thead><tbody>",
       body,
       "</tbody></table>",
       more
     ]}
  end

  defp text(column, row) do
    case Column.flat(column, row) do
      nil -> ""
      value when is_binary(value) -> value
      value -> value |> Value.to_wire() |> to_string()
    end
  end

  defp more_text(more, opts) do
    case {more, Keyword.get(opts, :more, &default_more/1)} do
      {nil, _fun} -> nil
      {0, _fun} -> nil
      {_more, nil} -> nil
      {more, fun} -> fun.(more)
    end
  end

  defp default_more(1), do: "And 1 more row."
  defp default_more(more), do: "And #{more} more rows."

  defp line(cells), do: "| " <> Enum.join(cells, " | ") <> " |"

  defp rule(:end), do: "---:"
  defp rule(:center), do: ":---:"
  defp rule(_start), do: ":---"

  # A cell of a Markdown table: one line, its pipes and backslashes escaped.
  defp cell(text) do
    text
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("|", "\\|")
    |> String.replace(~r/\s*\R\s*/, " ")
  end

  defp escape(text),
    do: text |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end

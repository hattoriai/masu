defmodule Masu.Test do
  @moduledoc """
  Helpers for `Phoenix.LiveViewTest`, to read and query the grids of a
  LiveView with no browser.

      import Masu.Test

      test "finds the late orders", %{conn: conn} do
        {:ok, view, _html} = live(conn, ~p"/orders")

        assert total(view, "orders") == 120

        view
        |> filter("orders", [{"status", :eq, "late"}])
        |> sort("orders", {"total", :desc})

        assert [%{"number" => "A-1042"} | _] = rows(view, "orders")
      end

  The functions send the events that the browser sends (see `Masu.Grid`),
  so the grid applies a sort, a filter or a search as it does for a
  person: the source sorts, filters and counts, and `rows/3` reads the
  rows it gives.

  Changes broadcast with `Masu.Live` before a call are in the rows it
  reads: the call waits for the LiveView to take them.

  A row is a map of each column's key to its value as the browser gets
  it: numbers and booleans as they are, decimals as strings, dates and
  times in ISO 8601, and for a column with content the text of its cell.
  """

  @compile {:no_warn_undefined, [LazyHTML]}

  import ExUnit.Assertions

  alias Phoenix.LiveViewTest

  @doc """
  The rows of the grid `id`, in its current order.

  Options: `:from` (0), the first row, and `:count` (100), how many
  (at most 500, as the browser asks).
  """
  @spec rows(struct(), String.t(), keyword()) :: [map()]
  def rows(view, id, opts \\ []) do
    keys = view |> config(id) |> Map.fetch!("columns") |> Enum.map(&{&1["key"], &1["html"]})
    from = Keyword.get(opts, :from, 0)
    count = Keyword.get(opts, :count, 100)

    view
    |> event(id, "masu:rows", %{"from" => from, "count" => count})
    |> Map.fetch!("rows")
    |> Enum.map(fn [_id | cells] ->
      keys
      |> Enum.zip(cells)
      |> Map.new(fn
        {{key, true}, [html, _value]} -> {key, text(html)}
        {{key, true}, html} -> {key, text(html)}
        {{key, false}, value} -> {key, value}
      end)
    end)
  end

  @doc "The ids of the rows of the grid `id`, as `rows/3` reads them."
  @spec ids(struct(), String.t(), keyword()) :: [term()]
  def ids(view, id, opts \\ []) do
    view
    |> event(id, "masu:rows", %{
      "from" => Keyword.get(opts, :from, 0),
      "count" => Keyword.get(opts, :count, 100)
    })
    |> Map.fetch!("rows")
    |> Enum.map(&hd/1)
  end

  @doc "How many rows the grid `id` has for its current query."
  @spec total(struct(), String.t()) :: non_neg_integer()
  def total(view, id) do
    view |> event(id, "masu:rows", %{"from" => 0, "count" => 0}) |> Map.fetch!("total")
  end

  @doc """
  The values that the filter menu of the column `key` offers: the values
  of the column among the rows of the query (without the column's own
  filters), each with its count, the most frequent first. `:search`
  narrows them as the menu's search box does.
  """
  @spec values(struct(), String.t(), String.t(), keyword()) :: [{term(), non_neg_integer()}]
  def values(view, id, key, opts \\ []) do
    view
    |> event(id, "masu:values", %{"key" => to_string(key), "search" => Keyword.get(opts, :search)})
    |> Map.fetch!("values")
    |> Enum.map(fn [value, count] -> {value, count} end)
  end

  @doc """
  Edits cells of the grid `id`, as a person typing in them, pasting or
  undoing does: `edits` is a list of `{row_id, key, value}`, the value as
  the browser sends it (a string, or `nil` to empty the cell). The grid
  saves the edits of each row together.

  An edit may be `{row_id, key, value, before}`, with the value the person
  saw: the grid refuses it when the cell's value changed meanwhile, as it
  does for the browser.

  Returns `:ok` when every edit was saved, or `{:error, errors}` with
  `{row_id, key, message}` for each cell that was not.
  """
  @spec edit(struct(), String.t(), [{term(), String.t() | atom(), term()}]) ::
          :ok | {:error, [{term(), String.t(), String.t()}]}
  def edit(view, id, edits) do
    edits =
      Enum.map(edits, fn
        {row, key, value} ->
          %{"id" => row, "key" => to_string(key), "value" => value}

        {row, key, value, before} ->
          %{"id" => row, "key" => to_string(key), "value" => value, "before" => before}
      end)

    case event(view, id, "masu:edit", %{"edits" => edits}) do
      %{"errors" => []} ->
        :ok

      %{"errors" => errors} ->
        {:error, Enum.map(errors, fn [id, key, message | _] -> {id, key, message} end)}
    end
  end

  @doc """
  The place (from 0) of the row `row_id` in the grid's current order, or
  `nil` when its query leaves the row out: where the grid scrolls to
  follow another person to it.
  """
  @spec place(struct(), String.t(), term()) :: non_neg_integer() | nil
  def place(view, id, row_id),
    do: view |> event(id, "masu:locate", %{"id" => row_id}) |> Map.fetch!("index")

  @doc "The labels of the columns of the grid `id`, in order."
  @spec columns(struct(), String.t()) :: [String.t()]
  def columns(view, id) do
    view |> config(id) |> Map.fetch!("columns") |> Enum.map(& &1["label"])
  end

  @doc """
  Sorts the grid `id` as clicks on its headers do: `sorts` is a key, a
  `{key, :asc | :desc}`, or a list of them (the first the most
  important). `[]` takes the order away. Returns the view.
  """
  @spec sort(struct(), String.t(), term()) :: struct()
  def sort(view, id, sorts) do
    sorts =
      sorts
      |> List.wrap()
      |> Enum.map(fn
        {key, direction} -> %{"key" => to_string(key), "dir" => Atom.to_string(direction)}
        key -> %{"key" => to_string(key), "dir" => "asc"}
      end)

    query(view, id, %{"sorts" => sorts})
  end

  @doc """
  Filters the grid `id`: `filters` is a list of `{key, op, value}` (see
  `Masu.Filter` for the operators), which replaces the grid's filters.
  Returns the view.
  """
  @spec filter(struct(), String.t(), [tuple()]) :: struct()
  def filter(view, id, filters) do
    filters =
      Enum.map(filters, fn
        {key, op, value} ->
          %{"key" => to_string(key), "op" => Atom.to_string(op), "value" => value}

        {key, op} ->
          %{"key" => to_string(key), "op" => Atom.to_string(op)}
      end)

    query(view, id, %{"filters" => filters})
  end

  @doc "Searches the grid `id` as its search box does. Returns the view."
  @spec search(struct(), String.t(), String.t()) :: struct()
  def search(view, id, text), do: query(view, id, %{"search" => text})

  @doc """
  The rows of a tree (`Masu.Tree`) in the grid `id`, in order, as maps
  of `:id`, `:level` (0 for a root), `:children` (whether it has any) and
  `:expanded`. Options as `rows/3`.
  """
  @spec nodes(struct(), String.t(), keyword()) :: [map()]
  def nodes(view, id, opts \\ []) do
    view
    |> event(id, "masu:rows", %{
      "from" => Keyword.get(opts, :from, 0),
      "count" => Keyword.get(opts, :count, 100)
    })
    |> Map.fetch!("rows")
    |> Enum.map(fn [row_id | rest] ->
      [level, children, expanded, _position, _size] = List.last(rest)
      %{id: row_id, level: level, children: children, expanded: expanded}
    end)
  end

  @doc """
  Opens the row `row_id` of a tree in the grid `id`, as a click on its
  arrow (or →) does: its children show under it. Returns the view.
  """
  @spec expand(struct(), String.t(), term()) :: struct()
  def expand(view, id, row_id), do: toggle(view, id, %{"id" => row_id, "open" => true})

  @doc "Closes the row `row_id` of a tree in the grid `id`. Returns the view."
  @spec collapse(struct(), String.t(), term()) :: struct()
  def collapse(view, id, row_id), do: toggle(view, id, %{"id" => row_id, "open" => false})

  @doc """
  Opens every row beside `row_id` that has children, as `*` does.
  Returns the view.
  """
  @spec expand_siblings(struct(), String.t(), term()) :: struct()
  def expand_siblings(view, id, row_id),
    do: toggle(view, id, %{"id" => row_id, "open" => true, "siblings" => true})

  defp toggle(view, id, payload) do
    event(view, id, "masu:toggle", payload)
    view
  end

  @doc """
  Opens (or, with `false`, closes) the detail of the row `row_id` in the
  grid `id`: the grid renders its `:detail` slot for the row, which
  `Phoenix.LiveViewTest.render/1` then has. Returns the view.
  """
  @spec detail(struct(), String.t(), term(), boolean()) :: struct()
  def detail(view, id, row_id, open \\ true) do
    event(view, id, "masu:detail", %{"id" => row_id, "open" => open})
    view
  end

  @doc """
  The view of the grid `id`, as its params (see `Masu.View`): what differs
  from the grid's own view. `%{}` is the grid's own view.
  """
  @spec view(struct(), String.t()) :: map()
  def view(view, id), do: view |> config(id) |> Map.fetch!("view")

  @doc """
  Applies a view to the grid `id`, as a link or a saved view does: params
  as `view/2` gives them (`%{}` for the grid's own view). Returns the
  keys of the columns of the parts that no longer apply (see
  `Masu.View.from_params/3`).
  """
  @spec apply_view(struct(), String.t(), map()) :: [String.t()]
  def apply_view(view, id, params) do
    view
    |> event(id, "masu:view", %{"action" => "params", "params" => params})
    |> Map.fetch!("dropped")
  end

  @doc """
  Changes the layout of the grid `id`, as its columns menu, its headers
  and their edges do: any of `order: keys` (every column, in order),
  `hidden: keys`, `pinned: %{key => :start | :end}` and `widths: %{key =>
  pixels}`. Returns the view.
  """
  @spec layout(struct(), String.t(), keyword()) :: struct()
  def layout(view, id, changes) do
    params =
      Map.new(changes, fn
        {:pinned, pins} ->
          {"pinned", Map.new(pins, fn {key, pin} -> {to_string(key), to_string(pin)} end)}

        {:widths, widths} ->
          {"widths", Map.new(widths, fn {key, width} -> {to_string(key), width} end)}

        {key, keys} when key in [:order, :hidden] ->
          {Atom.to_string(key), Enum.map(keys, &to_string/1)}
      end)

    event(view, id, "masu:layout", params)
    view
  end

  defp query(view, id, changes) do
    current = view |> config(id) |> Map.fetch!("query")
    reply = event(view, id, "masu:query", Map.merge(current, changes))

    if error = reply["error"] do
      flunk("the grid #{id} refused the query: #{error}")
    end

    view
  end

  defp event(view, id, name, payload) do
    # A render first: changes broadcast before this call (Masu.Live) reach
    # the grid before the event does.
    LiveViewTest.render(view)

    view
    |> LiveViewTest.element("##{id}")
    |> LiveViewTest.render_hook(name, payload)

    %{proxy: {ref, _topic, _pid}} = view

    receive do
      {^ref, {:reply, reply}} -> reply
    after
      1000 -> flunk("the grid #{id} did not answer #{name}")
    end
  end

  defp config(view, id) do
    view
    |> LiveViewTest.render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("##{id}")
    |> LazyHTML.attribute("data-masu")
    |> case do
      [json | _] -> JSON.decode!(json)
      [] -> flunk("no grid with the id #{inspect(id)}")
    end
  end

  defp text(nil), do: nil
  defp text(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.trim()
end

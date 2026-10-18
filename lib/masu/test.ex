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
  What the grid `id` knows of its count: `{:exact, n}`, or
  `{:at_least, n}` while it does not know it (`count={:none}`, a count
  not in yet, or a source that does not count). `total/2` gives `n`.
  """
  @spec count(struct(), String.t()) :: {:exact | :at_least, non_neg_integer()}
  def count(view, id) do
    reply = event(view, id, "masu:rows", %{"from" => 0, "count" => 0})
    {if(reply["exact"], do: :exact, else: :at_least), reply["total"]}
  end

  @doc """
  Asks the grid `id` for its count, as the person does when they go to
  the end of a grid that does not know it (Ctrl+End): `{:exact, n}`, or
  `{:at_least, n}` from a source that does not know it either.
  """
  @spec ask_count(struct(), String.t()) :: {:exact | :at_least, non_neg_integer()}
  def ask_count(view, id) do
    reply = event(view, id, "masu:count", %{})
    # Counted in a task (`load={:async}`): the count is in the render.
    reply = if reply["pending"], do: config(view, id), else: reply
    {if(reply["exact"], do: :exact, else: :at_least), reply["total"]}
  end

  @doc """
  Goes to a page of the grid `id` (`paging={:pages}`), from 1, as its
  pager does, and gives the ids of its rows.
  """
  @spec page(struct(), String.t(), pos_integer()) :: [term()]
  def page(view, id, page) when is_integer(page) and page >= 1 do
    case event(view, id, "masu:page", %{"page" => page - 1}) do
      %{"rows" => rows} ->
        Enum.map(rows, &hd/1)

      # Its rows come later (`load={:async}`, `on_query`): read them.
      %{"page" => page} ->
        size = view |> config(id) |> Map.fetch!("pageSize")
        ids(view, id, from: page * size, count: size)
    end
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

  Returns `:ok` when every edit was saved, `:async` when the grid's
  `on_update` saves them later (`Masu.Write.async/1`), or `{:error,
  errors}` with `{row_id, key, message}` for each cell that was not.

  Options: `:origin`, what the person did, as `Masu.Write`'s `origin`
  says (`:paste`, `:fill`...); `:test` unless given.
  """
  @spec edit(struct(), String.t(), [tuple()], keyword()) ::
          :ok | :async | {:error, [{term(), String.t(), String.t()}]}
  def edit(view, id, edits, opts \\ []) do
    edits =
      Enum.map(edits, fn
        {row, key, value} ->
          %{"id" => row, "key" => to_string(key), "value" => value}

        {row, key, value, before} ->
          %{"id" => row, "key" => to_string(key), "value" => value, "before" => before}
      end)

    payload = %{"edits" => edits, "origin" => origin(opts)}

    case event(view, id, "masu:edit", payload) do
      %{"errors" => [], "async" => _token} ->
        :async

      %{"errors" => []} ->
        :ok

      %{"errors" => errors} ->
        {:error, Enum.map(errors, fn [id, key, message | _] -> {id, key, message} end)}
    end
  end

  @doc """
  Adds rows to the grid `id`, as the person does with "New row" or a
  paste below the last row: each a map of column keys (or atoms) to
  values, as the browser sends them. The grid saves each through its
  `create`, or its `changeset` of its `struct`.

  Returns `{:ok, ids}` when every row was saved, or `{:error, results}`,
  a result for each row: `{:ok, id}` or `{:error, [{key, message}]}` (a
  key of nil for an error of the row). Options: `:origin`, as `edit/4`.
  """
  @spec add_rows(struct(), String.t(), map() | [map()], keyword()) ::
          {:ok, [term()]} | {:error, [{:ok, term()} | {:error, [{String.t() | nil, String.t()}]}]}
  def add_rows(view, id, rows, opts \\ []) do
    rows = rows |> List.wrap() |> Enum.map(&Map.new(&1, fn {k, v} -> {to_string(k), v} end))

    case event(view, id, "masu:create", %{"rows" => rows, "origin" => origin(opts)}) do
      %{"error" => error} ->
        flunk("the grid #{id} did not add rows: #{error}")

      %{"results" => results} ->
        results =
          Enum.map(results, fn
            %{"id" => id} ->
              {:ok, id}

            %{"errors" => errors} ->
              {:error, Enum.map(errors, fn [key, message] -> {key, message} end)}
          end)

        if Enum.all?(results, &match?({:ok, _}, &1)),
          do: {:ok, Enum.map(results, &elem(&1, 1))},
          else: {:error, results}
    end
  end

  @doc """
  Deletes the rows `ids` of the grid `id`, or, with `:selection`, the
  rows selected (`select/4`, `select_all/3`), as the person does with
  Ctrl+Delete. Returns `{:ok, undo}`, with the token that brings them back
  (`restore_rows/3`; nil when the grid cannot), `:async` when the grid's
  `on_delete` deletes them later, or `{:error, errors, undo}` with
  `{row_id, message}` for each row that was not deleted. Options:
  `:origin`, as `edit/4`.
  """
  @spec delete_rows(struct(), String.t(), [term()] | :selection, keyword()) ::
          {:ok, String.t() | nil} | :async | {:error, [{term(), String.t()}], String.t() | nil}
  def delete_rows(view, id, ids, opts \\ []) do
    payload = if ids == :selection, do: %{"selection" => true}, else: %{"ids" => ids}
    payload = Map.put(payload, "origin", origin(opts))

    case event(view, id, "masu:delete", payload) do
      %{"error" => error} -> flunk("the grid #{id} did not delete: #{error}")
      %{"errors" => [], "async" => _token} -> :async
      %{"errors" => [], "undo" => undo} -> {:ok, undo}
      %{"errors" => errors, "undo" => undo} -> {:error, Enum.map(errors, &List.to_tuple/1), undo}
    end
  end

  @doc """
  Brings back the rows of a delete (its `undo` token, `delete_rows/3`), as
  the person does with Ctrl+Z. Returns `{:ok, ids}`.
  """
  @spec restore_rows(struct(), String.t(), String.t()) :: {:ok, [term()]} | {:error, term()}
  def restore_rows(view, id, undo) do
    case event(view, id, "masu:restore", %{"undo" => undo}) do
      %{"error" => error} -> {:error, error}
      %{"ids" => ids, "errors" => []} -> {:ok, ids}
      %{"errors" => errors} -> {:error, Enum.map(errors, &List.to_tuple/1)}
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
      # A group's row ends with its [key, value, count] after its place.
      place = if Masu.Group.id?(row_id), do: Enum.at(rest, -2), else: List.last(rest)
      [level, children, expanded, _position, _size] = place
      %{id: row_id, level: level, children: children, expanded: expanded}
    end)
  end

  @doc """
  Groups the rows of the grid `id` by columns (`Masu.Group`), as the
  header menu does: `keys`, the first the outermost; `[]` stops
  grouping. Returns the view.
  """
  @spec group(struct(), String.t(), [String.t() | atom()]) :: struct()
  def group(view, id, keys), do: query(view, id, %{"groups" => Enum.map(keys, &to_string/1)})

  @doc """
  The rows of a grouped grid `id` that are groups, in order, as maps of
  `:id` (what `expand/3` takes), `:key`, `:value`, `:count`, `:level`,
  `:expanded` and `:totals` (by column key). Options as `rows/3`.
  """
  @spec groups(struct(), String.t(), keyword()) :: [map()]
  def groups(view, id, opts \\ []) do
    keys = view |> config(id) |> Map.fetch!("columns") |> Enum.map(& &1["key"])

    view
    |> event(id, "masu:rows", %{
      "from" => Keyword.get(opts, :from, 0),
      "count" => Keyword.get(opts, :count, 100)
    })
    |> Map.fetch!("rows")
    |> Enum.flat_map(fn
      [["masu-group" | _] = group_id | rest] ->
        [[level, _children, expanded, _position, _size], [key, value, count]] =
          Enum.take(rest, -2)

        totals = keys |> Enum.zip(rest) |> Enum.reject(&is_nil(elem(&1, 1))) |> Map.new()

        [
          %{
            id: group_id,
            key: key,
            value: value,
            count: count,
            level: level,
            expanded: expanded,
            totals: totals
          }
        ]

      _row ->
        []
    end)
  end

  @doc """
  The totals of the query of the grid `id`, by column key: the row of
  totals at its bottom (`Masu.Group`). `nil` when no column has an
  aggregate.
  """
  @spec totals(struct(), String.t()) :: map() | nil
  def totals(view, id), do: view |> config(id) |> Map.fetch!("totals")

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
  The labels of the actions of your own (`Masu.Action`) that the grid `id`
  offers: on the rows selected (`actions(view, id, :selection)`, while
  rows are selected), on the row `row_id` (`actions(view, id, :row,
  row_id)`: those it shows, available or not), or for the column `key`
  in its header menu (`:header`) or in the menu of its cells (`:cell`).
  """
  @spec actions(struct(), String.t(), :selection) :: [String.t()]
  def actions(view, id, :selection) do
    config = config(view, id)
    count = (config["selection"] || %{})["count"]

    if count in [nil, 0],
      do: [],
      else: Enum.map(config["actions"], & &1["label"])
  end

  @spec actions(struct(), String.t(), :header | :cell | :row, term()) :: [String.t()]
  def actions(view, id, :row, row_id) do
    view
    |> row_items(id, row_id)
    |> Enum.map(fn {action, _disabled, _href} -> action["label"] end)
  end

  def actions(view, id, kind, key) when kind in [:header, :cell] do
    view |> offered(id, kind, to_string(key)) |> Enum.map(& &1["label"])
  end

  @doc """
  Runs the action `label` on the rows selected in the grid `id` (`:action`,
  see `Masu.Action`), as its button in the bar above the grid does, past
  its question (`confirm`). Rows are selected with `select/4` or
  `select_all/3`.

  Returns the action's result: `:ok`, `{:ok, message}`, `{:error,
  message}` or `:async` (see `Masu.Action`), or `{:error, :refused}`
  when the server refuses it: the grid does not offer it (`:if`), or no
  row is selected.
  """
  @spec action(struct(), String.t(), String.t()) ::
          :ok | {:ok, String.t()} | {:error, String.t() | :refused} | :async
  def action(view, id, label) do
    index =
      case Enum.find(config(view, id)["actions"], &(&1["label"] == label)) do
        nil -> -1
        action -> action["id"]
      end

    view
    |> event(id, "masu:action", %{"kind" => "selection", "action" => index, "label" => label})
    |> action_result()
  end

  @doc """
  Runs the action `label` on the row `row_id` of the grid `id`
  (`:row_action`, see `Masu.Action`), as its item in the row's menu
  does, past its question (`confirm`). The grid reads the row from its
  source.

  Returns the action's result, as `action/3` does; for a link, the path
  it goes to, `{:navigate, path}` or `{:patch, path}`; and `{:error,
  :refused}` when the server refuses it: the grid does not offer it, the
  row does not show it, or it is disabled for the row.
  """
  @spec row_action(struct(), String.t(), String.t(), term()) ::
          :ok
          | {:ok, String.t()}
          | {:error, String.t() | :refused}
          | :async
          | {:navigate | :patch, String.t()}
  def row_action(view, id, label, row_id) do
    item =
      view
      |> row_items(id, row_id)
      |> Enum.find(fn {action, _disabled, _href} -> action["label"] == label end)

    case item do
      {%{"link" => link}, false, href} when link in ["navigate", "patch"] ->
        {if(link == "navigate", do: :navigate, else: :patch), href}

      {%{"link" => link}, true, _href} when link in ["navigate", "patch"] ->
        {:error, :refused}

      item ->
        index =
          case item || Enum.find(config(view, id)["rowActions"], &(&1["label"] == label)) do
            {action, _disabled, _href} -> action["id"]
            %{"id" => index} -> index
            nil -> -1
          end

        payload = %{"kind" => "row", "action" => index, "label" => label, "id" => row_id}
        view |> event(id, "masu:action", payload) |> action_result()
    end
  end

  defp action_result(%{"error" => _refused}), do: {:error, :refused}
  defp action_result(%{"failed" => message}), do: {:error, message}
  defp action_result(%{"async" => _token}), do: :async

  defp action_result(%{"ok" => true, "message" => message}) when is_binary(message),
    do: {:ok, message}

  defp action_result(%{"ok" => true}), do: :ok

  # The row actions of a row, as the row carries them: each with whether
  # it is disabled, and its link.
  defp row_items(view, id, row_id) do
    config = config(view, id)
    by_id = Map.new(config["rowActions"], &{&1["id"], &1})

    index =
      place(view, id, row_id) ||
        flunk("the grid #{id} has no row #{inspect(row_id)} in its query")

    row =
      case event(view, id, "masu:rows", %{"from" => index, "count" => 1}) do
        %{"rows" => [row | _]} -> row
        _other -> flunk("the grid #{id} sent no row #{inspect(row_id)}")
      end

    at = length(config["columns"]) + 1 + if(config["locks"], do: 1, else: 0)

    for [action_id, disabled, href] <- Enum.at(row, at) || [],
        do: {Map.fetch!(by_id, action_id), disabled, href}
  end

  @doc """
  Runs the item `label` of the header menu of the column `key` of the
  grid `id`, as a click on it does: its function, its event to the
  LiveView, or its panel, which `Phoenix.LiveViewTest.render/1` then has.
  An item that is only a JS command runs in the browser, not here.
  Returns the view.
  """
  @spec header_action(struct(), String.t(), String.t(), String.t() | atom()) :: struct()
  def header_action(view, id, label, key) do
    run_action(view, id, :header, label, to_string(key), %{})
  end

  @doc """
  Runs the item `label` of the menu of the cell of the row `row_id` and
  the column `key` of the grid `id`, as `header_action/4` does. The grid
  reads the row and the value of the cell from its source.

  Options: `:range`, `{ids, keys}`: a range of cells selected, its rows'
  ids and its columns' keys, that the cell is in.
  """
  @spec cell_action(struct(), String.t(), String.t(), String.t() | atom(), term(), keyword()) ::
          struct()
  def cell_action(view, id, label, key, row_id, opts \\ []) do
    payload =
      case Keyword.get(opts, :range) do
        nil ->
          %{"id" => row_id}

        {ids, keys} ->
          %{"id" => row_id, "range" => %{"ids" => ids, "keys" => Enum.map(keys, &to_string/1)}}
      end

    run_action(view, id, :cell, label, to_string(key), payload)
  end

  @doc "Closes the panel of an item of the grid `id`, as Escape does. Returns the view."
  @spec close_panel(struct(), String.t()) :: struct()
  def close_panel(view, id) do
    event(view, id, "masu:action_panel", %{"open" => false})
    view
  end

  defp run_action(view, id, kind, label, key, payload) do
    action =
      view
      |> offered(id, kind, key)
      |> Enum.find(&(&1["label"] == label)) ||
        flunk(
          "the grid #{id} has no #{kind} item #{inspect(label)} for the column #{inspect(key)}"
        )

    unless action["server"] or action["panel"] do
      flunk("the #{kind} item #{inspect(label)} of the grid #{id} runs only in the browser (js)")
    end

    payload =
      Map.merge(payload, %{
        "kind" => Atom.to_string(kind),
        "action" => action["id"],
        "label" => label,
        "key" => key
      })

    case event(view, id, "masu:action", payload) do
      %{"error" => error} ->
        flunk("the grid #{id} refused the #{kind} item #{inspect(label)}: #{error}")

      _reply ->
        view
    end
  end

  defp offered(view, id, kind, key) do
    field = if kind == :header, do: "headerActions", else: "cellActions"

    view
    |> config(id)
    |> Map.fetch!("columns")
    |> Enum.find(&(&1["key"] == key))
    |> case do
      nil -> flunk("the grid #{id} shows no column #{inspect(key)}")
      column -> column[field]
    end
  end

  @doc """
  Selects rows of the grid `id` (`selectable`) by their ids, as their
  boxes do, or, with `false`, takes them out. Returns the view.
  """
  @spec select(struct(), String.t(), [term()], boolean()) :: struct()
  def select(view, id, ids, on \\ true) do
    event(view, id, "masu:select", %{"ids" => ids, "on" => on})
    view
  end

  @doc "Selects every row of the query of the grid `id` (or, with `false`, none). Returns the view."
  @spec select_all(struct(), String.t(), boolean()) :: struct()
  def select_all(view, id, on \\ true) do
    event(view, id, "masu:select", %{"all" => on})
    view
  end

  @doc """
  The selection of the grid `id`: `%{all: boolean, ids: [...], except:
  [...], count: n}`.
  """
  @spec selection(struct(), String.t()) :: map()
  def selection(view, id) do
    selection = view |> config(id) |> Map.fetch!("selection")

    %{
      all: selection["all"],
      ids: selection["ids"],
      except: selection["except"],
      count: selection["count"]
    }
  end

  @doc """
  Exports the grid `id` as its Export menu does (`Masu.Export`), and
  downloads the file from the link the browser gets, through the
  endpoint and the router's export route (`Masu.Router`): `{name,
  binary}`. A `conn` (`Phoenix.ConnTest.build_conn/0`, with what the
  route's pipeline wants of it, a signed-in user) is given with `:conn`.
  """
  @spec export(struct(), String.t(), :csv | :xlsx, keyword()) :: {String.t(), binary()}
  def export(view, id, format, opts \\ []) do
    url = export_url(view, id, format)
    conn = Keyword.get_lazy(opts, :conn, &Phoenix.ConnTest.build_conn/0)
    conn = Phoenix.ConnTest.dispatch(conn, view.endpoint, :get, url, nil)

    if conn.status != 200,
      do: flunk("the export of the grid #{id} answered #{conn.status}: #{conn.resp_body}")

    [disposition] = Plug.Conn.get_resp_header(conn, "content-disposition")
    [_all, name] = Regex.run(~r/filename="([^"]*)"/, disposition)
    {name, conn.resp_body}
  end

  @doc """
  The link the Export menu of the grid `id` gives the browser, for a
  test of the route itself: that it wants a signed-in user, say.
  """
  @spec export_url(struct(), String.t(), :csv | :xlsx) :: String.t()
  def export_url(view, id, format) do
    reply = event(view, id, "masu:export", %{"format" => Atom.to_string(format)})
    reply["url"] || flunk("the grid #{id} did not export: #{reply["error"]}")
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

  defp origin(opts), do: opts |> Keyword.get(:origin, :test) |> Atom.to_string()

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

    reply =
      receive do
        {^ref, {:reply, reply}} -> reply
      after
        1000 -> flunk("the grid #{id} did not answer #{name}")
      end

    if reply["pending"], do: pending(view, id, name, reply), else: reply
  end

  # An answer whose rows come later (`load={:async}`): the read in a task
  # is waited for, as the browser waits. A block of rows comes in a
  # `masu:block` event; a query or a count, with the render after it.
  defp pending(view, id, "masu:rows", %{"from" => from}) do
    LiveViewTest.render_async(view, 5000)
    %{proxy: {ref, _topic, _pid}} = view

    receive do
      {^ref, {:push_event, "masu:block", %{"id" => ^id, "block" => %{"from" => ^from} = block}}} ->
        if block["failed"],
          do: flunk("the grid #{id} could not read its rows: #{error(view, id)}")

        block
    after
      5000 -> flunk("the grid #{id} sent no rows from #{from}")
    end
  end

  defp pending(view, id, _name, reply) do
    LiveViewTest.render_async(view, 5000)
    if message = error(view, id), do: flunk("the grid #{id} failed: #{message}")
    reply
  end

  defp error(view, id) do
    view
    |> LiveViewTest.render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("##{id}-state .masu-error-text")
    |> LazyHTML.text()
    |> case do
      "" -> nil
      text -> text
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

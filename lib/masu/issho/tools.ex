if Code.ensure_loaded?(Issho.Tool) do
  defmodule Masu.Issho.Tools.Grid do
    @moduledoc false
    # What the tools share: the grid's columns and rows as a model reads
    # them, and the errors of a write in words.

    alias Masu.{Column, Filter, Sheet}

    def columns(sheet) do
      for %Column{} = column <- Sheet.columns(sheet) do
        %{
          "key" => column.key,
          "label" => column.label,
          "type" => to_string(column.type),
          "editable" => column.editable == true,
          "values" => column.values && Enum.map(column.values, &value/1)
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end)
      end
    end

    defp value({label, value}),
      do: %{"label" => to_string(label), "value" => Masu.Value.to_wire(value)}

    defp value(value), do: Masu.Value.to_wire(value)

    def sorts(nil), do: []

    def sorts(sorts),
      do: Enum.map(sorts, &{&1.key, if(&1[:dir] == "desc", do: :desc, else: :asc)})

    @ops Map.new(Filter.ops(), &{Atom.to_string(&1), &1})

    def filters(nil), do: {:ok, []}

    def filters(filters) do
      Enum.reduce_while(filters, {:ok, []}, fn filter, {:ok, acc} ->
        case Map.fetch(@ops, filter.op) do
          {:ok, op} -> {:cont, {:ok, acc ++ [{filter.key, op, filter[:value]}]}}
          :error -> {:halt, {:error, "There is no filter #{inspect(filter.op)}."}}
        end
      end)
    end

    def op_names, do: Map.keys(@ops)

    # A grid's errors, `[id, key, message]` or `[id, key, message, now]`.
    def errors(errors) do
      Enum.map(errors, fn
        [id, key, message, now] -> %{"row" => id, "key" => key, "error" => message, "now" => now}
        [id, key, message] -> %{"row" => id, "key" => key, "error" => message}
        [id, message] -> %{"row" => id, "error" => message}
      end)
    end

    # Who holds a lock on a cell, of the others.
    def holder(grid, participant, self_key, id, key) do
      place = Masu.Issho.place(grid.grid, {id, key})

      Enum.find_value(Issho.Participant.locks(participant), fn
        {^place, holder} when holder != self_key -> holder
        _other -> nil
      end)
    end

    def name(participant, key) do
      case Issho.Participant.people(participant) do
        %{^key => %{"person" => %{"name" => name}}} when is_binary(name) -> name
        _people -> "Someone"
      end
    end
  end

  defmodule Masu.Issho.Tools.Read do
    @moduledoc false
    use Issho.Tool,
      name: "read_grid",
      description: """
      Reads rows of a grid (a table), as a person sees them: its columns
      (key, label, type, whether it edits, an enum's values) and its rows,
      each its cells by column key and its "id". In an order, filtered and
      searched as a person would; from `offset`, at most `limit` rows (50
      unless given). `total` is how many rows the query has.
      """,
      annotations: [read_only: true, idempotent: true]

    arg(:grid, :string, required: true, description: "The grid, as room/grid: notebook:42/tasks")

    arg(
      :sort,
      {:array,
       {:object, [{:key, :string, required: true}, {:dir, {:enum, ["asc", "desc"]}, []}]}},
      description: "The order: column keys, each asc or desc"
    )

    arg(
      :filters,
      {:array,
       {:object,
        [
          {:key, :string, required: true},
          {:op, :string, required: true},
          {:value, :any, []}
        ]}},
      description:
        "Filters, all of which a row passes: a column key, an op (eq, not_eq, contains, starts_with, gt, gte, lt, lte, between, in, is_nil, not_nil...) and a value"
    )

    arg(:search, :string, description: "Text to find in the searchable columns")
    arg(:offset, :integer, min: 0)
    arg(:limit, :integer, min: 1, max: 500)

    alias Issho.Tool.Context
    alias Masu.Issho.Tools.Grid
    alias Masu.Sheet

    @impl true
    def call(args, ctx) do
      with {:ok, grid} <- Masu.Issho.open(ctx, args.grid),
           {:ok, filters} <- Grid.filters(args[:filters]),
           {:ok, %{rows: rows, total: total}} <-
             Sheet.rows(grid.sheet,
               sort: Grid.sorts(args[:sort]),
               filters: filters,
               search: args[:search],
               offset: args[:offset] || 0,
               limit: args[:limit] || 50
             ) do
        {:ok,
         %{
           "grid" => args.grid,
           "columns" => Grid.columns(grid.sheet),
           "rows" => Enum.map(rows, &Sheet.to_map(grid.sheet, &1)),
           "total" => total(total),
           "offset" => args[:offset] || 0,
           "can" => grid.sheet |> Sheet.can() |> Map.new(fn {k, v} -> {to_string(k), v} end)
         }}
      else
        {:error, reason} -> Context.error(reason)
      end
    end

    defp total({:at_least, n}), do: "at least #{n}"
    defp total(n), do: n
  end

  defmodule Masu.Issho.Tools.Select do
    @moduledoc false
    use Issho.Tool,
      name: "select_cells",
      description: """
      Shows the people where you are in a grid: a cell (`row` and `key`),
      or a range of rows and columns (`rows` and `keys`). Each person sees
      it wherever the rows are in their own order, and not at all when
      their filters leave the rows out.
      """,
      annotations: [idempotent: true]

    arg(:grid, :string, required: true)
    arg(:row, :any, description: "A row's id")
    arg(:key, :string, description: "A column's key")
    arg(:rows, {:array, :any}, description: "The ids of the rows of a range")
    arg(:keys, {:array, :string}, description: "The keys of the columns of a range")

    alias Issho.Participant
    alias Issho.Tool.Context

    @impl true
    def call(args, ctx) do
      with {:ok, place} <- place(args),
           {:ok, grid} <- Masu.Issho.open(ctx, args.grid),
           :ok <- Participant.place(grid.participant, Masu.Issho.place(args.grid, place)) do
        {:ok, "Selected."}
      else
        {:error, reason} -> Context.error(reason)
      end
    end

    defp place(%{rows: [_ | _] = rows, keys: [_ | _] = keys}), do: {:ok, {rows, keys}}
    defp place(%{row: row, key: key}) when not is_nil(row), do: {:ok, {row, key}}
    defp place(_args), do: {:error, "Give a cell (row and key), or a range (rows and keys)."}
  end

  defmodule Masu.Issho.Tools.Edit do
    @moduledoc false
    use Issho.Tool,
      name: "edit_cells",
      description: """
      Edits cells of a grid, as a person types in them: the people see you
      on each cell as you edit it, and the rows change in your color. Each
      edit is a row's id, a column's key and the value; give `before`, the
      value you read, and the edit is refused if someone changed the cell
      since. The grid checks each value as it checks a person's: an error
      says why, and a cell changed meanwhile gives its value now.
      """,
      annotations: [destructive: true]

    arg(:grid, :string, required: true)

    arg(
      :edits,
      {:array,
       {:object,
        [
          {:row, :any, required: true},
          {:key, :string, required: true},
          {:value, :any, []},
          {:before, :any, []}
        ]}},
      required: true
    )

    alias Issho.Participant
    alias Issho.Tool.Context
    alias Masu.Issho.Tools.Grid
    alias Masu.Sheet

    # More cells than this go at once, as a paste, without the pace.
    @paced 20

    @impl true
    def call(%{edits: edits} = args, ctx) do
      with {:ok, grid} <- Masu.Issho.open(ctx, args.grid),
           :ok <- Participant.authorize(grid.participant, :write) do
        edits = Enum.map(edits, &edit/1)

        {saved, errors} =
          if length(edits) <= @paced,
            do: paced(grid, edits),
            else: at_once(grid, edits)

        result(saved, errors)
      else
        {:error, reason} -> Context.error(reason)
      end
    end

    defp edit(edit) do
      %{"id" => edit.row, "key" => edit.key, "value" => edit[:value]}
      |> then(&if Map.has_key?(edit, :before), do: Map.put(&1, "before", edit.before), else: &1)
    end

    # Cell by cell: on it, holding it while it saves.
    defp paced(grid, edits) do
      self_key = Context.key(grid.ctx)

      Enum.reduce(edits, {0, []}, fn edit, {saved, errors} ->
        {more, refused} = edit_cell(grid, self_key, edit)
        {saved + more, errors ++ refused}
      end)
    end

    defp edit_cell(grid, self_key, %{"id" => id, "key" => key} = edit) do
      place = Masu.Issho.place(grid.grid, {id, key})
      _ = Participant.place(grid.participant, place)

      case Grid.holder(grid, grid.participant, self_key, id, key) do
        nil ->
          locked? = Participant.lock(grid.participant, [place]) == :ok
          result = write(grid, [edit], :edit)
          if locked?, do: Participant.lock(grid.participant, [])
          pause()
          {length(result.saved), result.errors}

        holder ->
          {0, [[id, key, "#{Grid.name(grid.participant, holder)} is editing this cell."]]}
      end
    end

    defp at_once(grid, edits) do
      ids = edits |> Enum.map(& &1["id"]) |> Enum.uniq()
      keys = edits |> Enum.map(& &1["key"]) |> Enum.uniq()
      _ = Participant.place(grid.participant, Masu.Issho.place(grid.grid, {ids, keys}))
      result = write(grid, edits, :paste)
      {length(result.saved), result.errors}
    end

    defp write(grid, edits, origin),
      do: Sheet.update(grid.sheet, edits, scope: grid.scope, user: grid.user, origin: origin)

    defp pause do
      case Masu.Issho.pace() do
        0 -> :ok
        ms -> Process.sleep(ms)
      end
    end

    defp result(0, [_ | _] = errors),
      do: {:error, "Nothing saved: " <> Enum.map_join(Grid.errors(errors), " ", &describe/1)}

    defp result(saved, errors), do: {:ok, %{"saved" => saved, "errors" => Grid.errors(errors)}}

    defp describe(%{"row" => row, "key" => key, "error" => error} = e),
      do: "Row #{inspect(row)}, #{key}: #{error}" <> now(e)

    defp now(%{"now" => now}), do: " (now #{inspect(now)})"
    defp now(_error), do: ""
  end

  defmodule Masu.Issho.Tools.Add do
    @moduledoc false
    use Issho.Tool,
      name: "add_rows",
      description: """
      Adds rows to a grid: each row its cells' values by column key. The
      grid checks each as it checks a person's new row; gives each new
      row's id, or its errors.
      """,
      annotations: [destructive: false]

    arg(:grid, :string, required: true)
    arg(:rows, {:array, :any}, required: true, description: "Each a map of column key to value")

    alias Issho.Participant
    alias Issho.Tool.Context
    alias Masu.Sheet

    @impl true
    def call(%{rows: rows} = args, ctx) do
      with true <-
             Enum.all?(rows, &is_map/1) || {:error, "Each row is a map of column key to value."},
           {:ok, grid} <- Masu.Issho.open(ctx, args.grid),
           :ok <- Participant.authorize(grid.participant, :write),
           true <- Sheet.can(grid.sheet).create || {:error, "This grid does not add rows."} do
        drafts = Enum.map(rows, &Map.new(&1, fn {key, value} -> {to_string(key), value} end))
        results = Sheet.create(grid.sheet, drafts, scope: grid.scope, user: grid.user)

        ids = for {:ok, row} <- results, do: Sheet.id(grid.sheet, row)

        with [first | _] <- ids,
             [key | _] <- Enum.map(Sheet.columns(grid.sheet), & &1.key),
             do: Participant.place(grid.participant, Masu.Issho.place(args.grid, {first, key}))

        {:ok,
         %{
           "rows" =>
             Enum.map(results, fn
               {:ok, row} ->
                 %{"id" => Sheet.id(grid.sheet, row)}

               {:error, errors} ->
                 %{
                   "errors" =>
                     Enum.map(errors, fn [key, message] -> %{"key" => key, "error" => message} end)
                 }
             end)
         }}
      else
        {:error, reason} -> Context.error(reason)
      end
    end
  end

  defmodule Masu.Issho.Tools.Delete do
    @moduledoc false
    use Issho.Tool,
      name: "delete_rows",
      description: "Deletes rows of a grid, by their ids, as a person would.",
      annotations: [destructive: true]

    arg(:grid, :string, required: true)
    arg(:rows, {:array, :any}, required: true, description: "The rows' ids")

    alias Issho.Participant
    alias Issho.Tool.Context
    alias Masu.Issho.Tools.Grid
    alias Masu.Sheet

    @impl true
    def call(%{rows: ids} = args, ctx) do
      with {:ok, grid} <- Masu.Issho.open(ctx, args.grid),
           :ok <- Participant.authorize(grid.participant, :write) do
        keys = Enum.map(Sheet.columns(grid.sheet), & &1.key)
        _ = Participant.place(grid.participant, Masu.Issho.place(args.grid, {ids, keys}))
        result = Sheet.delete(grid.sheet, ids, scope: grid.scope, user: grid.user)
        _ = Participant.place(grid.participant, nil)

        case result do
          %{deleted: [], errors: [_ | _] = errors} ->
            {:error,
             Enum.map_join(Grid.errors(errors), " ", &"Row #{inspect(&1["row"])}: #{&1["error"]}")}

          %{deleted: deleted, errors: errors} ->
            {:ok, %{"deleted" => length(deleted), "errors" => Grid.errors(errors)}}
        end
      else
        {:error, reason} -> Context.error(reason)
      end
    end
  end
end

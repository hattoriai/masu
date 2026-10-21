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

    # A person's cell or range in the grid, from their place: the cells as
    # [id, key] pairs, at most 500 rows.
    def selection_of(grid, who) do
      with {:ok, at, name} <- Issho.Tools.place_of(grid.participant, grid.grid, who),
           {:ok, cells} <- cells(at, name),
           do: {:ok, name, at, cells}
    end

    defp cells(%{"range" => %{"rows" => [_ | _] = rows, "keys" => [_ | _] = keys}}, _name),
      do: {:ok, for(id <- Enum.take(rows, 500), key <- keys, do: [id, key])}

    defp cells(%{"cell" => [id, key]}, _name), do: {:ok, [[id, key]]}
    defp cells(_at, name), do: {:error, "#{name} has no cell selected in the grid."}

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

    arg :grid, :string, required: true, description: "The grid, as room/grid: notebook:42/tasks"

    arg :sort,
        {:array,
         {:object, [{:key, :string, required: true}, {:dir, {:enum, ["asc", "desc"]}, []}]}},
        description: "The order: column keys, each asc or desc"

    arg :filters,
        {:array,
         {:object,
          [{:key, :string, required: true}, {:op, :string, required: true}, {:value, :any, []}]}},
        description:
          "Filters, all of which a row passes: a column key, an op (eq, not_eq, contains, starts_with, gt, gte, lt, lte, between, in, is_nil, not_nil...) and a value"

    arg :search, :string, description: "Text to find in the searchable columns"
    arg :offset, :integer, min: 0
    arg :limit, :integer, min: 1, max: 500

    arg :of, :string,
      description: "A person in the room, by name: the cells they have selected, and their rows"

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
        %{
          "grid" => args.grid,
          "columns" => Grid.columns(grid.sheet),
          "rows" => Enum.map(rows, &Sheet.to_map(grid.sheet, &1)),
          "total" => total(total),
          "offset" => args[:offset] || 0,
          "can" => grid.sheet |> Sheet.can() |> Map.new(fn {k, v} -> {to_string(k), v} end)
        }
        |> selected(grid, args[:of])
      else
        {:error, reason} -> Context.error(reason)
      end
    end

    defp selected(read, _grid, nil), do: {:ok, read}

    defp selected(read, grid, who) do
      with {:ok, name, at, cells} <- Grid.selection_of(grid, who) do
        ids = cells |> Enum.map(&hd/1) |> Enum.uniq()
        rows = grid.sheet |> Sheet.fetch(ids) |> Enum.map(&Sheet.to_map(grid.sheet, &1))
        {:ok, Map.put(read, "of", Map.merge(%{"name" => name, "rows" => rows}, at))}
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

    arg :grid, :string, required: true
    arg :row, :any, description: "A row's id"
    arg :key, :string, description: "A column's key"
    arg :rows, {:array, :any}, description: "The ids of the rows of a range"
    arg :keys, {:array, :string}, description: "The keys of the columns of a range"

    alias Issho.Participant
    alias Issho.Tool.Context

    @impl true
    def call(args, ctx) do
      with {:ok, place} <- place(args),
           {:ok, grid} <- Masu.Issho.open(ctx, args.grid),
           :ok <- Masu.Issho.go(grid, place) do
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
      since. Or `of`, a person in the room, and a `value`: each cell they
      have selected takes it. The grid checks each value as it checks a person's: an error
      says why, and a cell changed meanwhile gives its value now.
      """,
      annotations: [destructive: true]

    arg :grid, :string, required: true

    arg :edits,
        {:array,
         {:object,
          [
            {:row, :any, required: true},
            {:key, :string, required: true},
            {:value, :any, []},
            {:before, :any, []}
          ]}},
        description: "The cells, each a row's id, a column's key and the value"

    arg :of, :string,
      description: "A person in the room, by name: each cell they have selected takes `value`"

    arg :value, :any, description: "With `of`: the value of each of their cells"

    alias Issho.Participant
    alias Issho.Tool.Context
    alias Masu.Issho.Tools.Grid
    alias Masu.Sheet

    # More cells than this go at once, as a paste, without the pace.
    @paced 20

    @impl true
    def call(args, ctx) do
      with {:ok, grid} <- Masu.Issho.open(ctx, args.grid),
           :ok <- Participant.authorize(grid.participant, :write),
           {:ok, edits} <- edits(grid, args) do
        {saved, errors} =
          if length(edits) <= @paced,
            do: paced(grid, edits),
            else: at_once(grid, edits)

        result(saved, errors)
      else
        {:error, reason} -> Context.error(reason)
      end
    end

    defp edits(_grid, %{edits: [_ | _] = edits}), do: {:ok, Enum.map(edits, &edit/1)}

    defp edits(grid, %{of: who} = args) do
      with {:ok, _name, _at, cells} <- Grid.selection_of(grid, who),
           do:
             {:ok,
              for([id, key] <- cells, do: %{"id" => id, "key" => key, "value" => args[:value]})}
    end

    defp edits(_grid, _args), do: {:error, "Give the edits, or `of` a person and a `value`."}

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

    # To the cell, typing in it (the others see it, and edit it meanwhile
    # no more than a person's), then the value saved.
    defp edit_cell(grid, self_key, %{"id" => id, "key" => key} = edit) do
      place = Masu.Issho.place(grid.grid, {id, key})
      :ok = Masu.Issho.go(grid, {id, key})

      case Grid.holder(grid, grid.participant, self_key, id, key) do
        nil ->
          locked? = Participant.lock(grid.participant, [place]) == :ok
          :ok = Masu.Issho.pause(grid, {id, key}, Masu.Issho.pace())
          result = write(grid, [edit], :edit)
          if locked?, do: Participant.lock(grid.participant, [])
          {length(result.saved), result.errors}

        holder ->
          {0, [[id, key, "#{Grid.name(grid.participant, holder)} is editing this cell."]]}
      end
    end

    defp at_once(grid, edits) do
      ids = edits |> Enum.map(& &1["id"]) |> Enum.uniq()
      keys = edits |> Enum.map(& &1["key"]) |> Enum.uniq()
      :ok = Masu.Issho.go(grid, {ids, keys})
      result = write(grid, edits, :paste)
      {length(result.saved), result.errors}
    end

    defp write(grid, edits, origin),
      do: Sheet.update(grid.sheet, edits, scope: grid.scope, user: grid.user, origin: origin)

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

    arg :grid, :string, required: true
    arg :rows, {:array, :any}, required: true, description: "Each a map of column key to value"

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
             do: Masu.Issho.go(grid, {first, key})

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

    arg :grid, :string, required: true
    arg :rows, {:array, :any}, required: true, description: "The rows' ids"

    alias Issho.Participant
    alias Issho.Tool.Context
    alias Masu.Issho.Tools.Grid
    alias Masu.Sheet

    @impl true
    def call(%{rows: ids} = args, ctx) do
      with {:ok, grid} <- Masu.Issho.open(ctx, args.grid),
           :ok <- Participant.authorize(grid.participant, :write) do
        keys = Enum.map(Sheet.columns(grid.sheet), & &1.key)
        :ok = Masu.Issho.go(grid, {ids, keys})
        :ok = Masu.Issho.pause(grid, {ids, keys}, if(Masu.Issho.travel?(), do: 300, else: 0))
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

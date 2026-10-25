if Code.ensure_loaded?(Issho.Place) do
  defmodule Masu.Issho.Place do
    @moduledoc """
    A place in a Masu grid, in the grid's own terms (rows by their ids,
    columns by their keys, never screen pixels, as each person has their
    own order, filters and scroll): where a person is, where their
    pointer is, where an agent goes (`Issho.Motion`), what an app keeps
    of them. Its format is part of Masu's public API, and only grows.

        %{"cell" => [row_id, key]}                         # a cell
        %{"range" => %{"rows" => [row_id, ...], "keys" => [key, ...]}}
        %{"cell" => [row_id, key], "range" => %{...}}      # a range, from a cell
        %{"cell" => [row_id, key], "x" => 0.5, "y" => 0.5} # a pointer in a cell

    A row id is a string or an integer, as the grid sends its rows; `x`
    and `y` are where in the cell, from 0 to 1. A range names at most 500
    rows. In the room, it is the `"at"` of a place of the grid's document:
    `%{"doc" => "notebook:42/tasks", "at" => %{"cell" => [7, "status"]}}`.

    The grid gives the places it sets a `"label"` too, what is selected in
    a few words for people and agents (`Issho.Place`): a cell's column and
    its row's first cell, `Status of “Forge the blade”`; a range's size,
    `Status, 3 rows` or `3 rows × 2 columns`. Only words: `"at"` locates
    the place.
    """
    @behaviour Issho.Place

    @impl true
    def validate(nil), do: :ok

    def validate(%{} = place) when map_size(place) > 0 do
      if Enum.all?(place, &part?/1), do: :ok, else: {:error, :invalid_place}
    end

    def validate(_other), do: {:error, :invalid_place}

    defp part?({"cell", [id, key]}), do: id?(id) and key?(key)

    defp part?({"range", %{"rows" => rows, "keys" => keys}})
         when is_list(rows) and is_list(keys) and length(rows) <= 500,
         do: Enum.all?(rows, &id?/1) and Enum.all?(keys, &key?/1)

    defp part?({coordinate, value}) when coordinate in ["x", "y"],
      do: is_number(value) and value >= 0 and value <= 1

    defp part?(_other), do: false

    @doc false
    # A place's words (`"label"`), of its `"at"`, the grid's columns and
    # the name of its row (the first cell of the row, or nil) when it is
    # in one row; nil for a place of no cell.
    @spec label(map(), [Masu.Column.t()], String.t() | nil) :: String.t() | nil
    def label(
          %{"range" => %{"rows" => [_ | _] = rows, "keys" => [_ | _] = keys}} = at,
          columns,
          name
        ) do
      if Enum.all?(keys, &is_binary/1),
        do: range_label(rows, keys, columns, name),
        else: label(Map.delete(at, "range"), columns, name)
    end

    def label(%{"cell" => [_id, key]}, columns, name) when is_binary(key),
      do: column(columns, key) <> of(name)

    def label(_at, _columns, _name), do: nil

    defp range_label(rows, keys, columns, name) do
      case {Enum.uniq(rows), Enum.uniq(keys)} do
        {[_id], [key]} -> column(columns, key) <> of(name)
        {[_id], keys} -> "#{length(keys)} columns" <> of(name)
        {rows, [key]} -> "#{column(columns, key)}, #{length(rows)} rows"
        {rows, keys} -> "#{length(rows)} rows × #{length(keys)} columns"
      end
    end

    @doc false
    # The row a label names: the place's one row, or nil.
    @spec row(map()) :: term()
    def row(%{"range" => %{"rows" => [_ | _] = rows, "keys" => [_ | _]}}) do
      case Enum.uniq(rows) do
        [id] -> id
        _rows -> nil
      end
    end

    def row(%{"cell" => [id, _key]}), do: id
    def row(_at), do: nil

    @doc false
    # A row's name in a label: its first cell, as text, short.
    @spec name([Masu.Column.t()], term()) :: String.t() | nil
    def name([first | _columns], row) do
      case Masu.Column.wire(first, row) do
        text when is_binary(text) -> short(String.trim(text))
        number when is_number(number) -> to_string(number)
        _other -> nil
      end
    end

    def name(_columns, _row), do: nil

    defp column(columns, key) do
      case Enum.find(columns, &(&1.key == key)) do
        %{label: label} when is_binary(label) and label != "" -> label
        _column -> key
      end
    end

    defp of(nil), do: ""
    defp of(name), do: " of “" <> name <> "”"

    # Issho cuts a label to 60 characters: the name is cut first, so that
    # the column stays.
    defp short(""), do: nil

    defp short(text) do
      if String.length(text) > 32, do: String.slice(text, 0, 31) <> "…", else: text
    end

    defp id?(id), do: (is_binary(id) and byte_size(id) <= 200) or is_integer(id)
    defp key?(key), do: is_binary(key) and byte_size(key) <= 200
  end
end

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

    defp id?(id), do: (is_binary(id) and byte_size(id) <= 200) or is_integer(id)
    defp key?(key), do: is_binary(key) and byte_size(key) <= 200
  end
end

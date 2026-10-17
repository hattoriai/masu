defmodule Masu.Sort do
  @moduledoc """
  An order of a grid's rows: a column, and a direction.

  A grid's query holds a list of them, the first the most important: a
  click on a column's header sorts by that column alone, and a click with
  Shift adds it to the list.
  """

  @type direction :: :asc | :desc
  @type t :: %__MODULE__{key: String.t(), direction: direction()}

  @enforce_keys [:key]
  defstruct [:key, direction: :asc]

  @doc "A sort by the column with `key`, ascending unless `direction` says."
  @spec new(String.t() | atom(), direction()) :: t()
  def new(key, direction \\ :asc) when direction in [:asc, :desc],
    do: %__MODULE__{key: to_string(key), direction: direction}

  @doc false
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{key: key, direction: direction}),
    do: %{"key" => key, "dir" => Atom.to_string(direction)}
end

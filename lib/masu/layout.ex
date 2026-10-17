defmodule Masu.Layout do
  @moduledoc """
  How a grid lays out its columns: their order, which are hidden, which
  are pinned to the start or the end, and their widths.

  A grid starts with the layout of its `:col` slots (their order, and
  their `hidden`, `pinned` and `width` attributes), and changes it as the
  person moves, hides, pins and resizes columns. With the query
  (`Masu.Query`), it is the person's view (`Masu.View`).

  The columns a grid shows are `columns/2` of its layout: the pinned to
  the start first, then the others, then the pinned to the end, each in
  the layout's order, without the hidden ones.
  """

  alias Masu.Column

  @type pin :: :start | :end

  @type t :: %__MODULE__{
          order: [String.t()],
          hidden: [String.t()],
          pinned: %{String.t() => pin()},
          widths: %{String.t() => pos_integer()}
        }

  defstruct order: [], hidden: [], pinned: %{}, widths: %{}

  @max_width 2_000

  @doc "The layout of the columns as declared."
  @spec new([Column.t()]) :: t()
  def new(columns) do
    %__MODULE__{
      order: Enum.map(columns, & &1.key),
      hidden: for(%Column{hidden: true, key: key} <- columns, do: key),
      pinned:
        for(%Column{pinned: pin, key: key} <- columns, pin != nil, into: %{}, do: {key, pin}),
      widths: %{}
    }
  end

  @doc """
  The layout made to fit the columns: the keys of columns that no longer
  exist are left out, and a column that the layout does not name (one
  added since it was saved) takes its declared place, as declared.
  """
  @spec fit(t(), [Column.t()]) :: t()
  def fit(%__MODULE__{} = layout, columns) do
    keys = Enum.map(columns, & &1.key)
    known = MapSet.new(keys)
    named = MapSet.new(layout.order)
    declared = new(columns)

    order =
      Enum.reduce(Enum.with_index(keys), Enum.filter(layout.order, &(&1 in known)), fn
        {key, index}, order ->
          if MapSet.member?(named, key), do: order, else: List.insert_at(order, index, key)
      end)
      |> Enum.uniq()

    new_keys = Enum.reject(keys, &MapSet.member?(named, &1))

    %__MODULE__{
      order: order,
      hidden:
        Enum.uniq(
          Enum.filter(layout.hidden, &(&1 in known)) ++
            Enum.filter(declared.hidden, &(&1 in new_keys))
        ),
      pinned:
        layout.pinned
        |> Map.take(keys)
        |> Map.merge(Map.take(declared.pinned, new_keys)),
      widths:
        for(
          {key, width} <- layout.widths,
          key in known,
          into: %{},
          do: {key, max(width, Column.find(columns, key).min_width)}
        )
    }
  end

  @doc """
  The columns that show, in their places: the pinned to the start, the
  others, the pinned to the end; each with its width and pin.
  """
  @spec columns(t(), [Column.t()]) :: [Column.t()]
  def columns(%__MODULE__{} = layout, columns) do
    by_key = Map.new(columns, &{&1.key, &1})
    hidden = MapSet.new(layout.hidden)

    shown =
      for key <- layout.order, not MapSet.member?(hidden, key), column = by_key[key] do
        %{
          column
          | pinned: layout.pinned[key],
            hidden: false,
            width: Map.get(layout.widths, key, column.width)
        }
      end

    Enum.filter(shown, &(&1.pinned == :start)) ++
      Enum.filter(shown, &is_nil(&1.pinned)) ++ Enum.filter(shown, &(&1.pinned == :end))
  end

  @doc """
  Every column, with whether it is hidden and where it is pinned, in the
  order they show (the pinned to the start first, the pinned to the end
  last): for the columns menu.
  """
  @spec all(t(), [Column.t()]) :: [Column.t()]
  def all(%__MODULE__{} = layout, columns) do
    by_key = Map.new(columns, &{&1.key, &1})
    hidden = MapSet.new(layout.hidden)

    all =
      for key <- layout.order, column = by_key[key] do
        %{
          column
          | pinned: layout.pinned[key],
            hidden: MapSet.member?(hidden, key),
            width: Map.get(layout.widths, key, column.width)
        }
      end

    Enum.filter(all, &(&1.pinned == :start)) ++
      Enum.filter(all, &is_nil(&1.pinned)) ++ Enum.filter(all, &(&1.pinned == :end))
  end

  @doc """
  Applies a change from the browser: any of `"order"` (every key, in
  order), `"hidden"` (keys), `"pinned"` (key to `"start"` or `"end"`) and
  `"widths"` (key to pixels, merged into the widths there are). Keys of no
  column are left out; a grid always shows one column at least.
  """
  @spec change(t(), map(), [Column.t()]) :: t()
  def change(%__MODULE__{} = layout, params, columns) when is_map(params) do
    keys = MapSet.new(columns, & &1.key)

    layout
    |> change_order(known_keys(params["order"], keys))
    |> change_hidden(known_keys(params["hidden"], keys))
    |> change_pins(params["pinned"], keys)
    |> change_widths(params["widths"], keys)
    |> fit(columns)
    |> keep_one(columns)
  end

  defp known_keys(list, keys) when is_list(list), do: Enum.filter(list, &(&1 in keys))
  defp known_keys(_other, _keys), do: nil

  defp change_order(layout, nil), do: layout

  defp change_order(layout, order),
    do: %{layout | order: merge_order(Enum.uniq(order), layout.order)}

  defp change_hidden(layout, nil), do: layout
  defp change_hidden(layout, hidden), do: %{layout | hidden: Enum.uniq(hidden)}

  defp change_pins(layout, pinned, keys) when is_map(pinned),
    do: %{layout | pinned: pins(pinned, keys)}

  defp change_pins(layout, _pinned, _keys), do: layout

  defp change_widths(layout, widths, keys) when is_map(widths),
    do: %{layout | widths: Map.merge(layout.widths, widths(widths, keys))}

  defp change_widths(layout, _widths, _keys), do: layout

  @doc false
  @spec pins(map(), MapSet.t()) :: %{String.t() => pin()}
  def pins(pinned, keys) do
    for {key, pin} <- pinned, key in keys, pin in ["start", "end", :start, :end], into: %{} do
      {key, if(is_atom(pin), do: pin, else: String.to_existing_atom(pin))}
    end
  end

  @doc false
  @spec widths(map(), MapSet.t()) :: %{String.t() => pos_integer()}
  def widths(widths, keys) do
    for {key, width} <- widths, key in keys, is_integer(width) or is_float(width), into: %{} do
      {key, width |> round() |> max(1) |> min(@max_width)}
    end
  end

  # An order that leaves keys out: they keep their places of the order
  # before.
  defp merge_order(order, before) do
    before
    |> Enum.with_index()
    |> Enum.reject(fn {key, _index} -> key in order end)
    |> Enum.reduce(order, fn {key, index}, order -> List.insert_at(order, index, key) end)
  end

  # Hiding every column leaves the first one shown.
  defp keep_one(%__MODULE__{order: [first | _], hidden: hidden} = layout, _columns) do
    if Enum.all?(layout.order, &(&1 in hidden)),
      do: %{layout | hidden: List.delete(hidden, first)},
      else: layout
  end

  defp keep_one(layout, _columns), do: layout

  @doc "The layout as the browser gets it."
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = layout) do
    %{
      "order" => layout.order,
      "hidden" => layout.hidden,
      "pinned" => Map.new(layout.pinned, fn {key, pin} -> {key, Atom.to_string(pin)} end),
      "widths" => layout.widths
    }
  end
end

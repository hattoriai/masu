defmodule Masu.Column do
  @moduledoc """
  A column of a grid: which value of a row it shows, how, and what a
  person may do with it.

  A grid makes its columns from its `:col` slots (see
  `Masu.Components.data_grid/1`):

      <:col field={:name} />
      <:col field={:total} type={:decimal} label="Total" width={140} />
      <:col :let={order} field={:status} type={:enum}>
        <.badge status={order.status} />
      </:col>

  ## Types

  The type says how the browser formats a value, in the grid's locale,
  how a filter reads the value it is given, and where the cell aligns:

    * `:text` (the default) and `:enum`, as they are;
    * `:integer`, `:number` and `:decimal`, as numbers, aligned to the end
      of the cell. A decimal goes to the browser as a string, so no digit
      is lost on the way;
    * `:date`, `:datetime` and `:time`;
    * `:boolean`, as a check mark.

  A column with an inner block is rendered by it, on the server, for each
  row that the browser shows; the type still says how it sorts and
  filters.

  ## Editing

  In a grid that edits, `values` lists the values of an `:enum` column,
  which its editor offers (a schema's `Ecto.Enum` field has them unless
  given); `decimals` shows a `:decimal` or `:number` column with that
  many digits after the point, whatever the value has.

  ## Layout

  `hidden` starts the column hidden (a person shows it from the columns
  menu), and `pinned={:start}` or `pinned={:end}` keeps it in view while
  the others scroll sideways. See `Masu.Layout`.

  ## Totals

  `aggregate={:sum}` totals the column in the row of each group and in a
  row of totals at the bottom of the grid; see `Masu.Group`.
  """

  @types [:text, :enum, :integer, :number, :decimal, :date, :datetime, :time, :boolean]

  @widths %{
    text: 200,
    enum: 140,
    integer: 120,
    number: 120,
    decimal: 140,
    date: 140,
    datetime: 200,
    time: 110,
    boolean: 100
  }

  @type type ::
          :text | :enum | :integer | :number | :decimal | :date | :datetime | :time | :boolean

  @type t :: %__MODULE__{
          key: String.t(),
          field: atom() | String.t() | nil,
          value: (term() -> term()) | nil,
          label: String.t(),
          type: type(),
          width: pos_integer(),
          min_width: pos_integer(),
          align: :start | :center | :end,
          sortable: boolean(),
          filterable: boolean(),
          searchable: boolean(),
          editable: boolean() | nil,
          editable_if: (term() -> boolean()) | nil,
          creatable: boolean(),
          decimals: non_neg_integer() | nil,
          values: [term()] | nil,
          hidden: boolean(),
          pinned: :start | :end | nil,
          aggregate: aggregate() | nil,
          slot: map() | nil
        }

  @aggregates [:sum, :avg, :min, :max, :count, :count_distinct]

  @typedoc """
  How a column totals its values, in a group's row and the totals row:
  `:sum`, `:avg`, `:min`, `:max`, `:count` (of the values that are not
  `nil`), `:count_distinct`, or, for a list, a function of the rows.
  """
  @type aggregate ::
          :sum | :avg | :min | :max | :count | :count_distinct | ([term()] -> term())

  defstruct [
    :key,
    :field,
    :value,
    :label,
    :slot,
    type: :text,
    width: 200,
    min_width: 48,
    align: :start,
    sortable: true,
    filterable: true,
    searchable: false,
    editable: nil,
    editable_if: nil,
    creatable: false,
    decimals: nil,
    values: nil,
    hidden: false,
    pinned: nil,
    aggregate: nil
  ]

  @doc "The types a column can have."
  @spec types() :: [type()]
  def types, do: @types

  @doc """
  Makes a column from the attributes of a `:col` slot (or a keyword list
  or map of the same names).

  `field` names the value of a row (a key of a map or a field of a
  struct); `value`, a function of the row, computes it instead. `key`
  names the column on the wire and in `Masu.Test`; it is the field as a
  string unless given. `label` is the field in words unless given.

  Raises `ArgumentError` for a column with neither `field` nor `value`,
  or with an unknown type.
  """
  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    {field, value, type} = check!(attrs)
    key = to_key(Map.get(attrs, :key) || field || raise_key(attrs))

    %__MODULE__{
      key: key,
      field: field,
      value: value,
      label: or_default(attrs, :label, humanize(key)),
      type: type,
      width: or_default(attrs, :width, Map.fetch!(@widths, type)),
      min_width: or_default(attrs, :min_width, 48),
      align: or_default(attrs, :align, default_align(type)),
      sortable: Map.get(attrs, :sortable, true) != false,
      filterable: Map.get(attrs, :filterable, true) != false,
      searchable: Map.get(attrs, :searchable, type in [:text, :enum]) == true,
      editable:
        if(is_function(Map.get(attrs, :editable), 1), do: nil, else: Map.get(attrs, :editable)),
      editable_if: if(is_function(Map.get(attrs, :editable), 1), do: Map.get(attrs, :editable)),
      decimals: decimals!(Map.get(attrs, :decimals)),
      values: values!(Map.get(attrs, :values)),
      hidden: Map.get(attrs, :hidden) == true,
      pinned: pinned!(Map.get(attrs, :pinned)),
      aggregate: aggregate!(Map.get(attrs, :aggregate)),
      slot: if(Map.get(attrs, :inner_block), do: attrs)
    }
  end

  defp decimals!(nil), do: nil
  defp decimals!(n) when is_integer(n) and n >= 0 and n <= 20, do: n

  defp decimals!(other),
    do: raise(ArgumentError, "a Masu column's decimals is 0 to 20, got: #{inspect(other)}")

  defp values!(nil), do: nil
  defp values!(values) when is_list(values), do: values

  defp values!(other),
    do: raise(ArgumentError, "a Masu column's values is a list, got: #{inspect(other)}")

  defp aggregate!(nil), do: nil
  defp aggregate!(aggregate) when aggregate in @aggregates, do: aggregate
  defp aggregate!(fun) when is_function(fun, 1), do: fun

  defp aggregate!(other) do
    raise ArgumentError,
          "a Masu column's aggregate is one of #{inspect(@aggregates)} or a function of the rows, got: #{inspect(other)}"
  end

  defp pinned!(pin) when pin in [nil, :start, :end], do: pin
  defp pinned!("start"), do: :start
  defp pinned!("end"), do: :end

  defp pinned!(pin),
    do: raise(ArgumentError, "a Masu column is pinned to :start or :end, got: #{inspect(pin)}")

  defp check!(attrs) do
    field = Map.get(attrs, :field)
    value = Map.get(attrs, :value)
    type = or_default(attrs, :type, :text)

    if is_nil(field) and is_nil(value) do
      raise ArgumentError, "a Masu column needs a field or a value, got: #{inspect(attrs)}"
    end

    unless type in @types do
      raise ArgumentError,
            "unknown Masu column type #{inspect(type)}; the types are #{inspect(@types)}"
    end

    {field, value, type}
  end

  # A slot's attribute that is not given is absent; one given as nil is
  # nil. Both take the default.
  defp or_default(attrs, key, default) do
    case Map.get(attrs, key) do
      nil -> default
      value -> value
    end
  end

  defp raise_key(attrs) do
    raise ArgumentError,
          "a Masu column with a value function needs a key, got: #{inspect(attrs)}"
  end

  @doc """
  Whether a person may edit the column's cells: its grid edits (it has a
  `changeset` or an `update`), the column names a field (not a `value`
  function), and it does not say `editable={false}`. A column whose
  `editable` is a function of the row edits the cells of the rows for
  which it gives `true` (see `editable?/2`).
  """
  @spec editable?(t()) :: boolean()
  def editable?(%__MODULE__{editable: editable}), do: editable == true

  @doc """
  Whether a person may edit the column's cell of a row: the column edits
  (`editable?/1`), and its `editable` function, if it has one, says so for
  the row.
  """
  @spec editable?(t(), term()) :: boolean()
  def editable?(%__MODULE__{editable: true, editable_if: nil}, _row), do: true
  def editable?(%__MODULE__{editable: true, editable_if: fun}, row), do: fun.(row) == true
  def editable?(%__MODULE__{}, _row), do: false

  @doc "The value of the column for a row."
  @spec get(t(), term()) :: term()
  def get(%__MODULE__{value: fun}, row) when is_function(fun, 1), do: fun.(row)
  def get(%__MODULE__{field: field}, %{} = row), do: Map.get(row, field)
  def get(%__MODULE__{}, _row), do: nil

  @doc """
  Whether the column's values can be sorted and filtered by a database:
  it reads a field, not a function of the row.
  """
  @spec stored?(t()) :: boolean()
  def stored?(%__MODULE__{value: nil, field: field}) when is_atom(field) and field != nil,
    do: true

  def stored?(%__MODULE__{}), do: false

  @doc "Finds a column by its key."
  @spec find([t()], String.t()) :: t() | nil
  def find(columns, key), do: Enum.find(columns, &(&1.key == key))

  defp to_key(key) when is_atom(key), do: Atom.to_string(key)
  defp to_key(key) when is_binary(key), do: key

  defp humanize(key) do
    key
    |> String.replace("_", " ")
    |> String.trim()
    |> String.capitalize()
  end

  defp default_align(type) when type in [:integer, :number, :decimal], do: :end
  defp default_align(:boolean), do: :center
  defp default_align(_type), do: :start
end

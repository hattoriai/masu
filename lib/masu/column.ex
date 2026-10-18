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

  `filters`, a list of `Masu.Filter` operators, limits a column's filters
  to those: the operators the app runs, in a controlled grid
  (`on_query`) whose app's queries have fewer than Masu (as a source's
  `c:Masu.Source.filters/2` does). Masu adds `:between` for a column that
  has `:gte` and `:lte`.

  `type={:auto}` is a column whose type the grid learns from its values,
  in the first block of rows of its source: integers make an `:integer`
  column, `Decimal`s a `:decimal` one, `Date`s a `:date` one, and so on;
  values of several types, or of none of these, make it `:text`. The
  grid keeps the type until its source changes. A column whose rows are
  a query tool's results, of no types, takes it.

  ## Rows as lists

  `field={2}` reads the value at that place of a row that is a list (from
  0): a query tool's rows, which come as lists of values in the order of
  its columns. Its key is the place as a string unless given.

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
          field: atom() | String.t() | non_neg_integer() | nil,
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
          raw: boolean(),
          values: [term()] | nil,
          hidden: boolean(),
          pinned: :start | :end | nil,
          aggregate: aggregate() | nil,
          filter_ops: [Masu.Filter.op()] | nil,
          slot: map() | nil,
          auto: map() | nil
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
    raw: false,
    values: nil,
    hidden: false,
    pinned: nil,
    aggregate: nil,
    # The operators its source filters it by (c:Masu.Source.filters/2);
    # nil: every operator of its type.
    filter_ops: nil,
    # A column of `type={:auto}`: its attributes, to make it again of the
    # type its values have (typed/2).
    auto: nil
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

    if type == :auto,
      do: %{new(Map.put(attrs, :type, :text)) | type: :auto, auto: attrs},
      else: build(attrs, key, field, value, type)
  end

  defp build(attrs, key, field, value, type) do
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
      raw: Map.get(attrs, :raw) == true,
      values: values!(Map.get(attrs, :values)),
      hidden: Map.get(attrs, :hidden) == true,
      pinned: pinned!(Map.get(attrs, :pinned)),
      aggregate: aggregate!(Map.get(attrs, :aggregate)),
      filter_ops: filters!(Map.get(attrs, :filters), type),
      slot: if(Map.get(attrs, :inner_block), do: attrs)
    }
  end

  # The operators the app runs for the column (a controlled grid's): those
  # of its type, and between of at least and at most.
  defp filters!(nil, _type), do: nil

  defp filters!(ops, type) when is_list(ops) do
    case ops -- Masu.Filter.ops() do
      [] ->
        Masu.Filter.offered(ops, type)

      unknown ->
        raise ArgumentError,
              "a Masu column's filters are operators of Masu.Filter, got: #{inspect(unknown)}"
    end
  end

  defp filters!(other, _type),
    do:
      raise(
        ArgumentError,
        "a Masu column's filters is a list of operators, got: #{inspect(other)}"
      )

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

    unless type in @types or type == :auto do
      raise ArgumentError,
            "unknown Masu column type #{inspect(type)}; the types are #{inspect(@types)} or :auto"
    end

    check_field!(field)
    {field, value, type}
  end

  defp check_field!(field) when is_atom(field) or is_binary(field), do: :ok
  defp check_field!(place) when is_integer(place) and place >= 0, do: :ok

  defp check_field!(field) do
    raise ArgumentError,
          "a Masu column's field is a key of a row, or a place in a row that is a list (from 0), got: #{inspect(field)}"
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

  @doc """
  A column of `type={:auto}` made again with a type (`infer/1`); any
  other column as it is.
  """
  @spec typed(t(), type()) :: t()
  def typed(%__MODULE__{type: :auto, auto: attrs}, type), do: new(Map.put(attrs, :type, type))
  def typed(%__MODULE__{} = column, _type), do: column

  @doc """
  The type of a column of these values: the type that every value which
  is not `nil` has (an integer and a float make `:number`), else `:text`.
  """
  @spec infer([term()]) :: type()
  def infer(values) do
    values
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&type_of/1)
    |> Enum.uniq()
    |> case do
      [type] ->
        type

      types when types != [] ->
        if Enum.sort(types) == [:integer, :number], do: :number, else: :text

      [] ->
        :text
    end
  end

  defp type_of(value) when is_integer(value), do: :integer
  defp type_of(value) when is_float(value), do: :number
  defp type_of(value) when is_boolean(value), do: :boolean
  defp type_of(%Decimal{}), do: :decimal
  defp type_of(%Date{}), do: :date
  defp type_of(%DateTime{}), do: :datetime
  defp type_of(%NaiveDateTime{}), do: :datetime
  defp type_of(%Time{}), do: :time
  defp type_of(_value), do: :text

  @doc "The value of the column for a row."
  @spec get(t(), term()) :: term()
  def get(%__MODULE__{value: fun}, row) when is_function(fun, 1), do: fun.(row)

  def get(%__MODULE__{field: place}, row) when is_integer(place) and is_list(row),
    do: Enum.at(row, place)

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
  defp to_key(key) when is_integer(key), do: Integer.to_string(key)

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

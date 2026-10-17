defmodule Masu.Filter do
  @moduledoc """
  A condition on a column that a row must meet to be in the grid.

  `op` is one of:

    * `:eq` and `:neq`: equal, or not, to `value`;
    * `:contains`, `:not_contains`, `:starts_with` and `:ends_with`: for
      text, without case;
    * `:gt`, `:gte`, `:lt` and `:lte`: greater or less than `value`;
    * `:between`: from the first to the second value of a two-item list,
      both included;
    * `:in`: one of the values of a list;
    * `:is_nil` and `:not_nil`: no value, or any value (with no `value`).

  The value is read for the column's type (see `Masu.Column`): a date
  column takes `"2026-10-17"` or a `Date`, a number column `"12.5"` or
  `12.5`.
  """

  alias Masu.{Column, Value}

  @ops [
    :eq,
    :neq,
    :contains,
    :not_contains,
    :starts_with,
    :ends_with,
    :gt,
    :gte,
    :lt,
    :lte,
    :between,
    :in,
    :is_nil,
    :not_nil
  ]

  @text_ops [:contains, :not_contains, :starts_with, :ends_with]

  @type op ::
          :eq
          | :neq
          | :contains
          | :not_contains
          | :starts_with
          | :ends_with
          | :gt
          | :gte
          | :lt
          | :lte
          | :between
          | :in
          | :is_nil
          | :not_nil

  @type t :: %__MODULE__{key: String.t(), op: op(), value: term()}

  @enforce_keys [:key, :op]
  defstruct [:key, :op, :value]

  @doc "The operators of a filter."
  @spec ops() :: [op()]
  def ops, do: @ops

  @doc "The operators of a filter on a column of `type`: those of text only for text and enums."
  @spec ops(Column.type()) :: [op()]
  def ops(type) when type in [:text, :enum], do: @ops
  def ops(_type), do: @ops -- @text_ops

  @doc false
  # The operators a column offers, of those its source runs (`direct`):
  # those of its type, and `:between`, which Masu runs as `:gte` and
  # `:lte` (expand/2).
  @spec offered([op()], Column.type()) :: [op()]
  def offered(direct, type) do
    ops = Enum.filter(ops(type), &(&1 in direct))

    if :between not in ops and :gte in ops and :lte in ops,
      do: ops ++ [:between],
      else: ops
  end

  @doc false
  # A filter as filters of the operators a source runs (`direct`): itself,
  # or `:between` as `:gte` and `:lte`. A filter the source cannot run is
  # refused before it gets here (cast/2).
  @spec expand(t(), [op()]) :: [t()]
  def expand(%__MODULE__{op: op} = filter, direct) do
    if op == :between and op not in direct do
      [from, to] = filter.value
      [%{filter | op: :gte, value: from}, %{filter | op: :lte, value: to}]
    else
      [filter]
    end
  end

  @doc "A filter on the column with `key`."
  @spec new(String.t() | atom(), op(), term()) :: t()
  def new(key, op, value \\ nil) when op in @ops,
    do: %__MODULE__{key: to_string(key), op: op, value: value}

  @doc """
  Checks a filter against the grid's columns and reads its value for the
  column's type. Returns the filter with the value read, or an error that
  says why: no such column, a column that does not filter, an operator
  that is not for its type, or a value it cannot read.
  """
  @spec cast(t(), [Column.t()]) :: {:ok, t()} | {:error, String.t()}
  def cast(%__MODULE__{key: key, op: op, value: value} = filter, columns) do
    with {:ok, column} <- column(columns, key),
         :ok <- check_op(column, op),
         {:ok, value} <- cast_value(column.type, op, value) do
      {:ok, %{filter | value: value}}
    end
  end

  defp column(columns, key) do
    case Column.find(columns, key) do
      nil -> {:error, "no column #{inspect(key)}"}
      %Column{filterable: false} -> {:error, "the column #{inspect(key)} does not filter"}
      column -> {:ok, column}
    end
  end

  defp check_op(%Column{type: type}, op) when op in @text_ops and type not in [:text, :enum],
    do: {:error, "#{op} is for text, not #{type}"}

  defp check_op(%Column{filter_ops: ops, key: key}, op) when is_list(ops) do
    if op in ops,
      do: :ok,
      else: {:error, "the source of the column #{inspect(key)} does not filter by #{op}"}
  end

  defp check_op(_column, _op), do: :ok

  defp cast_value(_type, op, _value) when op in [:is_nil, :not_nil], do: {:ok, nil}

  defp cast_value(type, :between, [from, to]) do
    with {:ok, from} <- cast_one(type, from),
         {:ok, to} <- cast_one(type, to) do
      {:ok, [from, to]}
    end
  end

  defp cast_value(_type, :between, value),
    do: {:error, "between takes a list of two values, got: #{inspect(value)}"}

  defp cast_value(type, :in, values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case cast_one(type, value) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp cast_value(_type, :in, value),
    do: {:error, "in takes a list of values, got: #{inspect(value)}"}

  defp cast_value(_type, op, nil), do: {:error, "#{op} needs a value"}
  defp cast_value(type, _op, value), do: cast_one(type, value)

  defp cast_one(type, value) do
    case Value.cast(type, value) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, "#{inspect(value)} is not a #{type}"}
    end
  end

  @doc """
  Whether a value meets the filter, as `Masu.Source.List` checks it. The
  filter's value must already be read (`cast/2`).
  """
  @spec match?(t(), term()) :: boolean()
  def match?(%__MODULE__{op: :is_nil}, value), do: is_nil(value)
  def match?(%__MODULE__{op: :not_nil}, value), do: not is_nil(value)
  def match?(%__MODULE__{op: :neq}, nil), do: true
  def match?(%__MODULE__{}, nil), do: false
  def match?(%__MODULE__{op: :eq, value: v}, value), do: Value.compare(value, v) == :eq
  def match?(%__MODULE__{op: :neq, value: v}, value), do: Value.compare(value, v) != :eq
  def match?(%__MODULE__{op: :gt, value: v}, value), do: Value.compare(value, v) == :gt
  def match?(%__MODULE__{op: :gte, value: v}, value), do: Value.compare(value, v) != :lt
  def match?(%__MODULE__{op: :lt, value: v}, value), do: Value.compare(value, v) == :lt
  def match?(%__MODULE__{op: :lte, value: v}, value), do: Value.compare(value, v) != :gt

  def match?(%__MODULE__{op: :between, value: [from, to]}, value),
    do: Value.compare(value, from) != :lt and Value.compare(value, to) != :gt

  def match?(%__MODULE__{op: :in, value: values}, value),
    do: Enum.any?(values, &(Value.compare(value, &1) == :eq))

  def match?(%__MODULE__{op: op, value: v}, value) when op in @text_ops do
    text = value |> Value.to_wire() |> to_string() |> String.downcase()
    part = String.downcase(v)

    case op do
      :contains -> String.contains?(text, part)
      :not_contains -> not String.contains?(text, part)
      :starts_with -> String.starts_with?(text, part)
      :ends_with -> String.ends_with?(text, part)
    end
  end

  @doc false
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{key: key, op: op, value: value}) do
    value = if is_list(value), do: Enum.map(value, &Value.to_wire/1), else: Value.to_wire(value)
    %{"key" => key, "op" => Atom.to_string(op), "value" => value}
  end
end

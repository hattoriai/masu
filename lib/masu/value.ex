defmodule Masu.Value do
  @moduledoc false
  # The values of cells: how a filter reads the value it is given for a
  # column's type, how two values compare in a list, and what goes to the
  # browser.

  @doc "Reads a filter's value for a column type: `{:ok, value}` or `:error`."
  @spec cast(Masu.Column.type(), term()) :: {:ok, term()} | :error
  def cast(_type, nil), do: {:ok, nil}
  def cast(type, value) when type in [:text, :enum] and is_binary(value), do: {:ok, value}

  def cast(type, value) when type in [:text, :enum] and is_atom(value),
    do: {:ok, Atom.to_string(value)}

  def cast(type, value) when type in [:text, :enum] and is_number(value),
    do: {:ok, to_string(value)}

  def cast(:integer, value) when is_integer(value), do: {:ok, value}

  def cast(:integer, value) when is_float(value) and trunc(value) == value,
    do: {:ok, trunc(value)}

  def cast(:integer, value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> {:ok, int}
      _other -> :error
    end
  end

  def cast(:number, value) when is_number(value), do: {:ok, value}

  def cast(:number, value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {float, ""} -> {:ok, if(float == trunc(float), do: trunc(float), else: float)}
      _other -> :error
    end
  end

  def cast(:decimal, value) when is_number(value) or is_binary(value) do
    if decimal?() do
      case Decimal.cast(value) do
        {:ok, decimal} -> {:ok, decimal}
        :error -> :error
      end
    else
      cast(:number, value)
    end
  end

  def cast(:date, %Date{} = date), do: {:ok, date}

  def cast(:date, value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _error -> :error
    end
  end

  def cast(:datetime, %DateTime{} = value), do: {:ok, value}
  def cast(:datetime, %NaiveDateTime{} = value), do: {:ok, value}

  def cast(:datetime, value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      _error ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive} -> {:ok, naive}
          _error -> :error
        end
    end
  end

  def cast(:time, %Time{} = time), do: {:ok, time}

  def cast(:time, value) when is_binary(value) do
    case Time.from_iso8601(value) do
      {:ok, time} -> {:ok, time}
      _error -> :error
    end
  end

  def cast(:boolean, value) when is_boolean(value), do: {:ok, value}
  def cast(:boolean, value) when value in ["true", "1", 1], do: {:ok, true}
  def cast(:boolean, value) when value in ["false", "0", 0], do: {:ok, false}
  def cast(_type, _value), do: :error

  @doc """
  Compares two values of a column as a list sorts them: `:lt`, `:eq` or
  `:gt`. Text compares without case; `nil` comes after every value.
  """
  @spec compare(term(), term()) :: :lt | :eq | :gt
  def compare(same, same), do: :eq
  def compare(nil, _other), do: :gt
  def compare(_value, nil), do: :lt
  def compare(a, b) when is_number(a) and is_number(b), do: order(a, b)

  def compare(a, b) when is_binary(a) and is_binary(b) do
    case order(String.downcase(a), String.downcase(b)) do
      :eq -> order(a, b)
      other -> other
    end
  end

  def compare(%module{} = a, %module{} = b)
      when module in [Date, DateTime, NaiveDateTime, Time],
      do: module.compare(a, b)

  # A datetime with a zone and one without: the one without is UTC.
  def compare(%DateTime{} = a, %NaiveDateTime{} = b),
    do: DateTime.compare(a, DateTime.from_naive!(b, "Etc/UTC"))

  def compare(%NaiveDateTime{} = a, %DateTime{} = b),
    do: DateTime.compare(DateTime.from_naive!(a, "Etc/UTC"), b)

  def compare(%{__struct__: Decimal} = a, b), do: decimal_compare(a, b)
  def compare(a, %{__struct__: Decimal} = b), do: decimal_compare(a, b)

  def compare(a, b) when is_atom(a) and is_atom(b),
    do: compare(Atom.to_string(a), Atom.to_string(b))

  def compare(a, b), do: order(a, b)

  defp decimal_compare(a, b) do
    if decimal?() and decimal_like?(a) and decimal_like?(b),
      do: Decimal.compare(to_decimal(a), to_decimal(b)),
      else: order(a, b)
  end

  defp decimal_like?(value), do: is_number(value) or is_struct(value, Decimal)

  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp to_decimal(value), do: value

  defp order(a, b) when a < b, do: :lt
  defp order(a, b) when a > b, do: :gt
  defp order(_a, _b), do: :eq

  @doc """
  A function that gives each of `values` a key that Erlang's term order
  sorts as `compare/2` does (`nil` for `nil`): text without case,
  dates and times by their instant, and decimals as exact integers,
  scaled to the smallest exponent among `values`.
  """
  @spec sort_key_fun([term()]) :: (term() -> term())
  def sort_key_fun(values) do
    exp =
      values
      |> Enum.flat_map(fn
        %{__struct__: Decimal, coef: coef, exp: exp} when is_integer(coef) -> [exp]
        value when is_float(value) -> [-15]
        _value -> []
      end)
      |> Enum.min(fn -> nil end)

    &sort_key(&1, exp)
  end

  defp sort_key(nil, _exp), do: nil
  defp sort_key(value, nil) when is_number(value), do: value
  defp sort_key(value, exp) when is_integer(value), do: value * pow10(-exp)

  defp sort_key(value, exp) when is_float(value),
    do: value |> Decimal.from_float() |> sort_key(exp)

  defp sort_key(%{__struct__: Decimal, sign: sign, coef: coef, exp: e}, exp)
       when is_integer(coef) and is_integer(exp),
       do: sign * coef * pow10(e - exp)

  defp sort_key(%{__struct__: Decimal} = value, _exp), do: {:special, Decimal.to_string(value)}
  defp sort_key(value, _exp) when is_binary(value), do: {String.downcase(value), value}
  defp sort_key(value, _exp) when is_boolean(value), do: value

  defp sort_key(value, _exp) when is_atom(value),
    do: value |> Atom.to_string() |> sort_key(nil)

  defp sort_key(%Date{} = date, _exp), do: Date.to_gregorian_days(date)
  defp sort_key(%DateTime{} = value, _exp), do: DateTime.to_unix(value, :microsecond)

  defp sort_key(%NaiveDateTime{} = value, _exp),
    do: {NaiveDateTime.to_gregorian_seconds(value), elem(value.microsecond, 0)}

  defp sort_key(%Time{} = value, _exp),
    do: {Time.to_seconds_after_midnight(value), elem(value.microsecond, 0)}

  defp sort_key(value, _exp), do: value

  defp pow10(n) when n <= 0, do: 1
  defp pow10(n), do: Integer.pow(10, n)

  @doc """
  The value as the browser gets it in JSON: numbers and booleans as they
  are, decimals as strings (no digit is lost), dates and times in ISO
  8601, atoms and other terms as text.
  """
  @spec to_wire(term()) :: term()
  def to_wire(nil), do: nil
  def to_wire(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  def to_wire(value) when is_atom(value), do: Atom.to_string(value)

  def to_wire(%module{} = value) when module in [Date, DateTime, NaiveDateTime, Time],
    do: module.to_iso8601(value)

  def to_wire(%{__struct__: Decimal} = value), do: Decimal.to_string(value, :normal)

  def to_wire(value) do
    case String.Chars.impl_for(value) do
      nil -> inspect(value)
      _impl -> to_string(value)
    end
  end

  defp decimal?, do: Code.ensure_loaded?(Decimal)
end

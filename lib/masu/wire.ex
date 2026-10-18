defprotocol Masu.Wire do
  @moduledoc """
  A value of your own type, as the browser gets it in a cell: what the
  cell shows (formatted by the column's type), what a copy and an export
  take, and what a filter of the browser compares.

  Masu knows numbers, decimals, dates and times, booleans and text, and a
  struct that implements `String.Chars`. For any other struct, implement
  this protocol: a rich text that shows its text, a range of days that
  shows `2027-03-15/2027-03-20`.

      defimpl Masu.Wire, for: Kotoba.Content do
        def to_wire(content), do: content.text
      end

      defimpl Masu.Wire, for: Koyomi.DateRange do
        def to_wire(range), do: "\#{range.from}/\#{range.to}"
      end

  The value goes to the browser as JSON: give text, a number, a boolean,
  or nil. An editor of your own (see the Editors of your own guide) gets
  the value as the row has it, not this.
  """

  @fallback_to_any true

  @doc "The value as the browser gets it."
  @spec to_wire(t()) :: String.t() | number() | boolean() | nil
  def to_wire(value)
end

defimpl Masu.Wire, for: Any do
  def to_wire(value) do
    case String.Chars.impl_for(value) do
      nil -> inspect(value)
      _impl -> to_string(value)
    end
  end
end

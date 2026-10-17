defmodule Masu.ValueTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Masu.Value

  test "cast/2 reads a value for each type" do
    assert Value.cast(:text, :late) == {:ok, "late"}
    assert Value.cast(:integer, " 42 ") == {:ok, 42}
    assert Value.cast(:integer, 4.0) == {:ok, 4}
    assert Value.cast(:integer, "4.5") == :error
    assert Value.cast(:number, "4.5") == {:ok, 4.5}
    assert Value.cast(:number, "4") == {:ok, 4}
    assert {:ok, %Decimal{}} = Value.cast(:decimal, "0.10")
    assert Value.cast(:date, "2026-10-17") == {:ok, ~D[2026-10-17]}
    assert Value.cast(:datetime, "2026-10-17T10:00:00Z") == {:ok, ~U[2026-10-17 10:00:00Z]}
    assert Value.cast(:datetime, "2026-10-17T10:00:00") == {:ok, ~N[2026-10-17 10:00:00]}
    assert Value.cast(:time, "09:30:00") == {:ok, ~T[09:30:00]}
    assert Value.cast(:boolean, "true") == {:ok, true}
    assert Value.cast(:boolean, "yes") == :error
    assert Value.cast(:date, "17/10/2026") == :error
  end

  test "compare/2 puts nil last, compares text without case, and decimals by value" do
    assert Value.compare(nil, 1) == :gt
    assert Value.compare(1, nil) == :lt
    assert Value.compare("alan", "Bob") == :lt
    assert Value.compare(Decimal.new("10"), Decimal.new("9.5")) == :gt
    assert Value.compare(Decimal.new("1.0"), 1) == :eq
    assert Value.compare(Decimal.new("1.5"), 1.5) == :eq
    assert Value.compare(~D[2026-01-02], ~D[2026-01-10]) == :lt
    assert Value.compare(~U[2026-01-02 10:00:00Z], ~N[2026-01-02 09:00:00]) == :gt
    assert Value.compare(~N[2026-01-02 10:00:00], ~U[2026-01-02 10:00:00Z]) == :eq
  end

  test "to_wire/1 keeps every digit of a decimal, and writes dates in ISO 8601" do
    assert Value.to_wire(Decimal.new("12345678901234567890.123")) == "12345678901234567890.123"
    assert Value.to_wire(~U[2026-10-17 10:00:00Z]) == "2026-10-17T10:00:00Z"
    assert Value.to_wire(:late) == "late"
    assert Value.to_wire(nil) == nil
    assert Value.to_wire({1, 2}) == "{1, 2}"
  end

  property "compare/2 orders integers as Elixir does" do
    check all(a <- integer(), b <- integer()) do
      expected =
        cond do
          a < b -> :lt
          a > b -> :gt
          true -> :eq
        end

      assert Value.compare(a, b) == expected
    end
  end
end

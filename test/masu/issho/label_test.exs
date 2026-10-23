defmodule Masu.Issho.LabelTest do
  use ExUnit.Case, async: true

  @grid "orders:42/orders"
  @opts [
    grid: @grid,
    columns: %{"name" => "Name", "city" => "City", "seats" => "Seats"},
    row: &__MODULE__.name/1
  ]

  def name(7), do: "Acme"
  def name(_id), do: nil

  defp at(at), do: %{"doc" => @grid, "at" => at}

  test "a cell, by its column's label and its row's name" do
    assert Masu.Issho.label(at(%{"cell" => [7, "city"]}), @opts) == "City of Acme"
    assert Masu.Issho.label(at(%{"cell" => [9, "city"]}), @opts) == "City of row 9"
    assert Masu.Issho.label(at(%{"cell" => [7, "notes"]}), @opts) == "notes of Acme"

    assert Masu.Issho.label(at(%{"cell" => [7, "city"], "x" => 0.5, "y" => 0.5}), @opts) ==
             "City of Acme"
  end

  test "a range, in a row or over rows" do
    assert Masu.Issho.label(
             at(%{"range" => %{"rows" => [7], "keys" => ["name", "city", "seats"]}}),
             @opts
           ) ==
             "Name to Seats of Acme"

    range = %{"rows" => [7, 8, 9], "keys" => ["seats"]}

    assert Masu.Issho.label(at(%{"cell" => [7, "seats"], "range" => range}), @opts) ==
             "Seats of 3 rows"
  end

  test "no words for no place, a place of another grid, or one it does not know" do
    assert Masu.Issho.label(nil, @opts) == nil

    assert Masu.Issho.label(
             %{"doc" => "orders:42/other", "at" => %{"cell" => [7, "city"]}},
             @opts
           ) == nil

    assert Masu.Issho.label(at(%{"node" => "n7"}), @opts) == nil
  end

  test "without options, any grid's place, its keys and its ids" do
    assert Masu.Issho.label(%{"doc" => "a/b", "at" => %{"cell" => ["x1", "city"]}}) ==
             "city of row x1"
  end
end

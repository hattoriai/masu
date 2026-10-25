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

  describe "the words of the places the grid sets (Masu.Issho.Place.label/3)" do
    alias Masu.Issho.Place

    @columns [
      Masu.Column.new(field: :title),
      Masu.Column.new(field: :status, label: "Status"),
      Masu.Column.new(field: :due)
    ]

    test "a cell, by its column's label and its row's name" do
      assert Place.label(%{"cell" => [7, "status"]}, @columns, "Forge the blade") ==
               "Status of “Forge the blade”"

      assert Place.label(%{"cell" => [7, "status"]}, @columns, nil) == "Status"
      assert Place.label(%{"cell" => [7, "notes"]}, @columns, nil) == "notes"

      range = %{"rows" => [7], "keys" => ["status"]}

      assert Place.label(%{"cell" => [7, "status"], "range" => range}, @columns, "A") ==
               "Status of “A”"
    end

    test "a range, by its size" do
      assert Place.label(
               %{"range" => %{"rows" => [7, 8, 9], "keys" => ["status"]}},
               @columns,
               nil
             ) ==
               "Status, 3 rows"

      assert Place.label(
               %{"range" => %{"rows" => [7], "keys" => ["title", "status"]}},
               @columns,
               "A"
             ) ==
               "2 columns of “A”"

      range = %{"rows" => [7, 8, 9], "keys" => ["title", "status"]}

      assert Place.label(%{"cell" => [7, "title"], "range" => range}, @columns, nil) ==
               "3 rows × 2 columns"
    end

    test "the row a label names, and its name: its first cell, short" do
      assert Place.row(%{"cell" => [7, "status"]}) == 7
      assert Place.row(%{"range" => %{"rows" => [7, 7], "keys" => ["a", "b"]}}) == 7
      assert Place.row(%{"range" => %{"rows" => [7, 8], "keys" => ["a"]}}) == nil

      assert Place.name(@columns, %{title: " Forge the blade "}) == "Forge the blade"
      assert Place.name(@columns, %{title: 42}) == "42"
      assert Place.name(@columns, %{title: nil}) == nil
      assert Place.name(@columns, %{title: ""}) == nil

      assert Place.name(@columns, %{title: String.duplicate("a", 40)}) ==
               String.duplicate("a", 31) <> "…"
    end

    test "no words for a place of no cell" do
      assert Place.label(%{"x" => 0.5}, @columns, nil) == nil
      assert Place.label(%{"range" => %{"rows" => [], "keys" => []}}, @columns, nil) == nil
      assert Place.label(%{"cell" => [7, 3]}, @columns, nil) == nil
      assert Place.label(%{"range" => %{"rows" => [7], "keys" => [3]}}, @columns, nil) == nil
    end
  end
end

defmodule Masu.ColumnTest do
  use ExUnit.Case, async: true

  alias Masu.Column

  test "a column of a field takes its key and label from it" do
    column = Column.new(field: :inserted_at, type: :datetime)

    assert %Column{key: "inserted_at", label: "Inserted at", width: 200, align: :start} = column
    assert column.sortable and column.filterable
    refute column.searchable
  end

  test "numbers align to the end, booleans to the center, text is searchable" do
    assert Column.new(field: :total, type: :decimal).align == :end
    assert Column.new(field: :ok, type: :boolean).align == :center
    assert Column.new(field: :name).searchable
    assert Column.new(field: :status, type: :enum).searchable
  end

  test "a column of a value function needs a key" do
    assert %Column{key: "initials", label: "Initials"} =
             Column.new(key: "initials", value: &String.first(&1.name))

    assert_raise ArgumentError, ~r/needs a key/, fn -> Column.new(value: & &1) end
    assert_raise ArgumentError, ~r/needs a field or a value/, fn -> Column.new(label: "X") end

    assert_raise ArgumentError, ~r/unknown Masu column type/, fn ->
      Column.new(field: :x, type: :money)
    end
  end

  test "a column is at least its min_width wide" do
    assert Column.new(field: :title, min_width: 280).width == 280
    assert Column.new(field: :title, width: 100, min_width: 120).width == 120
    assert Column.new(field: :title, width: 300, min_width: 120).width == 300
  end

  test "grow is its share of the room the columns leave: true is 1" do
    assert Column.new(field: :title).grow == 0
    assert Column.new(field: :title, grow: false).grow == 0
    assert Column.new(field: :title, grow: true).grow == 1
    assert Column.new(field: :title, grow: 2).grow == 2
    assert Column.new(field: :title, type: :auto, grow: true).grow == 1

    for grow <- [-1, 1.5, "1"] do
      assert_raise ArgumentError, ~r/grow is true, or a positive integer/, fn ->
        Column.new(field: :title, grow: grow)
      end
    end
  end

  test "get/2 reads a map, a struct or a function" do
    assert Column.get(Column.new(field: :name), %{name: "Ada"}) == "Ada"
    assert Column.get(Column.new(field: "name"), %{"name" => "Ada"}) == "Ada"
    assert Column.get(Column.new(field: :hour), ~T[10:00:00]) == 10
    assert Column.get(Column.new(key: "n", value: &String.length(&1.name)), %{name: "Ada"}) == 3
  end

  test "stored?/1 is true for an atom field only" do
    assert Column.stored?(Column.new(field: :name))
    refute Column.stored?(Column.new(field: "name"))
    refute Column.stored?(Column.new(key: "n", value: & &1))
  end
end

defmodule Masu.ViewTest do
  use ExUnit.Case, async: true

  alias Masu.{Column, Filter, Layout, Query, Sort, View}

  defp columns do
    [
      Column.new(field: :id, type: :integer, pinned: :start),
      Column.new(field: :name),
      Column.new(field: :city),
      Column.new(field: :age, type: :integer),
      Column.new(field: :admin, type: :boolean, hidden: true),
      Column.new(field: :total, type: :decimal, pinned: :end)
    ]
  end

  defp keys(columns), do: Enum.map(columns, & &1.key)

  defp default do
    {:ok, query} = Query.new([sort: [:name]], columns())
    %View{query: query, layout: Layout.new(columns())}
  end

  describe "Masu.Layout" do
    test "the declared layout shows the pinned to the start first, the pinned to the end last, without the hidden" do
      layout = Layout.new(columns())
      assert layout.hidden == ["admin"]
      assert layout.pinned == %{"id" => :start, "total" => :end}
      assert keys(Layout.columns(layout, columns())) == ~w(id name city age total)
    end

    test "a change moves, hides, pins and resizes; every column stays in the catalog" do
      layout =
        Layout.new(columns())
        |> Layout.change(
          %{
            "order" => ~w(id city name age admin total),
            "hidden" => ["age"],
            "pinned" => %{"city" => "start", "total" => "nowhere"},
            "widths" => %{"name" => 260, "nope" => 10}
          },
          columns()
        )

      shown = Layout.columns(layout, columns())
      assert keys(shown) == ~w(city id name admin total)
      assert Enum.find(shown, &(&1.key == "name")).width == 260
      assert Enum.find(shown, &(&1.key == "city")).pinned == :start
      assert layout.pinned == %{"city" => :start}
      assert keys(Layout.all(layout, columns())) == ~w(city id name age admin total)
    end

    test "a grid always shows one column" do
      layout = Layout.change(Layout.new(columns()), %{"hidden" => keys(columns())}, columns())
      assert keys(Layout.columns(layout, columns())) == ["id"]
    end

    test "a width is at least the column's min_width" do
      layout = Layout.change(Layout.new(columns()), %{"widths" => %{"name" => 3}}, columns())
      assert layout.widths["name"] == 48
    end

    test "a layout fits columns that changed: removed keys go, new columns take their declared place" do
      old = %Layout{
        order: ~w(city gone name id),
        hidden: ["gone"],
        pinned: %{},
        widths: %{"gone" => 90}
      }

      layout = Layout.fit(old, columns())

      assert layout.order == ~w(city name id age admin total)
      assert layout.hidden == ["admin"]
      assert layout.pinned == %{"total" => :end}
      assert layout.widths == %{}
    end
  end

  describe "Masu.View" do
    test "the grid's own view has no params" do
      assert View.to_params(default(), default()) == %{}
      assert View.from_params(%{}, columns(), default()) == {default(), []}
    end

    test "params have only what differs, and read back to the same view" do
      view = %View{
        query: %Query{
          sorts: [Sort.new("age", :desc), Sort.new("name")],
          filters: [
            %Filter{key: "city", op: :in, value: ["London", "Nuenen"]},
            %Filter{key: "age", op: :between, value: [30, 80]},
            %Filter{key: "admin", op: :is_nil, value: nil}
          ],
          search: "a"
        },
        layout:
          Layout.change(
            Layout.new(columns()),
            %{
              "order" => ~w(id city name age admin total),
              "hidden" => [],
              "pinned" => %{"id" => "start"},
              "widths" => %{"name" => 220}
            },
            columns()
          )
      }

      params = View.to_params(view, default())

      assert params["sort"] == "-age,name"
      assert params["q"] == "a"
      assert params["cols"] == "id,city,name,age,admin,total"
      assert params["hide"] == ""
      assert params["pin"] == "id:start"
      assert params["w"] == "name:220"
      assert map_size(params["filter"]) == 3

      # As a URL has them: every value a string.
      url_params = params |> Plug.Conn.Query.encode() |> Plug.Conn.Query.decode()
      assert View.from_params(url_params, columns(), default()) == {view, []}
    end

    test "an empty part replaces the grid's: no order" do
      {view, []} = View.from_params(%{"sort" => ""}, columns(), default())
      assert view.query.sorts == []
      assert View.to_params(view, default()) == %{"sort" => ""}
    end

    test "parts that no longer apply are left out, and named" do
      params = %{
        "sort" => "-gone,age",
        "filter" => %{
          "0" => %{"key" => "age", "op" => "gt", "value" => "forty"},
          "1" => %{"key" => "city", "op" => "eq", "value" => "London"},
          "2" => %{"key" => "nope", "op" => "eq", "value" => "x"}
        },
        "cols" => "gone,name,id",
        "hide" => "gone,city"
      }

      {view, dropped} = View.from_params(params, columns(), default())

      assert dropped == ["gone", "age", "nope"]
      assert view.query.sorts == [Sort.new("age")]
      assert [%Filter{key: "city", op: :eq, value: "London"}] = view.query.filters
      assert view.layout.order == ~w(name id city age admin total)
      assert view.layout.hidden == ["city"]
    end

    test "params that are not a map are the grid's own view" do
      assert View.from_params("junk", columns(), default()) == {default(), []}
    end
  end
end

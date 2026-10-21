defmodule Masu.InputTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Masu.Test

  alias Masu.{Column, Filter, Layout, Query, View}
  alias Masu.Views.Memory

  @endpoint MasuTest.Endpoint

  @columns [
    Column.new(field: :name),
    Column.new(field: :age, type: :integer),
    Column.new(field: :city)
  ]

  @nul <<0>>

  setup do
    Memory.clear()
    :ok
  end

  defp wire(changes), do: Query.from_wire(changes, @columns)

  defp condition(value, op \\ "eq", key \\ "name"),
    do: %{"key" => key, "op" => op, "value" => value}

  defp default do
    {:ok, query} = Query.new([sort: [:name]], @columns)
    %View{query: query, layout: Layout.new(@columns)}
  end

  defp params(params), do: View.from_params(params, @columns, default())

  defp nul?(term), do: String.contains?(inspect(term, limit: :infinity), "\\0")

  # An event's reply, as the browser gets it.
  defp push(view, id, name, payload) do
    render(view)
    view |> element("##{id}") |> render_hook(name, payload)
    %{proxy: {ref, _topic, _pid}} = view

    receive do
      {^ref, {:reply, reply}} -> reply
    after
      1000 -> flunk("no reply")
    end
  end

  describe "Query.from_wire/2" do
    test "a search is at most 1,000 bytes, as bytes: a text of graphemes is bound by its size" do
      assert {:ok, %Query{search: search}} = wire(%{"search" => String.duplicate("a", 1_000)})
      assert byte_size(search) == 1_000

      assert {:error, "The search is longer than 1,000 bytes."} =
               wire(%{"search" => String.duplicate("a", 1_001)})

      # 600 characters, 1,200 bytes.
      assert {:error, "The search is longer than 1,000 bytes."} =
               wire(%{"search" => String.duplicate("é", 600)})
    end

    test "a search of padding is refused, not trimmed to fit" do
      assert {:error, _} = wire(%{"search" => "ada" <> String.duplicate(" ", 1_000)})
    end

    test "a NUL is refused in a search" do
      assert {:error, "The search has a NUL character."} = wire(%{"search" => "a" <> @nul <> "b"})
    end

    test "the text of a filter value is at most 1,000 bytes, and has no NUL" do
      assert {:ok, _} = wire(%{"filters" => [condition(String.duplicate("a", 1_000))]})

      assert {:error, "A filter value is longer than 1,000 bytes."} =
               wire(%{"filters" => [condition(String.duplicate("a", 1_001), "contains")]})

      assert {:error, "A filter value has a NUL character."} =
               wire(%{"filters" => [condition("a" <> @nul, "starts_with")]})

      # A column that is not text reads its value from the text, so the text is checked too.
      assert {:error, "A filter value is longer than 1,000 bytes."} =
               wire(%{"filters" => [condition(String.duplicate("1", 1_001), "eq", "age")]})
    end

    test "each value of a list filter, and of between, is checked" do
      assert {:error, "A filter value has a NUL character."} =
               wire(%{"filters" => [condition(["a", "b" <> @nul], "in")]})

      assert {:error, "A filter value is longer than 1,000 bytes."} =
               wire(%{"filters" => [condition(["a", String.duplicate("b", 1_001)], "in")]})

      assert {:error, "A filter value has a NUL character."} =
               wire(%{"filters" => [condition(["1", "2" <> @nul], "between", "age")]})
    end

    test "a list filter has at most 10,000 values" do
      values = Enum.map(1..10_000, &Integer.to_string/1)
      assert {:ok, _} = wire(%{"filters" => [condition(values, "in")]})

      assert {:error, "A filter has more than 10,000 values."} =
               wire(%{"filters" => [condition(["0" | values], "in")]})
    end

    test "a query has at most 100 filters, 100 sorts and 100 groups, counted as sent" do
      filters = List.duplicate(condition("a"), 100)
      assert {:ok, _} = wire(%{"filters" => filters})

      assert {:error, "A query has more than 100 filters."} =
               wire(%{"filters" => [condition("a") | filters]})

      sorts = List.duplicate(%{"key" => "name", "dir" => "asc"}, 100)
      assert {:ok, %Query{sorts: [_]}} = wire(%{"sorts" => sorts})

      assert {:error, "A query has more than 100 sorts."} =
               wire(%{"sorts" => [%{"key" => "age", "dir" => "asc"} | sorts]})

      groups = List.duplicate("name", 100)
      assert {:ok, %Query{groups: ["name"]}} = wire(%{"groups" => groups})
      assert {:error, "A query has more than 100 groups."} = wire(%{"groups" => ["age" | groups]})
    end
  end

  describe "Filter.cast/2" do
    test "refuses a value past a bound, or with a NUL, whoever made the filter" do
      assert {:error, "A filter value has a NUL character."} =
               "name" |> Filter.new(:eq, "a" <> @nul) |> Filter.cast(@columns)

      assert {:error, "A filter value is longer than 1,000 bytes."} =
               "name" |> Filter.new(:eq, String.duplicate("a", 1_001)) |> Filter.cast(@columns)

      assert {:error, "A filter has more than 10,000 values."} =
               "age"
               |> Filter.new(:in, Enum.to_list(0..10_000))
               |> Filter.cast(@columns)
    end
  end

  describe "View.from_params/3" do
    test "a search past a bound, or with a NUL, is dropped whole, and the grid's own stays" do
      assert {%View{query: %Query{search: nil}}, ["search"]} =
               params(%{"q" => String.duplicate("a", 1_001)})

      assert {%View{query: %Query{search: nil}}, ["search"]} = params(%{"q" => "a" <> @nul})
      assert {%View{query: %Query{search: "ada"}}, []} = params(%{"q" => " ada "})

      {:ok, own} = Query.new([search: "own"], @columns)
      view = %{default() | query: own}

      assert {%View{query: %Query{search: "own"}}, ["search"]} =
               View.from_params(%{"q" => "a" <> @nul}, @columns, view)
    end

    test "a filter with a value past a bound, or with a NUL, is dropped by its column" do
      filters = %{
        "0" => %{"key" => "name", "op" => "eq", "value" => "a" <> @nul},
        "1" => %{"key" => "city", "op" => "eq", "value" => "Paris"},
        "2" => %{"key" => "age", "op" => "in", "value" => Enum.to_list(0..10_000)}
      }

      assert {%View{query: %Query{filters: [%Filter{key: "city", value: "Paris"}]}},
              ["name", "age"]} = params(%{"filter" => filters})
    end

    test "more than 100 filters are all dropped, a link as a list or as the map of a URL" do
      filter = %{"key" => "name", "op" => "eq", "value" => "a"}

      assert {%View{query: %Query{filters: filters}}, []} =
               params(%{"filter" => List.duplicate(filter, 100)})

      assert length(filters) == 100

      assert {%View{query: %Query{filters: []}}, ["filters"]} =
               params(%{"filter" => List.duplicate(filter, 101)})

      map = Map.new(0..100, &{Integer.to_string(&1), filter})
      assert {%View{query: %Query{filters: []}}, ["filters"]} = params(%{"filter" => map})
    end

    test "more than 100 sorts or groups are dropped whole, counted before duplicates go" do
      assert {%View{query: %Query{sorts: [sort]}}, []} =
               params(%{"sort" => Enum.join(List.duplicate("age", 100), ",")})

      assert sort.key == "age"

      assert {%View{query: %Query{sorts: [%{key: "name"}]}}, ["sort"]} =
               params(%{"sort" => Enum.join(List.duplicate("age", 101), ",")})

      assert {%View{query: %Query{groups: ["name"]}}, []} =
               params(%{"group" => Enum.join(List.duplicate("name", 100), ",")})

      assert {%View{query: %Query{groups: []}}, ["group"]} =
               params(%{"group" => Enum.join(List.duplicate("name", 101), ",")})
    end

    test "a column key with a NUL never reaches the layout" do
      {%View{layout: layout}, _dropped} =
        params(%{
          "cols" => "name,a" <> @nul,
          "hide" => "b" <> @nul,
          "pin" => "c" <> @nul <> ":start",
          "w" => "d" <> @nul <> ":100"
        })

      refute nul?(layout)
    end
  end

  describe "a grid" do
    test "refuses a query with a NUL, and keeps its view" do
      {:ok, view, _html} = live(build_conn(), "/input")
      query = view |> grid_query() |> Map.put("search", "a" <> @nul)

      assert %{"error" => "The search has a NUL character."} =
               push(view, "g", "masu:query", query)

      assert view(view, "g") == %{}
      assert Memory.last("g", %{id: "ada"}) in [nil, %{}]
    end

    test "drops the search of a view with a NUL, and keeps what the last view stores clean" do
      {:ok, view, _html} = live(build_conn(), "/input")

      assert ["search"] = apply_view(view, "g", %{"q" => "a" <> @nul})
      assert view(view, "g") == %{}
      refute nul?(Memory.last("g", %{id: "ada"}))

      assert ["search"] = apply_view(view, "g", %{"q" => String.duplicate("a", 1_001)})
      assert [] = apply_view(view, "g", %{"q" => "ab"})
      assert %{"q" => "ab"} = view(view, "g")
    end

    test "gives no values for a search past a bound, or with a NUL" do
      {:ok, view, _html} = live(build_conn(), "/input")

      assert [{"ab", 1}] = values(view, "g", "name", search: "ab")
      assert [] = values(view, "g", "name", search: "a" <> @nul)
      assert [] = values(view, "g", "name", search: "ab" <> String.duplicate(" ", 1_000))
    end

    test "refuses the name of a view past 255 bytes, or with a NUL" do
      {:ok, view, _html} = live(build_conn(), "/input")
      save = &push(view, "g", "masu:view", %{"action" => "save", "name" => &1})

      assert %{"id" => _} = save.(String.duplicate("a", 255))

      assert %{"error" => "A view's name is longer than 255 bytes."} =
               save.(String.duplicate("a", 256))

      # 130 characters, 260 bytes: over a column of 255 characters never, over the bound.
      assert %{"error" => "A view's name is longer than 255 bytes."} =
               save.(String.duplicate("é", 130))

      assert %{"error" => "A view's name has a NUL character."} = save.("a" <> @nul)

      # The name is checked as it is saved: trimmed.
      padding = String.duplicate(" ", 300)
      assert %{"id" => _} = save.(padding <> "Mine" <> padding)
      assert %{"error" => "A view needs a name."} = save.(padding)
    end

    test "refuses an edited cell with a NUL, and saves the others" do
      {:ok, view, _html} = live(build_conn(), "/edit/people")

      assert {:error, [{2, "name", "The text of this cell has a NUL character."}]} =
               edit(view, "people", [{2, "name", "Al" <> @nul <> "an"}, {2, "age", "42"}])

      assert %{"name" => "alan Turing", "age" => 42} = Enum.at(rows(view, "people"), 1)
    end

    test "refuses a new row's cell with a NUL, and saves the other rows" do
      {:ok, view, _html} = live(build_conn(), "/rows/tasks")
      before = total(view, "tasks")

      assert {:error, [{:error, errors}, {:ok, _id}]} =
               add_rows(view, "tasks", [%{title: "a" <> @nul}, %{title: "Fine"}])

      assert {"title", "The text of this cell has a NUL character."} in errors
      assert total(view, "tasks") == before + 1
    end
  end

  describe "the history of a grid" do
    setup do
      Masu.History.Memory.clear()
      MasuTest.Ledger.reset!()
      :ok
    end

    defp entry(key) do
      %Masu.History.Entry{
        grid: "ledger",
        row_id: 1,
        key: key,
        op: :update,
        before: 1,
        after: 2,
        at: ~U[2026-01-01 00:00:00Z]
      }
    end

    test "a key that is not a column's has no history, and does not reach the store" do
      {:ok, view, _html} = live(build_conn(), "/ledger?store=strict")
      :ok = Masu.History.Memory.record([entry("amount"), entry("gone")])

      assert %{"entries" => [%{"key" => "amount"}]} =
               push(view, "ledger", "masu:history", %{"id" => 1, "key" => "amount"})

      assert %{"entries" => []} =
               push(view, "ledger", "masu:history", %{"id" => 1, "key" => "gone"})

      assert %{"entries" => []} =
               push(view, "ledger", "masu:history", %{"id" => 1, "key" => "a" <> @nul})

      assert %{"entries" => [_, _]} = push(view, "ledger", "masu:history", %{"id" => 1})
    end

    test "a batch with a NUL, or that is no token, is an unknown batch" do
      {:ok, view, _html} = live(build_conn(), "/ledger?store=strict")

      for batch <- ["a" <> @nul, String.duplicate("a", 65)] do
        assert %{"restored" => 0, "errors" => []} =
                 push(view, "ledger", "masu:history_restore", %{"batch" => batch})
      end
    end
  end

  defp grid_query(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#g")
    |> LazyHTML.attribute("data-masu")
    |> hd()
    |> JSON.decode!()
    |> Map.fetch!("query")
  end
end

defmodule Masu.AsyncTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Masu.Test

  @endpoint MasuTest.Endpoint

  defp config(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#people")
    |> LazyHTML.attribute("data-masu")
    |> hd()
    |> JSON.decode!()
  end

  defp push(view, event, payload) do
    view |> element("#people") |> render_hook(event, payload)
    %{proxy: {ref, _topic, _pid}} = view
    assert_receive {^ref, {:reply, reply}}
    reply
  end

  defp names(view), do: view |> rows("people") |> Enum.map(& &1["name"])

  describe "a slow source read in a task (load={:async})" do
    test "reads, sorts and filters as an inline grid does" do
      {:ok, view, _html} = live(build_conn(), "/async")
      render_async(view)

      assert total(view, "people") == 5
      view |> sort("people", {"age", :desc}) |> filter("people", [{"age", :lt, 80}])
      assert names(view) == ["Edsger Dijkstra", "alan Turing", "Ada Lovelace"]
    end

    test "the LiveView answers at once, and the grid says it runs until its rows come" do
      {:ok, view, _html} = live(build_conn(), "/async?delay=150")
      render_async(view, 2000)

      reply =
        push(view, "masu:query", %{
          "sorts" => [%{"key" => "age", "dir" => "desc"}],
          "filters" => []
        })

      assert %{"pending" => true} = reply
      assert has_element?(view, ~s(#people-state .masu-running[role="status"]), "Running…")
      assert config(view)["running"] == true

      render_async(view, 2000)
      refute has_element?(view, "#people-state .masu-running")
      assert config(view)["running"] == false
      assert hd(config(view)["query"]["sorts"]) == %{"key" => "age", "dir" => "desc"}
    end

    test "Stop keeps the rows and the query it had" do
      {:ok, view, _html} = live(build_conn(), "/async?delay=300")
      render_async(view, 2000)
      before = config(view)

      push(view, "masu:query", %{"sorts" => [%{"key" => "age", "dir" => "desc"}], "filters" => []})

      view |> element("#people-state .masu-state-button") |> render_click()
      render_async(view, 2000)

      refute has_element?(view, "#people-state .masu-running")
      assert config(view)["query"] == before["query"]
      assert config(view)["revision"] == before["revision"]
    end

    test "an error of the source shows in the grid, with Run again, and the LiveView lives" do
      {:ok, view, _html} = live(build_conn(), "/async?fail=true")
      render_async(view, 2000)

      assert has_element?(
               view,
               ~s(#people-state .masu-error[role="alert"]),
               "the warehouse is down"
             )

      assert has_element?(view, "#people-state .masu-state-button", "Run again")
      assert render(view) =~ "people"
    end

    test "a read longer than timeout stops, and the grid says so" do
      {:ok, view, _html} = live(build_conn(), "/async?delay=400&timeout=50")
      Process.sleep(150)

      assert has_element?(view, "#people-state .masu-error", "The query took too long")
      refute has_element?(view, "#people-state .masu-running")
    end
  end

  describe "a controlled grid (on_query): the LiveView runs its query" do
    test "the grid shows the rows it is given, a page of them, with the LiveView's count" do
      {:ok, view, _html} = live(build_conn(), "/controlled")
      render_async(view)

      assert total(view, "people") == 5
      assert names(view) == ["Ada Lovelace", "alan Turing"]
    end

    test "the person's sort, filter and page go to the LiveView: one run each" do
      {:ok, view, _html} = live(build_conn(), "/controlled")
      render_async(view)

      runs = fn ->
        view
        |> element("#runs")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()
        |> String.to_integer()
      end

      first = runs.()

      sort(view, "people", {"age", :desc})
      render_async(view)
      assert runs.() == first + 1
      assert names(view) == ["Barbara Liskov", "Grace Hopper"]

      filter(view, "people", [{"age", :lt, 80}])
      render_async(view)
      assert runs.() == first + 2
      assert total(view, "people") == 3

      assert [_id] = page(view, "people", 2)
      render_async(view)
      assert runs.() == first + 3

      assert view |> rows("people", from: 2, count: 2) |> Enum.map(& &1["name"]) == [
               "Ada Lovelace"
             ]
    end

    test "one sort at a time (multi_sort={false})" do
      {:ok, view, _html} = live(build_conn(), "/controlled")
      render_async(view)

      push(view, "masu:query", %{
        "sorts" => [%{"key" => "age", "dir" => "asc"}, %{"key" => "name", "dir" => "asc"}],
        "filters" => []
      })

      assert config(view)["query"]["sorts"] == [%{"key" => "age", "dir" => "asc"}]
      assert config(view)["multiSort"] == false
    end

    test "says it runs while the LiveView's query runs (loading)" do
      {:ok, view, _html} = live(build_conn(), "/controlled?delay=200")
      render_async(view, 2000)
      push(view, "masu:query", %{"sorts" => [%{"key" => "age", "dir" => "asc"}], "filters" => []})
      assert config(view)["running"] == true
      render_async(view, 2000)
      assert config(view)["running"] == false
    end
  end

  describe "declaring" do
    import Phoenix.Component, only: [sigil_H: 2]
    import Masu.Components

    test "a controlled grid does not take what reads or writes rows beyond its own" do
      assigns = %{rows: [%{id: 1, name: "a"}], on_query: fn _ -> :ok end}

      assert_raise ArgumentError, ~r/on_query .* and selectable, export/, fn ->
        rendered_to_string(~H"""
        <.data_grid id="g" rows={@rows} on_query={@on_query} selectable export>
          <:col field={:name} />
        </.data_grid>
        """)
      end
    end
  end
end

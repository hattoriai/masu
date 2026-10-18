defmodule Masu.EditorsTest do
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

  # The event the browser sends, without Masu.Test's checks.
  defp push(view, event, payload) do
    view |> element("#people") |> render_hook(event, payload)
    %{proxy: {ref, _topic, _pid}} = view
    assert_receive {^ref, {:reply, reply}}
    reply
  end

  test "a column says its editor to the browser: a form, or one of the browser's with its options" do
    {:ok, view, _html} = live(build_conn(), "/editors")
    editors = Map.new(config(view)["columns"], &{&1["key"], &1["editor"]})

    assert editors == %{
             "name" => %{"kind" => "form"},
             "stay" => %{"kind" => "form"},
             "color" => %{
               "kind" => "js",
               "name" => "color",
               "options" => %{"swatches" => ["#ff0000", "#00ff00"]}
             }
           }
  end

  test "a form editor opens with the cell's field, the row, the column and the scope" do
    {:ok, view, _html} = live(build_conn(), "/editors")
    open_editor(view, "people", 1, :name)

    assert has_element?(
             view,
             ~s(#people-cell-editor[role="dialog"][aria-labelledby="people-cell-label"])
           )

    assert has_element?(view, ~s(#people-cell-form #name-input[name="cell[value]"][value="Ada"]))
    assert view |> element("#name-editor-of") |> render() =~ "1 name Ada ada"

    close_editor(view, "people")
    refute has_element?(view, "#people-cell-editor")
  end

  test "what the form posts is the value: text, or params of a map" do
    {:ok, view, _html} = live(build_conn(), "/editors")
    open_editor(view, "people", 1, :stay)
    assert has_element?(view, ~s(#stay-from[name="cell[value][from]"][value="2027-03-15"]))

    assert edit(view, "people", [{1, :stay, %{"from" => "2027-04-01", "to" => "2027-04-03"}}]) ==
             :ok

    assert [%{"stay" => stay} | _] = rows(view, "people")
    assert stay =~ "2027-04-01"

    assert {:error, [{1, "stay", "ends before it starts"}]} =
             edit(view, "people", [{1, :stay, %{"from" => "2027-04-09", "to" => "2027-04-03"}}])
  end

  test "an edit carries the version the editor opened with: a cell changed meanwhile is refused" do
    {:ok, view, _html} = live(build_conn(), "/editors")
    assert %{"version" => version} = push(view, "masu:cell_editor", %{"id" => 1, "key" => "name"})

    assert %{"errors" => []} =
             push(view, "masu:edit", %{
               "edits" => [
                 %{"id" => 1, "key" => "name", "value" => "Ada L.", "version" => version}
               ]
             })

    # The same version again: the name is no longer the one it saw.
    assert %{"errors" => [[1, "name", "Changed by someone else meanwhile.", "Ada L."]]} =
             push(view, "masu:edit", %{
               "edits" => [
                 %{"id" => 1, "key" => "name", "value" => "Ada B.", "version" => version}
               ]
             })
  end

  test "the server opens no editor for a cell that does not edit, nor takes maps for a column of the browser's" do
    {:ok, view, _html} = live(build_conn(), "/editors")
    # Grace's row is locked for her name.
    assert push(view, "masu:cell_editor", %{"id" => 2, "key" => "name"}) == %{"error" => "editor"}

    assert push(view, "masu:cell_editor", %{"id" => 1, "key" => "color"}) == %{
             "error" => "editor"
           }

    assert push(view, "masu:cell_editor", %{"id" => 9, "key" => "stay"}) == %{"error" => "editor"}
    refute has_element?(view, "#people-cell-editor")

    assert {:error, [{1, "color", "This cell cannot be edited."}]} =
             edit(view, "people", [{1, :color, %{"r" => "1"}}])

    assert edit(view, "people", [{1, :color, "#00ff00"}]) == :ok
  end

  test "a value of a type of its own goes to the browser as Masu.Wire says" do
    assert Masu.Value.to_wire(%MasuTest.Stay{from: ~D[2027-03-15], to: ~D[2027-03-20]}) ==
             "2027-03-15/2027-03-20"

    assert Masu.Value.to_wire(%URI{host: "example.com", scheme: "https"}) == "https://example.com"
  end
end

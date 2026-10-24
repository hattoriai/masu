defmodule Masu.ViewsTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Masu.Test

  alias Masu.Views.Memory
  alias MasuTest.Repo

  @endpoint MasuTest.Endpoint

  setup do
    Memory.clear()
    Repo.query!("DELETE FROM masu_views")
    :ok
  end

  defp open(path) do
    {:ok, view, _html} = live(build_conn(), path)
    view
  end

  defp grid_config(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#people")
    |> LazyHTML.attribute("data-masu")
    |> hd()
    |> JSON.decode!()
  end

  describe "layout" do
    test "a hidden column does not show, and still filters; the pinned show first" do
      view = open("/views")

      assert columns(view, "people") == ["Id", "Name", "City", "Age"]
      assert rows(view, "people") |> hd() |> Map.keys() |> Enum.sort() == ~w(age city id name)

      filter(view, "people", [{"admin", :eq, true}])
      assert ids(view, "people") == [1, 3]
    end

    test "moving, hiding, pinning and resizing change the columns and their rows" do
      view =
        "/views"
        |> open()
        |> layout("people",
          order: ~w(name age city id admin),
          hidden: ["city"],
          pinned: %{age: :end},
          widths: %{name: 300}
        )

      assert columns(view, "people") == ["Name", "Id", "Admin", "Age"]
      assert %{"name" => "Ada Lovelace", "admin" => true} = hd(rows(view, "people"))

      config = grid_config(view)
      assert %{"key" => "name", "width" => 300} = hd(config["columns"])
      assert %{"key" => "age", "pinned" => "end"} = List.last(config["columns"])
      assert Enum.map(config["catalog"], & &1["key"]) == ~w(name city id admin age)
      assert Enum.find(config["catalog"], &(&1["key"] == "city"))["hidden"]
      assert config["columnsMenu"]
      # The filter bar, unless the grid says otherwise.
      assert config["filterBar"]
    end
  end

  describe "the URL" do
    test "a link opens its view" do
      view = open("/views?people[sort]=-age&people[hide]=city&people[q]=a")

      # `hide` is every hidden column: Admin, hidden by the grid, shows.
      assert columns(view, "people") == ["Id", "Name", "Age", "Admin"]
      assert ids(view, "people") == [5, 3, 4, 2, 1]
      assert view(view, "people") == %{"sort" => "-age", "hide" => "city", "q" => "a"}
    end

    test "the view goes into the URL as it changes, and back to none" do
      view = open("/views")
      sort(view, "people", {"age", :desc})
      assert_patch(view, "/views?people[sort]=-age")

      layout(view, "people", hidden: ["city", "admin"])
      assert_patch(view, "/views?people[hide]=admin%2Ccity&people[sort]=-age")

      apply_view(view, "people", %{})
      assert_patch(view, "/views")
    end

    test "a new URL (the back button) applies its view" do
      view = open("/views")
      render_patch(view, "/views?people[sort]=-age")
      assert ids(view, "people") == [5, 3, 4, 2, 1]
      assert view(view, "people") == %{"sort" => "-age"}
    end

    test "parts of a link that no longer apply are left out, and the grid says so" do
      view =
        open(
          "/views?people[sort]=-gone,age&people[filter][0][key]=age&people[filter][0][op]=gt&people[filter][0][value]=old"
        )

      assert ids(view, "people") == [1, 2, 4, 3, 5]
      assert grid_config(view)["notice"] == [1, "gone, age"]
      assert render(view) =~ "Part of this view no longer applies: {label}"
    end
  end

  describe "views" do
    test "the person's last view comes back" do
      view = open("/views?user=grace")
      sort(view, "people", {"age", :desc})
      layout(view, "people", hidden: ["city", "admin"])

      again = open("/views?user=grace")
      assert columns(again, "people") == ["Id", "Name", "Age"]
      assert ids(again, "people") == [5, 3, 4, 2, 1]

      assert columns(open("/views?user=edsger"), "people") == ["Id", "Name", "City", "Age"]
    end

    test "a link wins over the last view" do
      open("/views?user=grace") |> sort("people", {"age", :desc})
      view = open("/views?user=grace&people[sort]=age")
      assert ids(view, "people") == [1, 2, 4, 3, 5]
    end

    test "named views: saved, listed (shared ones for everyone), applied and deleted" do
      ada = open("/views?user=ada")
      search(ada, "people", "a")
      assert %{"id" => mine} = view_event(ada, %{"action" => "save", "name" => "Mine"})

      layout(ada, "people", hidden: ["city", "admin"])

      assert %{"id" => shared} =
               view_event(ada, %{"action" => "save", "name" => "Team", "shared" => true})

      assert [
               %{"name" => "Mine", "mine" => true, "current" => false},
               %{"name" => "Team", "shared" => true, "current" => true}
             ] = grid_config(ada)["views"]

      alan = open("/views?user=alan")
      assert [%{"name" => "Team", "mine" => false, "id" => ^shared}] = grid_config(alan)["views"]
      view_event(alan, %{"action" => "apply", "id" => shared})
      assert columns(alan, "people") == ["Id", "Name", "Age"]

      # Someone else's view is not theirs to delete.
      view_event(alan, %{"action" => "delete", "id" => shared})
      assert length(grid_config(open("/views?user=alan"))["views"]) == 1

      view_event(ada, %{"action" => "apply", "id" => mine})
      assert columns(ada, "people") == ["Id", "Name", "City", "Age"]
      assert view(ada, "people") == %{"q" => "a"}

      view_event(ada, %{"action" => "reset"})
      assert view(ada, "people") == %{}

      view_event(ada, %{"action" => "delete", "id" => mine})
      assert [%{"name" => "Team"}] = grid_config(ada)["views"]
    end

    test "a scope keeps its views apart from another's" do
      for store <- ~w(memory ecto) do
        ada = open("/views?store=#{store}&user=ada&account=1")
        sort(ada, "people", {"age", :desc})
        view_event(ada, %{"action" => "save", "name" => "Oldest", "shared" => true})

        assert [%{"name" => "Oldest"}] =
                 grid_config(open("/views?store=#{store}&user=alan&account=1"))["views"]

        other = open("/views?store=#{store}&user=alan&account=2")
        assert grid_config(other)["views"] == []

        # The same person in another account starts with no last view.
        assert view(open("/views?store=#{store}&user=ada&account=2"), "people") == %{}

        assert view(open("/views?store=#{store}&user=ada&account=1"), "people") == %{
                 "sort" => "-age"
               }
      end
    end

    test "a view needs a name" do
      assert %{"error" => "A view needs a name."} =
               view_event(open("/views"), %{"action" => "save", "name" => " "})
    end

    test "the Ecto store keeps the last view and named views" do
      view = open("/views?store=ecto&user=grace")
      sort(view, "people", {"age", :desc})

      assert %{"id" => id} =
               view_event(view, %{"action" => "save", "name" => "Oldest", "shared" => true})

      again = open("/views?store=ecto&user=grace")
      assert ids(again, "people") == [5, 3, 4, 2, 1]
      assert [%{"id" => ^id, "name" => "Oldest", "mine" => true}] = grid_config(again)["views"]

      alan = open("/views?store=ecto&user=alan")
      assert [%{"name" => "Oldest", "mine" => false}] = grid_config(alan)["views"]

      view_event(again, %{"action" => "save", "name" => "Oldest", "shared" => false})
      assert grid_config(open("/views?store=ecto&user=alan"))["views"] == []

      view_event(again, %{"action" => "delete", "id" => id})
      assert grid_config(again)["views"] == []
    end
  end

  # The views menu's events, with their reply.
  defp view_event(view, payload) do
    render(view)
    view |> element("#people") |> render_hook("masu:view", payload)
    %{proxy: {ref, _topic, _pid}} = view

    receive do
      {^ref, {:reply, reply}} -> reply
    after
      1000 -> flunk("no reply")
    end
  end
end

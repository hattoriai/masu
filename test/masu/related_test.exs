defmodule Masu.RelatedTest do
  # A grid's columns of related rows, from the database and from a list,
  # through Masu.Test as an app's tests use them.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Masu.Test

  @endpoint MasuTest.Endpoint

  defp open(source), do: build_conn() |> live("/sales?source=#{source}") |> elem(1)

  defp numbers(view), do: view |> rows("sales") |> Enum.map(& &1["number"])

  defp column(view, key) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#sales")
    |> LazyHTML.attribute("data-masu")
    |> hd()
    |> JSON.decode!()
    |> Map.fetch!("columns")
    |> Enum.find(&(&1["key"] == key))
  end

  for source <- ~w(ecto list) do
    describe "from #{source}" do
      test "shows the values of the related rows, the many as a list" do
        view = open(unquote(source))
        [first | _] = rows(view, "sales")

        assert first["customer.name"] == "Bea"
        assert first["company"] == "Globex"
        assert Enum.sort(first["tags"]) == ~w(gift urgent)
        assert columns(view, "sales") == ["Number", "Amount", "Customer", "Company", "Tags"]
      end

      test "sorts, filters and searches by a path" do
        view = open(unquote(source))

        view
        |> filter("sales", [{"company", :eq, "Acme"}])
        |> sort("sales", [{"customer.name", :desc}, "number"])

        assert numbers(view) == ~w(S-7 S-2 S-5)
        assert total(view, "sales") == 3

        view |> filter("sales", []) |> search("sales", "dor")
        assert numbers(view) == ~w(S-4)
      end

      test "a column of many values filters by has any of, all of and none of, and does not sort" do
        view = open(unquote(source))
        tags = column(view, "tags")

        assert tags["many"] == true
        assert tags["sortable"] == false
        assert tags["filters"] == ~w(in all_of none_of is_nil not_nil)
        refute column(view, "customer.name")["many"]
        refute column(view, "customer.name")["editable"]

        view |> filter("sales", [{"tags", :all_of, ["gift", "urgent"]}])
        assert numbers(view) == ~w(S-1 S-5)

        view |> filter("sales", [{"tags", :is_nil}])
        assert numbers(view) == ~w(S-3 S-6 S-7)

        view |> filter("sales", [])

        assert values(view, "sales", "tags") |> Enum.sort() == [
                 {"bulk", 2},
                 {"gift", 3},
                 {"urgent", 3}
               ]
      end
    end
  end

  test "a controlled grid sorts and filters by a path: the LiveView gets its key" do
    {:ok, view, _html} = live(build_conn(), "/controlled-sales")

    view
    |> sort("sales", {"customer.name", :desc})
    |> filter("sales", [{"customer.name", :eq, "Ana"}])

    asked = view |> element("#asked") |> render()
    assert asked =~ "key: &quot;customer.name&quot;, direction: :desc"
    assert asked =~ "key: &quot;customer.name&quot;, op: :eq, value: &quot;Ana&quot;"
  end
end

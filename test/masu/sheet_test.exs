defmodule Masu.SheetTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset
  import Ecto.Query

  alias Masu.Sheet

  defp orders do
    Sheet.new(
      id: "orders",
      source: from(o in MasuTest.Order, where: o.status != "void"),
      repo: MasuTest.Repo,
      columns: [
        [field: :number],
        [field: :customer],
        [field: :status, type: :enum],
        [field: :total, type: :decimal]
      ]
    )
  end

  defp people(attrs \\ []) do
    Sheet.new(
      Keyword.merge(
        [
          id: "people",
          rows: MasuTest.People.all(),
          changeset: &changeset/2,
          columns: [
            [field: :name],
            [field: :age, type: :integer],
            [field: :city, editable: false]
          ]
        ],
        attrs
      )
    )
  end

  def changeset(person, params) do
    types = %{name: :string, age: :integer}

    {person, types}
    |> cast(params, Map.keys(types))
    |> validate_required([:name])
    |> validate_number(:age, greater_than: 0, less_than: 150)
  end

  test "reads the rows of an Ecto source, in an order, filtered, as a person would" do
    sheet = orders()

    assert {:ok, %{rows: rows, total: total}} =
             Sheet.rows(sheet, sort: [{"total", :desc}], filters: [{"status", :eq, "paid"}])

    assert total == length(rows)
    assert rows != []
    assert Enum.all?(rows, &(&1.status == "paid"))
    assert rows == Enum.sort_by(rows, & &1.total, {:desc, Decimal})

    [first | _] = rows
    map = Sheet.to_map(sheet, first)
    assert map["id"] == first.id
    assert map["status"] == "paid"
    assert map["total"] == Decimal.to_string(first.total, :normal)

    assert [^first] = Sheet.fetch(sheet, [first.id])
    assert Sheet.can(sheet) == %{edit: false, create: false, delete: false}
  end

  test "says what is wrong with a query, in words" do
    assert {:error, message} = Sheet.rows(orders(), filters: [{"nope", :eq, 1}])
    assert is_binary(message)
  end

  test "edits cells through the changeset and the read-only rules" do
    sheet = people()
    assert Sheet.can(sheet).edit

    assert %{saved: [saved], errors: errors} =
             Sheet.update(sheet, [
               %{"id" => 1, "key" => "name", "value" => "Ada King"},
               %{"id" => 1, "key" => "city", "value" => "Paris"},
               %{"id" => 2, "key" => "age", "value" => 400}
             ])

    assert saved.name == "Ada King"

    assert Enum.sort(errors) == [
             [1, "city", "This cell cannot be edited."],
             [2, "age", "must be less than 150"]
           ]
  end

  test "refuses a cell that changed since it was seen" do
    assert %{saved: [], errors: [[1, "name", _message, "Ada Lovelace"]]} =
             Sheet.update(people(), [
               %{"id" => 1, "key" => "name", "value" => "Ada", "before" => "Countess"}
             ])
  end

  test "the people who have the grid open see the change, in the color of who made it" do
    topic = "sheet-#{System.unique_integer([:positive])}"
    :ok = Phoenix.PubSub.subscribe(MasuTest.PubSub, topic)
    sheet = people(live: {MasuTest.PubSub, topic})

    # From another process, as an agent's would be: broadcast_from leaves out the writer.
    Task.async(fn ->
      Sheet.update(sheet, [%{"id" => 2, "key" => "name", "value" => "Alan"}],
        user: %{id: "agent:1", name: "Assistant", color: "#be185d"}
      )
    end)
    |> Task.await()

    assert_receive {Masu.Live, ^topic,
                    {:upsert, %{id: 2, name: "Alan"}, %{name: "Assistant", color: "#be185d"}}}
  end

  test "a grid that neither adds nor deletes says so" do
    sheet = people()

    assert %{deleted: [], errors: [[1, "This grid does not delete rows."]]} =
             Sheet.delete(sheet, [1])
  end

  test "needs an id, rows or a source, and row ids" do
    assert_raise ArgumentError, ~r/id/, fn -> Sheet.new(rows: []) end
    assert_raise ArgumentError, ~r/rows or a source/, fn -> Sheet.new(id: "x") end

    assert_raise ArgumentError, ~r/position/, fn ->
      Sheet.new(id: "x", rows: [], row_id: :position)
    end
  end
end

defmodule Masu.SheetLiveTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Masu.Test

  @endpoint MasuTest.Endpoint

  test "one definition: the LiveView's grid, and the sheet whose edits it shows" do
    topic = "sheet-live-#{System.unique_integer([:positive])}"
    {:ok, view, _html} = live(build_conn(), "/sheet/#{topic}")
    assert view |> rows("people") |> hd() |> Map.fetch!("name") == "Ada Lovelace"

    sheet = Masu.Sheet.new(MasuTest.SheetLive.grid(topic))

    Task.async(fn ->
      Masu.Sheet.update(sheet, [%{"id" => 1, "key" => "name", "value" => "Ada King"}],
        user: %{id: "agent:1", name: "Assistant"}
      )
    end)
    |> Task.await()

    assert view |> rows("people") |> hd() |> Map.fetch!("name") == "Ada King"
  end
end

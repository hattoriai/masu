defmodule MasuTest.People do
  @moduledoc "People for the tests: a list that the grid sorts, filters and searches."

  def all do
    [
      %{
        id: 1,
        name: "Ada Lovelace",
        city: "London",
        age: 36,
        born: ~D[1815-12-10],
        admin: true,
        balance: Decimal.new("120.50")
      },
      %{
        id: 2,
        name: "alan Turing",
        city: "Wilmslow",
        age: 41,
        born: ~D[1912-06-23],
        admin: false,
        balance: Decimal.new("-3.25")
      },
      %{
        id: 3,
        name: "Grace Hopper",
        city: "Arlington",
        age: 85,
        born: ~D[1906-12-09],
        admin: true,
        balance: nil
      },
      %{
        id: 4,
        name: "Edsger Dijkstra",
        city: "Nuenen",
        age: 72,
        born: ~D[1930-05-11],
        admin: false,
        balance: Decimal.new("0")
      },
      %{
        id: 5,
        name: "Barbara Liskov",
        city: nil,
        age: 86,
        born: ~D[1939-11-07],
        admin: false,
        balance: Decimal.new("99.99")
      }
    ]
  end
end

defmodule MasuTest.PeopleLive do
  @moduledoc "A LiveView with a grid of a list, for the tests."
  use Phoenix.LiveView

  import Masu.Components

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, people: MasuTest.People.all())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.data_grid id="people" rows={@people} label="People" searchable sort={[{:age, :desc}]}>
      <:col :let={person} field={:name}><strong>{person.name}</strong></:col>
      <:col field={:city} />
      <:col field={:age} type={:integer} />
      <:col field={:born} type={:date} />
      <:col field={:admin} type={:boolean} />
      <:col field={:balance} type={:decimal} />
      <:col key="initials" value={&initials/1} label="Initials" />
    </.data_grid>
    <button id="add" phx-click="add">Add</button>
    """
  end

  @impl true
  def handle_event("add", _params, socket) do
    person = %{
      id: 6,
      name: "Donald Knuth",
      city: "Milwaukee",
      age: 88,
      born: ~D[1938-01-10],
      admin: false,
      balance: Decimal.new("1")
    }

    {:noreply, update(socket, :people, &(&1 ++ [person]))}
  end

  defp initials(person) do
    person.name |> String.split() |> Enum.map_join(&String.first/1) |> String.upcase()
  end
end

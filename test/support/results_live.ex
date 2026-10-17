defmodule MasuTest.ResultsSource do
  @moduledoc """
  A query tool's results, as Lotus gives them: column names, and rows as
  lists of values in their order, of no types. It runs a list.
  """
  @behaviour Masu.Source

  alias Masu.Source.List, as: ListSource

  @impl true
  def init(opts, grid_opts) do
    %{
      columns: Keyword.fetch!(opts, :columns),
      list: ListSource.init(Keyword.fetch!(opts, :rows), grid_opts)
    }
  end

  @impl true
  def columns(%{columns: columns}), do: columns

  @impl true
  def prepare(state, query, columns),
    do: %{state | list: ListSource.prepare(state.list, query, columns)}

  @impl true
  def count(state), do: ListSource.count(state.list)
  @impl true
  def rows(state, offset, limit), do: ListSource.rows(state.list, offset, limit)
  @impl true
  def values(state, column, query, columns, opts),
    do: ListSource.values(state.list, column, query, columns, opts)
end

defmodule MasuTest.ResultsLive do
  @moduledoc """
  Results of a query tool, two ways: rows as lists with `columns`
  (`?as=columns`), or a source that gives its columns (the default). A
  button runs another query, of other columns.
  """
  use Phoenix.LiveView

  import Masu.Components

  @people {["name", "age", "born", "balance", "admin", "note"],
           [
             ["Ada", 36, ~D[1815-12-10], Decimal.new("120.50"), true, "first"],
             ["Alan", 41, ~D[1912-06-23], Decimal.new("8.25"), false, nil],
             ["Grace", 85, ~D[1906-12-09], Decimal.new("40.00"), true, 12],
             ["Edsger", 72, nil, nil, false, "last"]
           ]}

  @cities {[%{key: "city", label: "City"}, "people", "age"],
           [["London", 9_000_000, 2.5], ["Lisbon", 550_000, 3], ["Tokyo", 14_000_000, nil]]}

  @impl true
  def mount(params, _session, socket),
    do: {:ok, assign(socket, as: params["as"] || "source", result: @people)}

  @impl true
  def handle_event("cities", _params, socket), do: {:noreply, assign(socket, result: @cities)}

  @impl true
  def render(assigns) do
    {columns, rows} = assigns.result
    assigns = assign(assigns, columns: columns, rows: rows)

    ~H"""
    <button id="cities" phx-click="cities">Cities</button>
    <%= if @as == "columns" do %>
      <.data_grid id="results" rows={@rows} columns={@columns} row_id={:position} />
    <% else %>
      <.data_grid id="results" source={{MasuTest.ResultsSource, columns: @columns, rows: @rows}} row_id={:position} />
    <% end %>
    """
  end
end

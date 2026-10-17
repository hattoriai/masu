defmodule MasuTest.LotusLikeSource do
  @moduledoc """
  A source that filters as Lotus does: `= ≠ > < ≥ ≤`, LIKE (`contains`),
  null and not null; no "between", no "is one of". It runs a list
  (Masu.Source.List), and raises on a filter it would not run.
  """
  @behaviour Masu.Source

  alias Masu.Source.List, as: ListSource

  @ops [:eq, :neq, :gt, :lt, :gte, :lte, :contains, :is_nil, :not_nil]

  @impl true
  def init(opts, grid_opts), do: ListSource.init(Keyword.fetch!(opts, :rows), grid_opts)

  @impl true
  def filters(_state, %Masu.Column{key: "code"}), do: []
  def filters(_state, _column), do: @ops

  @impl true
  def prepare(state, query, columns) do
    check!(query)
    ListSource.prepare(state, query, columns)
  end

  @impl true
  defdelegate count(state), to: ListSource
  @impl true
  defdelegate rows(state, offset, limit), to: ListSource
  @impl true
  defdelegate fetch(state, ids, row_id), to: ListSource

  @impl true
  def values(state, column, query, columns, opts) do
    check!(query)
    ListSource.values(state, column, query, columns, opts)
  end

  defp check!(query) do
    for filter <- query.filters, filter.op not in @ops do
      raise "the source got a filter it does not run: #{inspect(filter)}"
    end
  end
end

defmodule MasuTest.FilterOpsLive do
  @moduledoc "People from a source that runs some filters only (MasuTest.LotusLikeSource)."
  use Phoenix.LiveView

  import Masu.Components

  @impl true
  def mount(_params, _session, socket) do
    rows = Enum.map(MasuTest.People.all(), &Map.put(&1, :code, "P#{&1.id}"))
    {:ok, assign(socket, rows: rows)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.data_grid id="people" source={{MasuTest.LotusLikeSource, rows: @rows}} sort={[:id]} cell_menu>
      <:col field={:name} />
      <:col field={:city} type={:enum} values={~w(London Wilmslow Arlington Nuenen Milwaukee)} />
      <:col field={:age} type={:integer} />
      <:col field={:born} type={:date} />
      <:col field={:code} />
    </.data_grid>
    """
  end
end

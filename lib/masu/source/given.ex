defmodule Masu.Source.Given do
  @moduledoc false
  # The rows of a controlled grid (`on_query`): those the LiveView gives,
  # the rows of its own query from `offset` (a page's), as they are. It
  # neither sorts nor filters: the LiveView ran the query.

  @behaviour Masu.Source

  @impl true
  def init(rows, opts) do
    %{
      rows: rows,
      offset: Keyword.get(opts, :offset, 0),
      total: Keyword.get(opts, :total)
    }
  end

  @impl true
  def prepare(state, _query, _columns), do: state

  # The LiveView runs the query: every column it has, a path too.
  @impl true
  def supports?(_state, _column), do: true

  @impl true
  def count(%{total: total}) when is_integer(total), do: total
  def count(%{rows: rows, offset: offset}), do: offset + length(rows)

  @impl true
  def rows(%{rows: rows, offset: offset}, from, limit),
    do: if(from < offset, do: [], else: Enum.slice(rows, from - offset, limit))

  @impl true
  def fetch(%{rows: rows}, ids, row_id) do
    ids = MapSet.new(ids)
    Enum.filter(rows, &MapSet.member?(ids, Masu.Value.to_wire(row_id.(&1))))
  end

  @impl true
  def locate(%{rows: rows, offset: offset}, id, row_id) do
    case Enum.find_index(rows, &(Masu.Value.to_wire(row_id.(&1)) == id)) do
      nil -> nil
      index -> offset + index
    end
  end
end

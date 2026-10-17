defmodule MasuTest.IdsLive do
  @moduledoc "Grids of rows without ids: by position, by a function, and those that need ids."
  use Phoenix.LiveView

  import Masu.Components

  @impl true
  def mount(params, _session, socket), do: {:ok, assign(socket, case: params["case"] || "plain")}

  # Rows of a report: no id among them.
  defp report, do: for(n <- 1..30, do: %{code: "R#{n}", amount: n * 10})

  @impl true
  def render(%{case: "plain"} = assigns) do
    ~H"""
    <.data_grid id="g" rows={report()}><:col field={:code} /></.data_grid>
    """
  end

  def render(%{case: "position"} = assigns) do
    ~H"""
    <.data_grid id="g" rows={MasuTest.People.all()} row_id={:position} sort={[{:id, :desc}]}>
      <:col field={:id} type={:integer} />
    </.data_grid>
    """
  end

  def render(%{case: "function"} = assigns) do
    ~H"""
    <.data_grid id="g" rows={report()} row_id={& &1.code} selectable><:col field={:code} /></.data_grid>
    """
  end

  def render(%{case: "missing"} = assigns) do
    ~H"""
    <.data_grid id="g" rows={report()} selectable><:col field={:code} /></.data_grid>
    """
  end

  def render(%{case: "position_selectable"} = assigns) do
    ~H"""
    <.data_grid id="g" rows={report()} row_id={:position} selectable><:col field={:code} /></.data_grid>
    """
  end
end

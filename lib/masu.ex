defmodule Masu do
  @moduledoc """
  Masu (枡) adds data grids to a Phoenix app.

  It ships a prebuilt grid bundle and the components that render it: a
  grid that draws only the rows on the screen, asks the server for the
  rows it needs as you scroll, and sorts, filters and searches where the
  rows are, in a list or in your database, so a LiveView shows a hundred
  rows or a million the same way, with no Node.js build step of its own.

  Start with the [Quickstart](quickstart.md), then the
  [Columns](columns.md) and [Sources](sources.md) guides. The main
  modules are `Masu.Components` (the grid), `Masu.Column` (what a column
  shows), `Masu.Source` (where the rows come from), `Masu.Query` (what a
  person asked for) and `Masu.Test` (the test helpers).
  """

  @external_resource "mix.exs"
  @version Mix.Project.config()[:version]

  @doc """
  Returns the current Masu version.

  ## Examples

      iex> Masu.version()
      "#{@version}"

  """
  @spec version() :: String.t()
  def version, do: @version
end

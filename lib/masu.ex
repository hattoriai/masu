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
  person asked for), `Masu.Write` (what a person changes, as your app
  saves it), `Masu.Action` (what your app does with rows) and
  `Masu.Test` (the test helpers).
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

  @typedoc "How a write or an action that went on later (`async`) went."
  @type reply :: :ok | {:ok, String.t()} | {:error, String.t()}

  @doc """
  Says how a write (`Masu.Write.async/1`) or an action (`:async`, see
  `Masu.Action`) that went on later went, from any process: an Oban job,
  a task, on any node of the cluster. `ref` is the write's `ref`, or the
  action's context's.

    * `:ok` - done; the grid reads its rows again;
    * `{:ok, message}` - done, and the grid says `message`;
    * `{:error, message}` - it failed: the grid says so, and the cells of
      a write show their old values again.

  The grid may be gone (the person left): the reply then goes nowhere.
  """
  @spec reply(String.t(), reply()) :: :ok
  def reply(ref, result) when result == :ok or is_tuple(result) do
    {pid, grid, token} = Masu.Ref.decode!(ref)
    Phoenix.LiveView.send_update(pid, Masu.Grid, %{id: grid, masu_reply: {token, result}})
    :ok
  end

  @doc """
  Says how far an action that went on later is: `done` of `total`, which
  the grid shows ("Archive: 300 of 1,204").
  """
  @spec progress(String.t(), non_neg_integer(), non_neg_integer()) :: :ok
  def progress(ref, done, total) when is_integer(done) and is_integer(total) do
    {pid, grid, token} = Masu.Ref.decode!(ref)
    Phoenix.LiveView.send_update(pid, Masu.Grid, %{id: grid, masu_progress: {token, done, total}})
    :ok
  end
end

defmodule Masu.Ref do
  @moduledoc false
  # The reference of a write or an action: the LiveView's process, the
  # grid and a token of its own, as a string that a job's args take.

  @spec new(String.t()) :: {String.t(), String.t()}
  def new(grid) do
    token = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    ref = {self(), grid, token} |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)
    {ref, token}
  end

  @spec decode!(String.t()) :: {pid(), String.t(), String.t()}
  def decode!(ref) when is_binary(ref) do
    with {:ok, binary} <- Base.url_decode64(ref, padding: false),
         {pid, grid, token} when is_pid(pid) and is_binary(grid) and is_binary(token) <-
           safe_term(binary) do
      {pid, grid, token}
    else
      _other -> raise ArgumentError, "not the ref of a Masu write or action: #{inspect(ref)}"
    end
  end

  defp safe_term(binary) do
    :erlang.binary_to_term(binary, [:safe])
  rescue
    ArgumentError -> :error
  end
end

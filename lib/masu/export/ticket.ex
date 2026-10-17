defmodule Masu.Export.Ticket do
  @moduledoc false
  # An export the Export menu made, held for its download: taken once, by
  # the request of the link the browser got, or gone after five minutes,
  # or when the LiveView that made it goes. The link's token names this
  # process, not the export: a link in a browser's history gives nothing.

  use GenServer

  @ttl :timer.minutes(5)

  @doc false
  def ttl, do: @ttl

  @spec start(pid(), term()) :: {:ok, pid()}
  def start(owner, payload), do: GenServer.start(__MODULE__, {owner, payload})

  # The export, once; `:gone` when it was taken, or is no more.
  @spec take(pid()) :: {:ok, term()} | :gone
  def take(pid) when is_pid(pid) do
    GenServer.call(pid, :take)
  catch
    :exit, _reason -> :gone
  end

  @impl GenServer
  def init({owner, payload}) do
    Process.monitor(owner)
    {:ok, payload, @ttl}
  end

  @impl GenServer
  def handle_call(:take, _from, payload), do: {:stop, :normal, {:ok, payload}, nil}

  @impl GenServer
  def handle_info(:timeout, payload), do: {:stop, :normal, payload}
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, payload), do: {:stop, :normal, payload}
  def handle_info(_message, payload), do: {:noreply, payload, @ttl}
end

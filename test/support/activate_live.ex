defmodule MasuTest.ActivateLive do
  @moduledoc """
  Rows that open (`on_row_activate`): `?to=patch` patches the URL to the
  row, `?to=navigate` goes to another page, and with neither the function
  tells the LiveView, which shows what it heard.
  """
  use Phoenix.LiveView

  import Masu.Components

  @rows [
    %{id: 1, name: "Ada", city: "London"},
    %{id: 2, name: "Grace", city: "New York"},
    %{id: 3, name: "Alan", city: "Wilmslow"}
  ]

  @impl true
  def mount(params, _session, socket),
    do: {:ok, assign(socket, to: params["to"], heard: nil, open: nil)}

  @impl true
  def handle_params(params, _uri, socket), do: {:noreply, assign(socket, open: params["open"])}

  @impl true
  def handle_info({:opened, context}, socket),
    do: {:noreply, assign(socket, heard: "#{context.grid} #{context.id} #{context.row.name}")}

  @impl true
  def render(assigns) do
    pid = self()

    assigns =
      assign(assigns,
        rows: @rows,
        activate:
          case assigns.to do
            "patch" -> &{:patch, "/activate?to=patch&open=#{&1.id}"}
            "navigate" -> &{:navigate, "/people?from=#{&1.id}"}
            _send -> &send(pid, {:opened, &1})
          end
      )

    ~H"""
    <p :if={@heard} id="heard">{@heard}</p>
    <p :if={@open} id="open">{@open}</p>
    <.data_grid id="people" rows={@rows} on_row_activate={@activate}>
      <:col field={:name} />
      <:col field={:city} />
    </.data_grid>
    """
  end
end

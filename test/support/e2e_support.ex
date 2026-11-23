defmodule MasuE2E.Support do
  @moduledoc "Helpers for the browser tests (test/e2e)."

  alias Playwright.{Expect, Locator, Page, WebSocketRoute}

  @doc "Opens a page and waits for the LiveView to connect and the grid to draw its rows."
  def open_page(page, path \\ "/") do
    Page.goto!(page, path)
    Expect.to_be_visible!(Page.locator(page, "[data-phx-main].phx-connected"))
    Expect.to_be_visible!(page |> Page.locator(".masu .masu-body .masu-row") |> Locator.first())
  end

  @doc "The scroll box of a grid, which has the grid role and the focus."
  def grid(page, id), do: Page.locator(page, "##{id}-grid")

  @doc "The header cell of a column."
  def header(page, id, key), do: Page.locator(page, ~s(##{id} .masu-hcell[data-key="#{key}"]))

  @doc "The cell of a grid at `row` and `col` (from 0)."
  def cell(page, id, row, col), do: Page.locator(page, "##{id}-r#{row}-c#{col}")

  @doc "The status line of a grid."
  def status(page, id), do: Page.locator(page, "##{id} > .masu-status")

  @doc "The open menu of a grid."
  def menu(page, id), do: Page.locator(page, ~s(##{id} [role="menu"]))

  @doc "An item of the open menu of a grid."
  def item(page, id, name),
    do: page |> menu(id) |> Locator.get_by_role(:menuitem, name: name, exact: true)

  @doc "The cells of the row at `index` (from 0), as the grid shows them."
  def row_text(page, id, index) do
    row = Page.locator(page, ~s(##{id} .masu-body .masu-row[aria-rowindex="#{index + 2}"]))
    row |> Expect.not_() |> Expect.to_have_class!(~r/masu-loading/)

    row
    |> Locator.locator(".masu-cell")
    |> Locator.all_text_contents!()
    |> Enum.map(&String.trim/1)
  end

  @doc "Waits for the grid to apply its last query."
  def settled(page, id) do
    page |> Page.locator("##{id}") |> Expect.not_() |> Expect.to_have_class!(~r/masu-busy/)
  end

  @doc "JS's `Number(text)` of a number's text: an integer or a float."
  def number(text) do
    case Integer.parse(text) do
      {integer, ""} ->
        integer

      _ ->
        {float, ""} = Float.parse(text)
        float
    end
  end

  @doc "A random room name, as `${prefix}-${Date.now()}-${Math.random()...}`."
  def room_name(prefix) do
    "#{prefix}-#{System.system_time(:millisecond)}-#{Base.encode32(:crypto.strong_rand_bytes(5), case: :lower, padding: false)}"
  end

  @doc "A list that listeners append to, as a JS array: `push/2`, `items/1`."
  def collector do
    {:ok, agent} = Agent.start(fn -> [] end)
    agent
  end

  def push(agent, item), do: Agent.update(agent, &(&1 ++ [item]))
  def items(agent), do: Agent.get(agent, & &1)

  @doc """
  A slow network: routes the LiveView's WebSocket and hands the server's
  messages to the page `delay` ms late, in order. Returns a function that
  sets the delay.
  """
  def slow_live_socket(page) do
    {:ok, delay} = Agent.start(fn -> 0 end)

    Page.route_web_socket!(page, ~r"/live/websocket", fn ws ->
      server = WebSocketRoute.connect_to_server(ws)
      relay = spawn(fn -> relay(ws) end)

      WebSocketRoute.on_message(
        server,
        &delayed_send(ws, relay, Agent.get(delay, fn ms -> ms end), &1)
      )
    end)

    fn ms -> Agent.update(delay, fn _ -> ms end) end
  end

  defp delayed_send(ws, _relay, 0, message), do: WebSocketRoute.send(ws, message)

  defp delayed_send(_ws, relay, ms, message),
    do: send(relay, {:send, message, System.monotonic_time(:millisecond) + ms})

  # A handler must return quickly: a relay process sends the delayed
  # messages in order, each at its time, after those before it.
  defp relay(ws) do
    receive do
      {:send, message, at} ->
        Process.sleep(max(at - System.monotonic_time(:millisecond), 0))
        WebSocketRoute.send(ws, message)
        relay(ws)
    end
  end
end

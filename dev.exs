# The Masu development server: `mix dev`, then http://localhost:4099.
#
# One Phoenix endpoint with a few grids, the built bundle from
# priv/static, and a hundred thousand made-up customers in memory. The
# browser tests in e2e/ run against it.
#
# The bundle rebuilds and the page reloads on a change.
#
# Query params of every page: `locale` (a BCP 47 locale), `theme=sumi`,
# `dark=1`.
#
# Environment:
#
#   * PORT - the HTTP port (4099).
#   * MASU_DEV_WATCH - "false" starts no esbuild watcher and no live
#     reload, for the browser tests; the bundle must be built first.

port = "PORT" |> System.get_env("4099") |> String.to_integer()
watch? = System.get_env("MASU_DEV_WATCH") != "false"

Application.put_env(:phoenix, :json_library, JSON)
Logger.configure(level: :info)

Application.put_env(:masu, MasuDev.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  check_origin: false,
  code_reloader: watch?,
  debug_errors: true,
  http: [ip: {127, 0, 0, 1}, port: port],
  live_view: [signing_salt: "masu-dev-live-view-salt"],
  pubsub_server: MasuDev.PubSub,
  render_errors: [formats: [html: MasuDev.ErrorHTML], layout: false],
  secret_key_base: String.duplicate("masu-development-secret-", 3),
  server: true,
  url: [host: "localhost"],
  watchers:
    if(watch?,
      do: [masu_esm: {Esbuild, :install_and_run, [:masu_esm, ~w(--watch)]}],
      else: []
    ),
  live_reload: [
    patterns: [
      ~r"priv/static/.*\.(js|css)$",
      ~r"lib/masu/.*\.ex$"
    ]
  ]
)

defmodule MasuDev.Customers do
  @moduledoc """
  A hundred thousand made-up customers, the same on every start: made
  once, and kept in :persistent_term.
  """

  @first ~w(Ada Alan Grace Edsger Barbara Donald Margaret Ken Radia Frances John Hedy Tim Linus Katherine Dennis Anita Guido José Yukihiro)
  @last ~w(Lovelace Turing Hopper Dijkstra Liskov Knuth Hamilton Thompson Perlman Allen Backus Lamarr Berners-Lee Torvalds Johnson Ritchie Borg Rossum Valim Matsumoto)
  @cities [
    "Lisbon",
    "Porto",
    "London",
    "Tokyo",
    "Kraków",
    "São Paulo",
    "Austin",
    "Berlin",
    "Nairobi",
    "Oslo"
  ]
  @plans ~w(free starter team business enterprise)

  def all do
    case :persistent_term.get(__MODULE__, nil) do
      nil ->
        rows = Enum.map(1..100_000, &customer/1)
        :persistent_term.put(__MODULE__, rows)
        rows

      rows ->
        rows
    end
  end

  defp customer(id) do
    first = pick(@first, id * 7)
    last = pick(@last, id * 13)

    %{
      id: id,
      name: "#{first} #{last}",
      email: "#{String.downcase(first)}.#{String.downcase(last)}#{id}@example.com",
      city: if(rem(id, 17) == 0, do: nil, else: pick(@cities, id * 3)),
      plan: pick(@plans, id * 11),
      seats: rem(id * 37, 250) + 1,
      revenue: Decimal.new(rem(id * 7919, 1_000_000)) |> Decimal.div(100),
      active: rem(id, 5) != 0,
      signed_up: Date.add(~D[2020-01-01], rem(id * 31, 2000)),
      last_seen: DateTime.add(~U[2026-01-01 00:00:00Z], rem(id * 104_729, 25_000_000), :second)
    }
  end

  defp pick(list, n), do: Enum.at(list, rem(n, length(list)))
end

defmodule MasuDev.Layouts do
  @moduledoc """
  The root layout: the style sheets, the import map and the LiveSocket.
  `?theme=sumi` also loads masu-sumi.css.
  """
  use Phoenix.Component

  def root(assigns) do
    conn = assigns.conn

    current =
      if conn.query_string == "",
        do: conn.request_path,
        else: "#{conn.request_path}?#{conn.query_string}"

    assigns =
      assign(assigns,
        sumi: conn.params["theme"] == "sumi",
        current: current,
        links: [
          {"Customers", "/"},
          {"Small", "/small"},
          {"Sumi theme", "/?theme=sumi"},
          {"Sumi dark", "/?theme=sumi&dark=1"}
        ]
      )

    ~H"""
    <!DOCTYPE html>
    <html lang="en" data-theme={@conn.params["dark"] && "dark"}>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>Masu development</title>
        <link rel="stylesheet" href="/assets/masu.css" />
        <link :if={@sumi} rel="stylesheet" href="/assets/masu-sumi.css" />
        <style>
          body { font-family: system-ui, sans-serif; margin: 0; background: #fafaf9; color: #1c1917; }
          body.sumi { background: var(--masu-background); color: var(--masu-text); font-family: var(--masu-font); }
          main { max-width: 72rem; margin: 0 auto; padding: 2rem 1rem; }
          /* The page's own parts take the grid's tokens, so that they follow
             the theme (and the Sumi theme, dark and light) as the grid does. */
          nav { display: flex; gap: 1.25rem; font-size: 0.875rem; }
          nav a { color: var(--masu-muted); text-decoration: none; padding: 0.25rem 0; border-bottom: 2px solid transparent; }
          nav a:hover { color: var(--masu-text); }
          nav a[aria-current="page"] { color: var(--masu-text); border-bottom-color: var(--masu-accent); }
          nav a:focus-visible { outline: none; box-shadow: var(--masu-focus-ring); border-radius: 2px; }
          .badge { display: inline-block; padding: 0 0.5rem; border-radius: 999px; font-size: 0.75rem; line-height: 1.5rem; background: color-mix(in oklab, var(--masu-text) 8%, transparent); color: var(--masu-text); }
          .badge.enterprise { background: color-mix(in oklab, var(--masu-accent) 16%, transparent); color: color-mix(in oklab, var(--masu-accent) 75%, var(--masu-text)); }
          .badge.free { background: transparent; box-shadow: inset 0 0 0 1px var(--masu-border); color: var(--masu-muted); }
        </style>
        <script type="importmap">
          {
            "imports": {
              "phoenix": "/vendor/phoenix/phoenix.mjs",
              "phoenix_live_view": "/vendor/phoenix_live_view/phoenix_live_view.esm.js",
              "masu": "/assets/masu.esm.js"
            }
          }
        </script>
        <script type="module">
          import { Socket } from "phoenix"
          import { LiveSocket } from "phoenix_live_view"
          import { Masu } from "masu"
          const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
          const liveSocket = new LiveSocket("/live", Socket, {
            hooks: { Masu },
            params: { _csrf_token: csrfToken }
          })
          liveSocket.connect()
          window.liveSocket = liveSocket
        </script>
      </head>
      <body class={@sumi && "sumi"}>
        <main>
          <nav>
            <a
              :for={{label, href} <- @links}
              href={href}
              aria-current={href == @current && "page"}
            >
              {label}
            </a>
          </nav>
          {@inner_content}
        </main>
      </body>
    </html>
    """
  end
end

defmodule MasuDev.CustomersLive do
  @moduledoc "A hundred thousand customers in one grid."
  use Phoenix.LiveView

  import Masu.Components

  @impl true
  def mount(params, _session, socket) do
    {:ok, assign(socket, customers: MasuDev.Customers.all(), locale: params["locale"] || "en-GB")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1 id="customers-label">Customers</h1>
    <.data_grid
      id="customers"
      rows={@customers}
      label_id="customers-label"
      searchable
      height="36rem"
      locale={@locale}
    >
      <:col field={:id} type={:integer} width={90} label="ID" />
      <:col field={:name} width={190} />
      <:col field={:email} width={280} />
      <:col field={:city} />
      <:col :let={customer} field={:plan} type={:enum} width={130}>
        <span class={["badge", customer.plan]}>{customer.plan}</span>
      </:col>
      <:col field={:seats} type={:integer} />
      <:col field={:revenue} type={:decimal} />
      <:col field={:active} type={:boolean} />
      <:col field={:signed_up} type={:date} label="Signed up" />
      <:col field={:last_seen} type={:datetime} label="Last seen" />
    </.data_grid>
    """
  end
end

defmodule MasuDev.SmallLive do
  @moduledoc "The smallest grid: a few rows, two columns."
  use Phoenix.LiveView

  import Masu.Components

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, rows: Enum.take(MasuDev.Customers.all(), 8))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Small</h1>
    <.data_grid id="small" rows={@rows} label="A few customers" height="20rem">
      <:col field={:name} />
      <:col field={:email} />
    </.data_grid>
    """
  end
end

defmodule MasuDev.Router do
  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:protect_from_forgery)
    plug(:put_root_layout, html: {MasuDev.Layouts, :root})
  end

  scope "/" do
    pipe_through(:browser)

    live("/", MasuDev.CustomersLive)
    live("/small", MasuDev.SmallLive)
  end
end

defmodule MasuDev.ErrorHTML do
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end

defmodule MasuDev.Endpoint do
  use Phoenix.Endpoint, otp_app: :masu

  @session [store: :cookie, key: "_masu_dev", signing_salt: "masu-dev"]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session]])

  if System.get_env("MASU_DEV_WATCH") != "false" do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
  end

  plug(Plug.Static, at: "/assets", from: Path.expand("priv/static", __DIR__))
  plug(Plug.Static, at: "/vendor/phoenix", from: {:phoenix, "priv/static"})
  plug(Plug.Static, at: "/vendor/phoenix_live_view", from: {:phoenix_live_view, "priv/static"})

  plug(Plug.Parsers, parsers: [:urlencoded, :json], pass: ["*/*"], json_decoder: JSON)
  plug(Plug.Session, @session)
  plug(MasuDev.Router)
end

# The script's process ends after this file, so the server runs in a task
# that stays alive; `mix run --no-halt` keeps the VM up.
Task.async(fn ->
  if watch?, do: {:ok, _apps} = Application.ensure_all_started(:esbuild)

  {:ok, _pid} =
    Supervisor.start_link(
      [{Phoenix.PubSub, name: MasuDev.PubSub}, MasuDev.Endpoint],
      strategy: :one_for_one
    )

  IO.puts("Masu development server: http://localhost:#{port}")
  Process.sleep(:infinity)
end)

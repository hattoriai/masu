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
      revenue: Decimal.new(rem(id * 7919, 1_000_000)) |> Decimal.div(100) |> Decimal.round(2),
      active: rem(id, 5) != 0,
      signed_up: Date.add(~D[2020-01-01], rem(id * 31, 2000)),
      last_seen: DateTime.add(~U[2026-01-01 00:00:00Z], rem(id * 104_729, 25_000_000), :second)
    }
  end

  defp pick(list, n), do: Enum.at(list, rem(n, length(list)))

  @types %{
    name: :string,
    email: :string,
    city: :string,
    plan: :string,
    seats: :integer,
    revenue: :decimal,
    active: :boolean,
    signed_up: :date,
    last_seen: :utc_datetime
  }

  @doc "The rules of an edit in the grid: a schemaless changeset."
  def changeset(customer, params) do
    import Ecto.Changeset

    {customer, @types}
    |> cast(params, Map.keys(@types))
    |> validate_required([:name, :email, :plan, :seats])
    |> validate_format(:email, ~r/^[^@\s]+@[^@\s]+$/, message: "is not an email")
    |> validate_inclusion(:plan, @plans, message: "is not a plan (#{Enum.join(@plans, ", ")})")
    |> validate_number(:seats, greater_than: 0)
    |> validate_number(:revenue, greater_than_or_equal_to: 0)
  end
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
          {"Live", "/live"},
          {"Together", "/together"},
          {"Views", "/views"},
          {"Tree", "/tree"},
          {"Details", "/details"},
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
  @moduledoc """
  A hundred thousand customers in one grid, which edits: the rows of the
  enterprise plan are read-only, and the revenue of a customer that is
  not active.
  """
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
      changeset={&MasuDev.Customers.changeset/2}
      row_editable={&(&1.plan != "enterprise")}
      label_id="customers-label"
      searchable
      height="36rem"
      locale={@locale}
    >
      <:col field={:id} type={:integer} width={90} label="ID" editable={false} />
      <:col field={:name} width={190} />
      <:col field={:email} width={280} />
      <:col field={:city} />
      <:col :let={customer} field={:plan} type={:enum} width={130}>
        <span class={["badge", customer.plan]}>{customer.plan}</span>
      </:col>
      <:col field={:seats} type={:integer} />
      <:col field={:revenue} type={:decimal} editable={& &1.active} />
      <:col field={:active} type={:boolean} />
      <:col field={:signed_up} type={:date} label="Signed up" />
      <:col field={:last_seen} type={:datetime} label="Last seen" />
    </.data_grid>
    """
  end
end

defmodule MasuDev.ViewsLive do
  @moduledoc """
  Ten thousand customers in a grid whose view is the person's own: the
  columns menu shows, hides, pins and moves columns, a drag on a header
  moves it, the view goes into the URL (a link opens it), and the views
  menu saves named views (in memory, `Masu.Views.Memory`). Each browser
  is a person (`?as=Ada`, or "dev").
  """
  use Phoenix.LiveView

  import Masu.Components

  on_mount(Masu.Live)

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     assign(socket,
       customers: Enum.take(MasuDev.Customers.all(), 10_000),
       user: %{id: params["as"] || "dev", name: params["as"] || "dev"},
       locale: params["locale"] || "en-GB"
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1 id="views-label">Views</h1>
    <.data_grid
      id="views"
      rows={@customers}
      label_id="views-label"
      searchable
      columns_menu
      url
      views={Masu.Views.Memory}
      user={@user}
      height="34rem"
      locale={@locale}
    >
      <:col field={:id} type={:integer} width={90} label="ID" pinned={:start} />
      <:col field={:name} width={190} pinned={:start} />
      <:col field={:email} width={280} hidden />
      <:col field={:city} />
      <:col field={:plan} type={:enum} width={130} />
      <:col field={:seats} type={:integer} />
      <:col field={:active} type={:boolean} />
      <:col field={:signed_up} type={:date} label="Signed up" />
      <:col field={:last_seen} type={:datetime} label="Last seen" />
      <:col field={:revenue} type={:decimal} pinned={:end} />
    </.data_grid>
    """
  end
end

defmodule MasuDev.Files do
  @moduledoc "A tree of 22,200 files: 200 folders of 10 folders of 10 files."

  def all do
    :persistent_term.get({__MODULE__, :all}, nil) ||
      tap(build(), &:persistent_term.put({__MODULE__, :all}, &1))
  end

  # Projects are 1..200, their parts 1_000_000 + ..., files 2_000_000 + ...
  defp part(top, mid), do: 1_000_000 + top * 100 + mid

  defp build do
    kinds = ~w(pdf png csv txt mp4)

    for top <- 1..200,
        mid <- [nil | Enum.to_list(1..10)],
        leaf <- if(mid, do: [nil | Enum.to_list(1..10)], else: [nil]) do
      cond do
        is_nil(mid) ->
          %{
            id: top,
            parent_id: nil,
            name: "Project #{top}",
            kind: "folder",
            size: nil,
            modified: day(top)
          }

        is_nil(leaf) ->
          %{
            id: part(top, mid),
            parent_id: top,
            name: "Part #{mid}",
            kind: "folder",
            size: nil,
            modified: day(top + mid)
          }

        true ->
          kind = Enum.at(kinds, rem(top + mid + leaf, 5))

          %{
            id: 2_000_000 + top * 10_000 + mid * 100 + leaf,
            parent_id: part(top, mid),
            name: "File #{leaf}.#{kind}",
            kind: kind,
            size: rem(top * 7919 + mid * 104_729 + leaf * 1299, 9_000_000) + 1000,
            modified: day(top + mid + leaf)
          }
      end
    end
  end

  defp day(n), do: Date.add(~D[2025-01-01], rem(n * 37, 600))
end

defmodule MasuDev.TreeLive do
  @moduledoc """
  A tree of 22,200 rows: → opens a folder, ← closes it, * opens every
  folder beside it; a filter keeps the files that match and their folders.
  """
  use Phoenix.LiveView

  import Masu.Components

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, files: MasuDev.Files.all())}

  @impl true
  def render(assigns) do
    ~H"""
    <h1 id="tree-label">Tree</h1>
    <.data_grid id="files" rows={@files} tree={:parent_id} label_id="tree-label" searchable height="34rem">
      <:col field={:name} width={320} />
      <:col field={:kind} type={:enum} width={120} />
      <:col field={:size} type={:integer} />
      <:col field={:modified} type={:date} />
    </.data_grid>
    """
  end
end

defmodule MasuDev.DetailsLive do
  @moduledoc """
  Orders that open on their lines: Alt+→ (or the arrow) opens an order's
  detail, a grid of its own; Alt+↓ goes into it, Escape comes back.
  """
  use Phoenix.LiveView

  import Masu.Components

  @impl true
  def mount(_params, _session, socket) do
    orders =
      for id <- 1..2_000 do
        customer = Enum.at(MasuDev.Customers.all(), id)

        %{
          id: id,
          number: "SO-#{10_000 + id}",
          customer: customer.name,
          city: customer.city,
          placed_on: Date.add(~D[2026-01-01], rem(id * 13, 280))
        }
      end

    {:ok, assign(socket, orders: orders)}
  end

  def lines(order) do
    for n <- 1..(3 + rem(order.id, 6)) do
      %{
        id: order.id * 100 + n,
        product: Enum.at(~w(Bolt Nut Washer Gear Spring Valve Seal Pump), rem(order.id * n, 8)),
        quantity: rem(order.id * n * 7, 40) + 1,
        price: Decimal.new(rem(order.id * n * 13, 9000) + 100) |> Decimal.div(100)
      }
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1 id="details-label">Details</h1>
    <.data_grid id="orders" rows={@orders} label_id="details-label" searchable height="34rem">
      <:col field={:number} width={140} />
      <:col field={:customer} width={220} />
      <:col field={:city} />
      <:col field={:placed_on} type={:date} label="Placed on" />
      <:detail :let={order}>
        <p style="margin: 0 0 0.5rem">{order.customer} ordered {length(lines(order))} lines.</p>
        <.data_grid id={"lines-#{order.id}"} rows={lines(order)} height="12rem">
          <:col field={:product} />
          <:col field={:quantity} type={:integer} />
          <:col field={:price} type={:decimal} />
        </.data_grid>
      </:detail>
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

defmodule MasuDev.QuotesLive do
  @moduledoc """
  Live rows: two thousand quotes, and a ticker that changes twenty prices
  every 700 ms (one of them among the first ten, so that a change is
  always on the first screen) and broadcasts them on a PubSub topic
  (Masu.Live).
  """
  use Phoenix.LiveView

  import Masu.Components

  on_mount(Masu.Live)

  @symbols for a <- ?A..?Z, b <- ?A..?Z, c <- ?A..?C, do: <<a, b, c>>

  @impl true
  def mount(params, _session, socket) do
    quotes = @symbols |> Enum.take(2000) |> Enum.with_index(1) |> Enum.map(&new_quote/1)
    if connected?(socket), do: :timer.send_interval(700, :tick)

    {:ok,
     assign(socket,
       quotes: quotes,
       prices: Map.new(quotes, &{&1.id, &1}),
       ticks: 0,
       locale: params["locale"] || "en-GB"
     )}
  end

  defp new_quote({symbol, id}) do
    price = Decimal.new(rem(id * 7919, 90_000) + 1000) |> Decimal.div(100) |> Decimal.round(2)

    %{
      id: id,
      symbol: symbol,
      price: price,
      change: Decimal.new("0.00"),
      volume: rem(id * 104_729, 1_000_000),
      updated_at: DateTime.utc_now(:second)
    }
  end

  @impl true
  def handle_info(:tick, socket) do
    %{prices: prices, ticks: ticks} = socket.assigns
    ids = [rem(ticks, 10) + 1 | Enum.map(1..19, fn _ -> :rand.uniform(map_size(prices)) end)]

    prices =
      Enum.reduce(ids, prices, fn id, prices ->
        row = Map.fetch!(prices, id)
        change = Decimal.new(:rand.uniform(201) - 101) |> Decimal.div(100) |> Decimal.round(2)

        row = %{
          row
          | price: row.price |> Decimal.add(change) |> Decimal.round(2),
            change: change,
            volume: row.volume + :rand.uniform(500),
            updated_at: DateTime.utc_now(:second)
        }

        Masu.Live.broadcast_upsert(MasuDev.PubSub, "quotes", row)
        Map.put(prices, id, row)
      end)

    {:noreply, assign(socket, prices: prices, ticks: ticks + 1)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1 id="quotes-label">Quotes</h1>
    <.data_grid
      id="quotes"
      rows={@quotes}
      live={{MasuDev.PubSub, "quotes"}}
      label_id="quotes-label"
      searchable
      height="36rem"
      locale={@locale}
    >
      <:col field={:symbol} width={110} />
      <:col field={:price} type={:decimal} />
      <:col field={:change} type={:decimal} />
      <:col field={:volume} type={:integer} />
      <:col field={:updated_at} type={:datetime} label="Updated" />
    </.data_grid>
    """
  end
end

defmodule MasuDev.Presence do
  @moduledoc "Who has a grid open (Masu.Presence)."
  use Phoenix.Presence, otp_app: :masu, pubsub_server: MasuDev.PubSub
end

defmodule MasuDev.TogetherLive do
  @moduledoc """
  Twenty customers that everyone who opens the page shares: the grids
  follow one topic, so an edit in one browser shows in the others, and two
  edits of one cell are a conflict. Each browser is a person (`?as=Ada`,
  or a name of its own), whom the others see (Masu.Presence). `?room=`
  gives a page of its own, as the browser tests do, and `?presence=0` a
  page where no one sees the others; `?rows=300` takes more customers, and
  `?share=0` keeps this person's view from those who follow them.
  """
  use Phoenix.LiveView

  import Masu.Components

  on_mount(Masu.Live)

  @impl true
  def mount(params, _session, socket) do
    name = params["as"] || Enum.random(~w(Ada Alan Grace Edsger Barbara Donald Margaret Ken))
    user = %{id: "#{name}-#{System.unique_integer([:positive])}", name: name}

    {:ok,
     assign(socket,
       rows: Enum.take(MasuDev.Customers.all(), rows(params)),
       user: user,
       topic: "together:" <> (params["room"] || "main"),
       presence: if(params["presence"] != "0", do: MasuDev.Presence),
       share_view: params["share"] != "0",
       locale: params["locale"] || "en-GB"
     )}
  end

  defp rows(%{"rows" => rows}) do
    case Integer.parse(rows) do
      {rows, ""} when rows in 1..10_000 -> rows
      _other -> 20
    end
  end

  defp rows(_params), do: 20

  @impl true
  def render(assigns) do
    ~H"""
    <h1 id="together-label">Together</h1>
    <p>You are {@user.name}. Open this page in another browser to edit with someone.</p>
    <.data_grid
      id="together"
      rows={@rows}
      changeset={&MasuDev.Customers.changeset/2}
      live={{MasuDev.PubSub, @topic}}
      presence={@presence}
      user={@user}
      share_view={@share_view}
      label_id="together-label"
      searchable
      height="30rem"
      locale={@locale}
    >
      <:col field={:id} type={:integer} width={80} label="ID" editable={false} />
      <:col field={:name} width={190} />
      <:col field={:city} />
      <:col field={:plan} type={:enum} width={130} />
      <:col field={:seats} type={:integer} />
      <:col field={:revenue} type={:decimal} />
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
    live("/live", MasuDev.QuotesLive)
    live("/together", MasuDev.TogetherLive)
    live("/views", MasuDev.ViewsLive)
    live("/tree", MasuDev.TreeLive)
    live("/details", MasuDev.DetailsLive)
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
      [
        {Phoenix.PubSub, name: MasuDev.PubSub},
        MasuDev.Presence,
        Masu.Views.Memory,
        MasuDev.Endpoint
      ],
      strategy: :one_for_one
    )

  IO.puts("Masu development server: http://localhost:#{port}")
  Process.sleep(:infinity)
end)

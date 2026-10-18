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

  def cities, do: @cities

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
          {"Groups", "/groups"},
          {"Tasks", "/tasks"},
          {"Pages", "/pages"},
          {"Look", "/look"},
          {"Menus", "/menus"},
          {"Actions", "/actions"},
          {"Editors", "/editors"},
          {"Some filters", "/limited"},
          {"Results", "/results"},
          {"Slow", "/slow"},
          {"Controlled", "/controlled"},
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
          import { Masu, configure } from "masu"
          // Editors of the browser's own, for the Editors page: a slider,
          // and the browser's color input.
          configure({
            editors: {
              score: ({ element, value, options, label, commit }) => {
                const input = Object.assign(document.createElement("input"), {
                  type: "range", min: options.min ?? 0, max: options.max ?? 100, step: options.step ?? 1,
                  value: value ?? 0, className: "dev-score",
                })
                input.setAttribute("aria-label", label)
                const shown = document.createElement("output")
                shown.textContent = input.value
                input.addEventListener("input", () => (shown.textContent = input.value))
                // The arrows are the slider's; Enter and Tab are the grid's.
                input.addEventListener("keydown", (event) => {
                  if (event.key.startsWith("Arrow") || event.key === "Home" || event.key === "End") event.stopPropagation()
                })
                element.append(input, shown)
                return { value: () => Number(input.value), focus: () => input.focus() }
              },
              color: ({ element, value, label, commit }) => {
                const input = Object.assign(document.createElement("input"), { type: "color", value: value ?? "#000000" })
                input.setAttribute("aria-label", label)
                input.addEventListener("change", () => commit(input.value))
                element.append(input)
                return { value: () => input.value, focus: () => input.focus() }
              },
            },
          })
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
      selectable
      export
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

defmodule MasuDev.GroupsLive do
  @moduledoc """
  A hundred thousand customers grouped by plan, then city: each group
  with its count and totals, the totals of the query at the bottom. The
  header menu groups by another column.
  """
  use Phoenix.LiveView

  import Masu.Components

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, customers: MasuDev.Customers.all())}

  @impl true
  def render(assigns) do
    ~H"""
    <h1 id="groups-label">Groups</h1>
    <.data_grid
      id="groups"
      rows={@customers}
      group_by={[:plan, :city]}
      label_id="groups-label"
      searchable
      height="34rem"
    >
      <:col field={:name} width={240} />
      <:col field={:plan} type={:enum} width={130} />
      <:col field={:city} />
      <:col field={:seats} type={:integer} aggregate={:sum} />
      <:col field={:revenue} type={:decimal} aggregate={:sum} />
      <:col key="average" field={:revenue} type={:decimal} label="Average" aggregate={:avg} />
      <:col field={:active} type={:boolean} />
      <:col field={:signed_up} type={:date} label="Last sign-up" aggregate={:max} />
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

defmodule MasuDev.TasksLive do
  @moduledoc """
  Tasks that a person adds and deletes: "+ New row" (or Ctrl+Enter),
  Ctrl+Delete with a question, and Ctrl+Z to bring rows back. The status
  is an enum with its values, the estimate shows one decimal.
  """
  use Phoenix.LiveView

  import Ecto.Changeset
  import Masu.Components

  @statuses ~w(todo doing review done)
  @types %{title: :string, status: :string, estimate: :decimal, due: :date, urgent: :boolean}

  @impl true
  def mount(_params, _session, socket) do
    tasks =
      for id <- 1..30 do
        %{
          id: id,
          title: "Task #{id}",
          status: Enum.at(@statuses, rem(id, 4)),
          estimate: Decimal.new(rem(id * 7, 13)) |> Decimal.div(2),
          due: Date.add(~D[2026-11-01], id),
          urgent: rem(id, 6) == 0
        }
      end

    {:ok, assign(socket, tasks: tasks, statuses: @statuses)}
  end

  def changeset(task, params) do
    {task, @types}
    |> cast(params, Map.keys(@types))
    |> validate_required([:title])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:estimate, greater_than_or_equal_to: 0)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1 id="tasks-label">Tasks</h1>
    <.data_grid
      id="tasks"
      rows={@tasks}
      changeset={&changeset/2}
      struct={fn -> %{id: System.unique_integer([:positive]) + 1000, title: nil, status: "todo", estimate: nil, due: nil, urgent: false} end}
      deletable={&(&1.status != "done")}
      selectable
      label_id="tasks-label"
      height="28rem"
    >
      <:col field={:title} width={240} />
      <:col field={:status} type={:enum} values={@statuses} />
      <:col field={:estimate} type={:decimal} decimals={1} />
      <:col field={:due} type={:date} />
      <:col field={:urgent} type={:boolean} />
    </.data_grid>
    """
  end
end

defmodule MasuDev.Engine do
  @moduledoc """
  A source as a search engine is: it pages by offset and limit, and does
  not count (`:unknown`), as Lotus asks with `count: :none`. Its rows are
  the customers, slowly: 150 ms a block.
  """
  @behaviour Masu.Source

  @impl true
  def init(_opts, _grid_opts), do: %{rows: MasuDev.Customers.all()}

  @impl true
  def prepare(state, _query, _columns), do: state

  @impl true
  def count(_state), do: :unknown

  @impl true
  def rows(%{rows: rows}, offset, limit) do
    Process.sleep(150)
    Enum.slice(rows, offset, limit)
  end

  @impl true
  def supports?(_state, _column), do: false
end

defmodule MasuDev.PagesLive do
  @moduledoc """
  Large tables without a count, and with pages: a search engine's rows,
  which the grid scrolls over as they come, and a report that pages, with
  its page in the URL.
  """
  use Phoenix.LiveView

  import Masu.Components

  on_mount(Masu.Live)

  @impl true
  def mount(_params, _session, socket) do
    notes = for id <- 1..12, do: %{id: id, text: "Note #{id}"}
    {:ok, assign(socket, customers: MasuDev.Customers.all(), notes: notes)}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <h1 id="engine-label">A search engine's rows, not counted</h1>
    <.data_grid id="engine" source={{MasuDev.Engine, []}} label_id="engine-label" height="18rem">
      <:col field={:id} type={:integer} width={90} label="ID" />
      <:col field={:name} width={190} />
      <:col field={:city} />
      <:col field={:revenue} type={:decimal} />
    </.data_grid>
    <h1 id="report-label">A report, by pages</h1>
    <.data_grid
      id="report"
      rows={@customers}
      paging={:pages}
      page_size={25}
      url
      label_id="report-label"
      height="18rem"
    >
      <:col field={:id} type={:integer} width={90} label="ID" />
      <:col field={:name} width={190} />
      <:col field={:plan} type={:enum} />
      <:col field={:revenue} type={:decimal} />
    </.data_grid>
    <h1 id="notes-label">Notes, by pages, that a person adds to</h1>
    <.data_grid
      id="notes"
      rows={@notes}
      paging={:pages}
      page_size={5}
      changeset={&note/2}
      struct={fn -> %{id: System.unique_integer([:positive]) + 100, text: nil} end}
      deletable
      label_id="notes-label"
      height="14rem"
    >
      <:col field={:text} width={320} />
    </.data_grid>
    """
  end

  def note(note, params) do
    import Ecto.Changeset

    {note, %{text: :string}}
    |> cast(params, [:text])
    |> validate_required([:text])
  end
end

defmodule MasuDev.LookLive do
  @moduledoc """
  Masu in another app's look: Lotus Web's results table, made of tokens
  (and `row_height`), with no CSS of its own. The e2e spec compares it
  with Lotus Web's own table, pixel for pixel.
  """
  use Phoenix.LiveView

  import Masu.Components

  @rows [
    %{id: "1", name: "Ada Lovelace", plan: "team", revenue: "1,204.50"},
    %{id: "2", name: "Alan Turing", plan: "free", revenue: "0.00"},
    %{id: "3", name: "Grace Hopper", plan: "enterprise", revenue: "98,100.00"},
    %{id: "4", name: "Edsger Dijkstra", plan: "starter", revenue: "12.00"},
    %{id: "5", name: "Barbara Liskov", plan: "business", revenue: "7,400.25"},
    %{id: "6", name: "Donald Knuth", plan: "team", revenue: "310.75"}
  ]

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, rows: @rows)}

  @impl true
  def render(assigns) do
    ~H"""
    <style>
      /* Lotus Web's results table, as Masu tokens. In Lotus Web itself, the
         values would be its own variables: rgb(var(--lotus-gray-50)). */
      .lotus-look {
        --masu-font: "Inter var", sans-serif;
        --masu-font-size: 0.875rem;
        --masu-line-height: 1.25rem;
        --masu-text: rgb(39 39 42);
        --masu-background: rgb(255 255 255);
        --masu-header-background: rgb(255 255 255);
        --masu-header-text: rgb(39 39 42);
        --masu-header-height: 48px;
        --masu-header-border: none;
        --masu-header-shadow: 0 1px 0 0 rgb(209 213 219);
        --masu-header-hover: rgb(239 246 255);
        --masu-grid-border: none;
        --masu-grid-radius: 0;
        --masu-row-border: none;
        --masu-row-alt-background: rgb(249 250 251);
        --masu-row-hover: transparent;
        --masu-cell-hover: rgb(239 246 255);
        --masu-cell-padding: 0 0.75rem;
      }

      .dark .lotus-look {
        --masu-text: rgb(244 244 245);
        --masu-background: rgb(23 23 23);
        --masu-header-background: rgb(23 23 23);
        --masu-header-text: rgb(244 244 245);
        --masu-header-shadow: 0 1px 0 0 rgb(75 85 99);
        --masu-header-hover: rgb(30 58 138 / 0.2);
        --masu-row-alt-background: rgb(55 65 81);
        --masu-cell-hover: rgb(30 58 138 / 0.2);
      }
    </style>
    <h1 id="look-label">Lotus Web's table, in Masu</h1>
    <div style="width: 660px">
      <.data_grid id="look" rows={@rows} class="lotus-look" row_height={52} height="360px" label_id="look-label">
        <:col field={:id} label="id" width={100} />
        <:col field={:name} label="name" width={240} />
        <:col field={:plan} label="plan" width={160} />
        <:col field={:revenue} label="revenue" width={160} />
      </.data_grid>
    </div>
    """
  end
end

defmodule MasuDev.MenusLive do
  @moduledoc """
  Menus of the app's own (Masu.Action): items in the header menu, a
  menu on each cell (a right click, or the context-menu key or Shift+F10
  on the active cell) with the grid's own items, and panels the server
  renders.
  """
  use Phoenix.LiveView

  import Masu.Components

  alias Phoenix.LiveView.JS

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, rows: Enum.take(MasuDev.Customers.all(), 200), said: nil)}
  end

  @impl true
  def handle_info({Masu.Action, "open", context}, socket),
    do: {:noreply, assign(socket, said: "Opened #{context.row.name}")}

  def handle_info({:said, text}, socket), do: {:noreply, assign(socket, said: text)}

  @impl true
  def render(assigns) do
    pid = self()
    assigns = assign(assigns, explain: &send(pid, {:said, "About #{&1.column}"}))

    ~H"""
    <h1 id="menus-label">Menus</h1>
    <p id="said" role="status">{@said}</p>
    <p id="js-mark" data-marked="no">A JS command marks this.</p>
    <.data_grid id="menus" rows={@rows} label_id="menus-label" height="24rem" cell_menu>
      <:col field={:name} />
      <:col field={:city} />
      <:col field={:plan} type={:enum} values={~w(free starter team business enterprise)} />
      <:col field={:revenue} type={:decimal} />
      <:col field={:active} type={:boolean} />

      <:header_action label="Explain" on_action={@explain} />
      <:header_action :let={action} label="Column stats" types={[:decimal]}>
        <.stats rows={@rows} key={action.column} />
      </:header_action>

      <:cell_action label="Open" event="open" />
      <:cell_action label="Mark" js={JS.set_attribute({"data-marked", "yes"}, to: "#js-mark")} />
      <:cell_action :let={action} label="Card" columns={[:name]}>
        <div id="card">
          <strong>{action.row.name}</strong>
          <p>{action.row.email} · {action.row.city || "no city"} · {action.row.plan}</p>
        </div>
      </:cell_action>
    </.data_grid>
    """
  end

  attr :rows, :list, required: true
  attr :key, :string, required: true

  defp stats(assigns) do
    values =
      assigns.rows
      |> Enum.map(&Map.fetch!(&1, String.to_existing_atom(assigns.key)))
      |> Enum.reject(&is_nil/1)

    sum = Enum.reduce(values, Decimal.new(0), &Decimal.add/2)

    assigns =
      assign(assigns,
        min: Enum.min(values, Decimal),
        max: Enum.max(values, Decimal),
        avg: values |> length() |> then(&Decimal.div(sum, &1)) |> Decimal.round(2)
      )

    ~H"""
    <dl id="stats">
      <dt>Lowest</dt>
      <dd>{Decimal.to_string(@min)}</dd>
      <dt>Highest</dt>
      <dd>{Decimal.to_string(@max)}</dd>
      <dt>Average</dt>
      <dd>{Decimal.to_string(@avg)}</dd>
    </dl>
    """
  end
end

defmodule MasuDev.LimitedSource do
  @moduledoc """
  A source that filters as Lotus Web does: `= ≠ > < ≥ ≤`, LIKE
  (`contains`, `starts_with`, `ends_with`), null and not null. It runs a
  list; Masu runs "between" as `≥` and `≤` for it.
  """
  @behaviour Masu.Source

  alias Masu.Source.List, as: ListSource

  @impl true
  def init(opts, grid_opts), do: ListSource.init(Keyword.fetch!(opts, :rows), grid_opts)

  @impl true
  def filters(_state, _column),
    do: [:eq, :neq, :gt, :lt, :gte, :lte, :contains, :starts_with, :ends_with, :is_nil, :not_nil]

  @impl true
  defdelegate prepare(state, query, columns), to: ListSource
  @impl true
  defdelegate count(state), to: ListSource
  @impl true
  defdelegate rows(state, offset, limit), to: ListSource
end

defmodule MasuDev.LimitedLive do
  @moduledoc "A source that runs some filters only (MasuDev.LimitedSource): the menus offer those."
  use Phoenix.LiveView

  import Masu.Components

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, rows: Enum.take(MasuDev.Customers.all(), 500))}

  @impl true
  def render(assigns) do
    ~H"""
    <h1 id="limited-label">Some filters</h1>
    <.data_grid id="limited" source={{MasuDev.LimitedSource, rows: @rows}} label_id="limited-label" height="24rem" cell_menu>
      <:col field={:name} />
      <:col field={:city} type={:enum} values={MasuDev.Customers.cities()} />
      <:col field={:seats} type={:integer} />
      <:col field={:signed_up} type={:date} />
    </.data_grid>
    """
  end
end

defmodule MasuDev.ResultsLive do
  @moduledoc """
  A query tool's results, as Lotus Web gets them: column names, and rows
  as lists of values, of no types. The grid has no `:col` slots: its
  `columns` are the names, and each column's type is learned from its
  values. Another query brings other columns.
  """
  use Phoenix.LiveView

  import Masu.Components

  @impl true
  def mount(_params, _session, socket), do: {:ok, run(socket, "customers")}

  @impl true
  def handle_event("run", %{"query" => query}, socket), do: {:noreply, run(socket, query)}

  defp run(socket, "customers") do
    rows =
      for c <- Enum.take(MasuDev.Customers.all(), 300),
          do: [
            c.id,
            c.name,
            c.city,
            c.plan,
            c.seats,
            c.revenue,
            c.active,
            c.signed_up,
            c.last_seen
          ]

    assign(socket,
      query: "customers",
      columns: ~w(id name city plan seats revenue active signed_up last_seen),
      rows: rows
    )
  end

  defp run(socket, "plans") do
    rows =
      MasuDev.Customers.all()
      |> Enum.group_by(& &1.plan)
      |> Enum.map(fn {plan, cs} ->
        [
          plan,
          length(cs),
          cs |> Enum.map(& &1.revenue) |> Enum.reduce(&Decimal.add/2),
          Enum.sum_by(cs, & &1.seats) / length(cs)
        ]
      end)

    assign(socket, query: "plans", columns: ~w(plan customers revenue seats), rows: rows)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1 id="results-label">Results</h1>
    <form id="run" phx-change="run">
      <select name="query" aria-label="Query">
        <option value="customers" selected={@query == "customers"}>SELECT * FROM customers</option>
        <option value="plans" selected={@query == "plans"}>SELECT plan, count(*), sum(revenue), avg(seats) …</option>
      </select>
    </form>
    <.data_grid id="results" rows={@rows} columns={@columns} row_id={:position} label_id="results-label" height="24rem" />
    """
  end
end

defmodule MasuDev.SlowSource do
  @moduledoc "A slow source: customers that take `delay` milliseconds to sort, filter and read, as a warehouse would."
  @behaviour Masu.Source

  alias Masu.Source.List, as: ListSource

  @impl true
  def init(opts, grid_opts),
    do: %{
      list: ListSource.init(MasuDev.Customers.all(), grid_opts),
      delay: Keyword.fetch!(opts, :delay)
    }

  @impl true
  def prepare(state, query, columns) do
    Process.sleep(state.delay)
    %{state | list: ListSource.prepare(state.list, query, columns)}
  end

  @impl true
  def count(state), do: ListSource.count(state.list)

  @impl true
  def rows(state, offset, limit) do
    Process.sleep(div(state.delay, 2))
    ListSource.rows(state.list, offset, limit)
  end
end

defmodule MasuDev.SlowLive do
  @moduledoc "A slow source read in a task (`load={:async}`): the page answers while it runs, with Stop, and a timeout."
  use Phoenix.LiveView

  import Masu.Components

  @impl true
  def mount(params, _session, socket),
    do: {:ok, assign(socket, delay: String.to_integer(params["delay"] || "800"))}

  @impl true
  def render(assigns) do
    ~H"""
    <h1 id="slow-label">Slow source</h1>
    <.data_grid
      id="slow"
      source={{MasuDev.SlowSource, delay: @delay}}
      load={:async}
      timeout={5000}
      label_id="slow-label"
      height="24rem"
    >
      <:col field={:name} />
      <:col field={:city} />
      <:col field={:seats} type={:integer} />
      <:col field={:revenue} type={:decimal} />
    </.data_grid>
    """
  end
end

defmodule MasuDev.ControlledLive do
  @moduledoc """
  A controlled grid (`on_query`), as Lotus Web would have it: the
  LiveView runs its query in `start_async`, a page of a thousand rows at
  a time, with the count, and one sort; the grid shows its rows.
  """
  use Phoenix.LiveView

  import Masu.Components

  @page 1000

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(rows: [], total: 0, running: false, runs: 0) |> run(%Masu.Query{}, 0)}
  end

  @impl true
  def handle_info({:query, %{query: query, offset: offset}}, socket),
    do: {:noreply, run(socket, query, offset)}

  defp run(socket, query, offset) do
    socket = assign(socket, running: true, runs: socket.assigns.runs + 1)

    start_async(socket, :run, fn ->
      Process.sleep(400)
      keys = Map.new(~w(name city plan seats revenue), &{&1, String.to_existing_atom(&1)})

      rows =
        MasuDev.Customers.all()
        |> Enum.filter(fn row ->
          Enum.all?(query.filters, &Masu.Filter.match?(&1, Map.get(row, keys[&1.key])))
        end)

      rows =
        case query.sorts do
          [%Masu.Sort{key: key, direction: dir}] ->
            Enum.sort_by(rows, &Map.get(&1, keys[key]), sorter(dir))

          [] ->
            rows
        end

      {Enum.slice(rows, offset, @page), length(rows)}
    end)
  end

  defp sorter(:asc), do: &(Masu.Value.compare(&1, &2) != :gt)
  defp sorter(:desc), do: &(Masu.Value.compare(&1, &2) != :lt)

  @impl true
  def handle_async(:run, {:ok, {rows, total}}, socket),
    do: {:noreply, assign(socket, rows: rows, total: total, running: false)}

  @impl true
  def render(assigns) do
    pid = self()
    assigns = assign(assigns, on_query: &send(pid, {:query, &1}))

    ~H"""
    <h1 id="controlled-label">Controlled</h1>
    <p>The LiveView ran its query <span id="runs">{@runs}</span> times.</p>
    <.data_grid
      id="controlled"
      rows={@rows}
      total={@total}
      loading={@running}
      on_query={@on_query}
      paging={:pages}
      page_size={1000}
      max_block={1000}
      multi_sort={false}
      label_id="controlled-label"
      height="24rem"
    >
      <:col field={:name} />
      <:col field={:city} />
      <:col field={:plan} />
      <:col field={:seats} type={:integer} />
      <:col field={:revenue} type={:decimal} />
    </.data_grid>
    """
  end
end

defmodule MasuDev.ActionsLive do
  @moduledoc """
  Actions of the app's own (Masu.Action): on the rows selected (the bar
  above the grid) and on each row (the menu at its end, and in the menu
  of its cells), one that is a link, one that asks first, and one that
  goes on in a task and says how far it is.
  """
  use Phoenix.LiveView

  import Masu.Components

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, rows: Enum.take(MasuDev.Customers.all(), 200), said: nil)}
  end

  @impl true
  def handle_params(%{"open" => id}, _uri, socket) do
    row = Enum.find(socket.assigns.rows, &(to_string(&1.id) == id))
    {:noreply, assign(socket, said: "Opened #{row && row.name}")}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:deactivate, ids}, socket) do
    ids = MapSet.new(ids)
    rows = Enum.map(socket.assigns.rows, &if(&1.id in ids, do: %{&1 | active: false}, else: &1))
    {:noreply, assign(socket, rows: rows)}
  end

  def handle_info({:remove, ids}, socket) do
    ids = MapSet.new(ids)
    {:noreply, update(socket, :rows, fn rows -> Enum.reject(rows, &(&1.id in ids)) end)}
  end

  @impl true
  def render(assigns) do
    pid = self()

    assigns =
      assign(assigns,
        deactivate: fn %{selected: {:ids, ids}} ->
          send(pid, {:deactivate, ids})
          {:ok, "#{length(ids)} deactivated"}
        end,
        deactivate_row: fn %{row: row} ->
          send(pid, {:deactivate, [row.id]})
          {:ok, "#{row.name} deactivated"}
        end,
        remove: fn %{selected: {:ids, ids}} ->
          send(pid, {:remove, ids})
          {:ok, "#{length(ids)} removed"}
        end,
        export_later: &export_later/1
      )

    ~H"""
    <h1 id="actions-label">Actions</h1>
    <p id="said" role="status">{@said}</p>
    <.data_grid id="actions" rows={@rows} label_id="actions-label" height="24rem" selectable>
      <:col field={:name} />
      <:col field={:city} />
      <:col field={:plan} type={:enum} values={~w(free starter team business enterprise)} />
      <:col field={:active} type={:boolean} />

      <:action label="Deactivate" on_action={@deactivate} />
      <:action label="Export later" on_action={@export_later} />
      <:action label="Remove" on_action={@remove} confirm="Remove {count} customers?" danger />

      <:row_action label="Open" patch={&"/actions?open=#{&1.id}"} />
      <:row_action label="Deactivate" on_action={@deactivate_row} disabled={&(!&1.active)} />
      <:row_action label="Remove" on_action={&send(pid, {:remove, [&1.row.id]})} confirm="Remove this customer?" danger />
    </.data_grid>
    """
  end

  # A task: how far it is, then how it went.
  defp export_later(%{ref: ref, count: count}) do
    Task.start(fn ->
      for done <- 1..count do
        Process.sleep(150)
        Masu.progress(ref, done, count)
      end

      Masu.reply(ref, {:ok, "#{count} exported"})
    end)

    :async
  end
end

defmodule MasuDev.EditorsLive do
  @moduledoc """
  Editors of the app's own: forms of HEEx that the server renders in a
  popover under the cell (notes in a text area, a window of two days), and
  editors of the browser's, by name, given to `configure` in the page's
  script (a slider with options, a color).
  """
  use Phoenix.LiveView

  import Ecto.Changeset
  import Masu.Components

  @types %{title: :string, score: :integer, color: :string, notes: :string, window: :map}

  @impl true
  def mount(_params, _session, socket) do
    rows =
      for id <- 1..40 do
        %{
          id: id,
          title: "Task #{id}",
          score: rem(id * 37, 101),
          color: Enum.at(~w(#e5484d #30a46c #0090ff #f76b15), rem(id, 4)),
          notes: if(rem(id, 3) == 0, do: "Call back\nafter lunch"),
          window: %{"from" => "2027-03-#{10 + rem(id, 9)}", "to" => "2027-03-#{20 + rem(id, 8)}"}
        }
      end

    {:ok, assign(socket, rows: rows)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1 id="editors-label">Editors</h1>
    <.data_grid id="editors" rows={@rows} changeset={&changeset/2} label_id="editors-label" height="24rem" sort={[:id]}>
      <:col field={:title} />
      <:col field={:score} type={:integer} editor={{"score", %{max: 100, step: 5}}} />
      <:col field={:color} editor="color" />
      <:col field={:notes} editor={&notes_editor/1} />
      <:col :let={task} field={:window} editor={&window_editor/1} width={240} sortable={false} filterable={false}>
        {task.window["from"]} → {task.window["to"]}
      </:col>
    </.data_grid>
    """
  end

  defp notes_editor(assigns) do
    ~H"""
    <textarea name={@field.name} rows="4" cols="32" aria-labelledby={@label_id}>{@field.value}</textarea>
    <p class="dev-hint">⌘/Ctrl+Enter saves, Escape lets it go.</p>
    """
  end

  defp window_editor(assigns) do
    ~H"""
    <label>From <input type="date" name={@field.name <> "[from]"} value={@value["from"]} /></label>
    <label>To <input type="date" name={@field.name <> "[to]"} value={@value["to"]} /></label>
    <button type="submit">Save</button>
    """
  end

  def changeset(task, params) do
    {task, @types}
    |> cast(params, Map.keys(@types))
    |> validate_required([:title])
    |> validate_number(:score, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_change(:window, fn :window, window ->
      if window["from"] <= window["to"], do: [], else: [window: "ends before it starts"]
    end)
  end
end

defmodule MasuDev.Router do
  use Phoenix.Router

  import Phoenix.LiveView.Router
  import Masu.Router

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
    live("/groups", MasuDev.GroupsLive)
    live("/tasks", MasuDev.TasksLive)
    live("/pages", MasuDev.PagesLive)
    live("/look", MasuDev.LookLive)
    live("/menus", MasuDev.MenusLive)
    live("/limited", MasuDev.LimitedLive)
    live("/results", MasuDev.ResultsLive)
    live("/slow", MasuDev.SlowLive)
    live("/controlled", MasuDev.ControlledLive)
    live("/actions", MasuDev.ActionsLive)
    live("/editors", MasuDev.EditorsLive)
    masu_exports()
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

import Config

if config_env() == :dev do
  # The grid bundles. NODE_PATH is unset: the bundles never pick up a
  # package from deps/.
  esbuild_args = ~w(
    src/index.ts
    --bundle
    --minify
    --target=es2020
    --external:phoenix
    --external:phoenix_live_view
  )

  config :esbuild,
    version: "0.28.2",
    masu_esm: [
      args: esbuild_args ++ ~w(--format=esm --outfile=../priv/static/masu.esm.js),
      cd: Path.expand("../assets", __DIR__),
      env: %{"NODE_PATH" => nil}
    ],
    masu_cjs: [
      args: esbuild_args ++ ~w(--format=cjs --outfile=../priv/static/masu.cjs.js),
      cd: Path.expand("../assets", __DIR__),
      env: %{"NODE_PATH" => nil}
    ]
end

if config_env() == :test do
  config :logger, level: :warning
  config :phoenix, :json_library, JSON

  config :masu, MasuTest.Endpoint,
    secret_key_base: String.duplicate("masu-test-secret-key-base-", 4),
    live_view: [signing_salt: "masu-test-salt"],
    pubsub_server: MasuTest.PubSub,
    render_errors: [formats: [html: MasuTest.ErrorHTML], layout: false],
    server: false

  # The browser tests (test/e2e, `mix test.e2e`) run against the
  # development server (dev.exs), which test_helper.exs starts on its own
  # port (4098, or E2E_PORT).
  config :playwright, :test,
    base_url: "http://127.0.0.1:#{System.get_env("E2E_PORT", "4098")}",
    # The grids format numbers and dates in the page's locale (en-GB on
    # the dev pages), and datetimes in the browser's time zone.
    locale: "en-GB",
    timezone_id: "Europe/Lisbon",
    # A failed test keeps its trace and a screenshot, in test-results/.
    trace: :retain_on_failure,
    screenshot: :only_on_failure
end

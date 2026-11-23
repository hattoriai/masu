if :e2e in Keyword.get(ExUnit.configuration(), :include, []) do
  # The browser tests (test/e2e, `mix test.e2e`) run against the
  # development server. The bundle is built first, and the server
  # (dev.exs) starts in this VM without watchers or live reload, on its
  # own port (4098, or E2E_PORT), so that a `mix dev` with watchers on
  # 4099 is never the server of a run.
  port = System.get_env("E2E_PORT", "4098")

  {output, status} =
    System.cmd("mix", ["masu.build"], env: [{"MIX_ENV", "dev"}], stderr_to_stdout: true)

  if status != 0, do: raise("mix masu.build failed:\n" <> output)

  System.put_env(%{"PORT" => port, "MASU_DEV_WATCH" => "false"})
  Code.require_file("dev.exs")
  # Keep the dev server's request logs (dev.exs sets :info) out of the output.
  Logger.configure(level: :warning)

  {:ok, _apps} = Application.ensure_all_started(:inets)
  url = ~c"http://127.0.0.1:#{port}/small"
  deadline = System.monotonic_time(:millisecond) + 180_000

  Stream.repeatedly(fn -> :httpc.request(:get, {url, []}, [], []) end)
  |> Enum.find(fn
    {:ok, {{_, 200, _}, _, _}} ->
      true

    _ ->
      if System.monotonic_time(:millisecond) > deadline, do: raise("no dev server at #{url}")
      Process.sleep(100)
      false
  end)

  # Playwright Test's test timeout (30 s), not ExUnit's 60 s.
  ExUnit.configure(timeout: 30_000)
else
  # The Issho of the collaboration tests: a grid's people are those of its room.
  {:ok, _pid} =
    Supervisor.start_link(
      [
        # Before Issho, so that it stops after it.
        {Phoenix.PubSub, name: MasuTest.PubSub},
        Masu.Views.Memory,
        Masu.History.Memory,
        {Issho.Store.Memory, name: MasuTest.IsshoStore},
        {Issho,
         name: MasuTest.Issho,
         pubsub: MasuTest.PubSub,
         secret_key_base: Base.encode64(:crypto.strong_rand_bytes(48)),
         store: {Issho.Store.Memory, MasuTest.IsshoStore},
         policy: MasuTest.Collaboration,
         awareness_interval: 5}
      ],
      strategy: :one_for_one
    )

  {:ok, _pid} = MasuTest.Endpoint.start_link()

  # The repo of the Ecto source tests (MasuTest.DB), with six orders, for the whole run.
  :ok = MasuTest.Orders.setup!()
end

# The :build tests run `mix masu.build` (npm and network on the first
# run) and `mix hex.build`: `mix test --include build`.
ExUnit.start(exclude: [:build, :e2e])

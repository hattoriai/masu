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
# The :build tests run `mix masu.build` (npm and network on the first
# run) and `mix hex.build`: `mix test --include build`.
ExUnit.start(exclude: [:build])

{:ok, _pid} = Phoenix.PubSub.Supervisor.start_link(name: MasuTest.PubSub)
{:ok, _pid} = MasuTest.Endpoint.start_link()

{:ok, _pid} =
  Supervisor.start_link([MasuTest.Presence, Masu.Views.Memory, Masu.History.Memory],
    strategy: :one_for_one
  )

# The repo of the Ecto source tests (MasuTest.DB), with six orders, for the whole run.
:ok = MasuTest.Orders.setup!()
# The :build tests run `mix masu.build` (npm and network on the first
# run) and `mix hex.build`: `mix test --include build`.
ExUnit.start(exclude: [:build])

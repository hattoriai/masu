defmodule MasuTest.ErrorHTML do
  @moduledoc "Error pages for the test endpoint."

  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end

defmodule MasuTest.Router do
  @moduledoc "The router of the test endpoint."
  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_query_params)
  end

  scope "/" do
    pipe_through(:browser)
    live("/people", MasuTest.PeopleLive)
    live("/orders", MasuTest.OrdersLive)
    live("/live/people", MasuTest.LivePeopleLive)
    live("/live/orders", MasuTest.LiveOrdersLive)
    live("/live/no-hook", MasuTest.NoHookLive)
    live("/edit/people", MasuTest.EditPeopleLive)
    live("/edit/orders", MasuTest.EditOrdersLive)
    live("/edit/update", MasuTest.UpdateLive)
    live("/edit/locked", MasuTest.LockedLive)
    live("/presence", MasuTest.PresenceLive)
    live("/views", MasuTest.ViewsLive)
    live("/tree", MasuTest.TreeLive)
    live("/details", MasuTest.DetailsLive)
    live("/groups", MasuTest.GroupsLive)
    live("/export", MasuTest.ExportLive)
    live("/select", MasuTest.SelectLive)
  end
end

defmodule MasuTest.Endpoint do
  @moduledoc "A Phoenix endpoint for the `Masu.Grid` and `Masu.Test` tests. It runs no server."
  use Phoenix.Endpoint, otp_app: :masu

  plug(Plug.Session, store: :cookie, key: "_masu_test", signing_salt: "masu-test")
  plug(MasuTest.Router)
end

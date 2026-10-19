defmodule MasuTest.ErrorHTML do
  @moduledoc "Error pages for the test endpoint."

  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end

defmodule MasuTest.Router do
  @moduledoc "The router of the test endpoint."
  use Phoenix.Router

  import Phoenix.LiveView.Router
  import Masu.Router

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
    live("/rows/tasks", MasuTest.TasksLive)
    live("/rows/people", MasuTest.RowsPeopleLive)
    live("/rows/things", MasuTest.RowsThingsLive)
    live("/counts", MasuTest.CountsLive)
    live("/blocks", MasuTest.BlocksLive)
    live("/ids", MasuTest.IdsLive)
    live("/theme", MasuTest.ThemeLive)
    live("/actions", MasuTest.ActionsLive)
    live("/chores", MasuTest.ChoresLive)
    live("/writes", MasuTest.WritesLive)
    live("/editors", MasuTest.EditorsLive)
    live("/placed", MasuTest.PlacedLive)
    live("/sales", MasuTest.SalesLive)
    live("/controlled-sales", MasuTest.ControlledSalesLive)
    live("/ledger", MasuTest.LedgerLive)
    live("/filter-ops", MasuTest.FilterOpsLive)
    live("/results", MasuTest.ResultsLive)
    live("/async", MasuTest.AsyncLive)
    live("/keyset", MasuTest.KeysetLive)
    live("/controlled", MasuTest.ControlledLive)
  end

  # In a scope: the grid's link goes through it.
  scope "/admin" do
    pipe_through(:browser)
    masu_exports()
  end
end

defmodule MasuTest.Endpoint do
  @moduledoc "A Phoenix endpoint for the `Masu.Grid` and `Masu.Test` tests. It runs no server."
  use Phoenix.Endpoint, otp_app: :masu

  plug(Plug.Session, store: :cookie, key: "_masu_test", signing_salt: "masu-test")
  plug(MasuTest.Router)
end

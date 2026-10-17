defmodule Masu.Router do
  @moduledoc """
  The route a grid's exports download from.

      defmodule MyAppWeb.Router do
        use MyAppWeb, :router
        import Masu.Router

        scope "/" do
          pipe_through [:browser, :require_authenticated_user]

          live "/orders", OrdersLive
          masu_exports "/masu/exports"
        end
      end

  A grid with `export` gives the browser a link to this route, with a
  token: encrypted with the endpoint's `secret_key_base`, good for one
  download, for five minutes, and from the LiveView that made it while
  it runs. Put it in a scope that requires the person to be signed in, as
  the grid's LiveView does: the token proves the grid made the export,
  the pipeline that the person is still who they were.

  The path goes through the scopes it is in, and the endpoint's
  `script_name`: a grid finds it in the router of its LiveView.

  With the app on several nodes, a download must reach a node that is
  connected to the LiveView's (distributed Erlang, as `Phoenix.PubSub`
  has it).
  """

  @doc """
  Mounts the export route at `path` (`"/masu/exports"` by default).
  """
  defmacro masu_exports(path \\ "/masu/exports") do
    quote bind_quoted: [path: path] do
      require Phoenix.Router

      Phoenix.Router.get(path <> "/:token", Masu.Export.Download, :download, as: :masu_export)

      @masu_export_path Phoenix.Router.scoped_path(__MODULE__, path)

      @doc false
      def __masu_export_path__, do: @masu_export_path
    end
  end
end

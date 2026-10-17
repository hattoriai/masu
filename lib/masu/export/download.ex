defmodule Masu.Export.Download do
  @moduledoc false
  # The route of `Masu.Router.masu_exports/1`: the file of the export the
  # token's ticket holds, as its rows are read. The response is chunked,
  # so the browser shows the download from its first rows; it ends when
  # the browser goes.

  @behaviour Plug

  import Plug.Conn

  alias Masu.Export
  alias Masu.Export.Ticket

  @salt "masu_export"

  @doc false
  # A token for the ticket `pid`, for its link.
  @spec token(module(), pid()) :: String.t()
  def token(endpoint, pid),
    do: Phoenix.Token.encrypt(endpoint, @salt, pid, max_age: div(Ticket.ttl(), 1000))

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{path_params: %{"token" => token}} = conn, _opts) do
    endpoint = Phoenix.Controller.endpoint_module(conn)
    max_age = div(Ticket.ttl(), 1000)

    with {:ok, pid} when is_pid(pid) <-
           Phoenix.Token.decrypt(endpoint, @salt, token, max_age: max_age),
         {:ok, %{export: export, format: format}} <- Ticket.take(pid) do
      send_export(conn, export, format)
    else
      {:error, :expired} -> refuse(conn, 410, "This export link has expired. Export again.")
      :gone -> refuse(conn, 410, "This export link was used, or has expired. Export again.")
      _invalid -> refuse(conn, 404, "No such export.")
    end
  end

  def call(conn, _opts), do: refuse(conn, 404, "No such export.")

  defp send_export(conn, export, format) do
    {type, ext} = Export.type(format)

    conn
    |> put_resp_content_type(type, if(format == :csv, do: "utf-8"))
    |> put_resp_header("content-disposition", disposition(export.name, ext))
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_chunked(200)
    |> send_chunks(Export.stream(export, format))
  end

  # Stops reading rows when the browser goes (a cancelled download).
  defp send_chunks(conn, stream) do
    Enum.reduce_while(stream, conn, fn data, conn ->
      case chunk(conn, data) do
        {:ok, conn} -> {:cont, conn}
        {:error, :closed} -> {:halt, conn}
      end
    end)
  end

  defp refuse(conn, status, message) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, message)
    |> halt()
  end

  @doc false
  # The file's name in a header: in ASCII, with no quote, backslash or
  # control character to end the header, and in UTF-8 (RFC 6266).
  @spec disposition(String.t(), String.t()) :: String.t()
  def disposition(name, ext) do
    name =
      name
      |> to_string()
      |> String.replace(~r/[\x00-\x1f\x7f"\\\/]/u, "")
      |> String.trim()
      |> case do
        "" -> "export"
        name -> name
      end

    ascii = String.replace(name, ~r/[^\x20-\x7e]/u, "_")
    utf8 = URI.encode(name <> "." <> ext, &URI.char_unreserved?/1)
    ~s(attachment; filename="#{ascii}.#{ext}"; filename*=UTF-8''#{utf8})
  end
end

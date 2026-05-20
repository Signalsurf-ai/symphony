defmodule SymphonyElixirWeb.LoopbackOnlyPlug do
  @moduledoc """
  Restricts local operator observability routes to loopback clients.
  """

  @behaviour Plug

  import Plug.Conn

  alias Plug.Conn
  alias SymphonyElixirWeb.Loopback

  @json_error Jason.encode!(%{
                error: %{
                  code: "observability_forbidden",
                  message: "Observability endpoints are loopback-only"
                }
              })
  @text_error "Observability endpoints are loopback-only"

  @impl Plug
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl Plug
  @spec call(Conn.t(), keyword()) :: Conn.t()
  def call(%Conn{remote_ip: remote_ip} = conn, _opts) do
    if Loopback.loopback?(remote_ip) do
      conn
    else
      forbid(conn)
    end
  end

  defp forbid(%Conn{} = conn) do
    if json_path?(conn.request_path) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(403, @json_error)
      |> halt()
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(403, @text_error)
      |> halt()
    end
  end

  defp json_path?(path), do: String.starts_with?(path, "/api/")
end

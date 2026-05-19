defmodule SymphonyElixirWeb.RawBodyReader do
  @moduledoc false

  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        {:ok, body, cache_body(conn, body)}

      {:more, body, conn} ->
        {:more, body, cache_body(conn, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cache_body(conn, body) do
    cached = conn.private[:raw_body] || ""
    Plug.Conn.put_private(conn, :raw_body, cached <> body)
  end
end

defmodule ClawswapWeb.Endpoint do
  @moduledoc """
  The watcher's web side, on 127.0.0.1 at the project's port: the JSON API the Stream Deck keys and your
  app's pages use, then Hologram's branch page at /.
  """

  use Phoenix.Endpoint, otp_app: :clawswap

  # Before the parsers, which would take the API's JSON bodies.
  plug(ClawswapWeb.Api)

  plug(Plug.Static, at: "/", from: :clawswap, gzip: false, only: ~w(hologram clawswap.css))

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Plug.Session, store: :cookie, key: "clawswap_session", signing_salt: "clawswap", same_site: "Lax")
  # Hologram's client keeps its session alive with HEAD /hologram/ping, and its router only has GET.
  plug(Plug.Head)
  plug(Hologram.Router)

  # Whatever Hologram didn't serve (/favicon.ico, say), so Bandit doesn't log it as a crash.
  plug(:not_found)

  defp not_found(conn, _opts), do: conn |> Plug.Conn.send_resp(404, "Not found") |> Plug.Conn.halt()
end

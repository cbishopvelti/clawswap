defmodule ClawswapWeb.Api do
  @moduledoc """
  The watcher's JSON API:

      GET  /state                    the watcher's state (see README.md)
      POST /switch  {"branch": ...}  202, then follow /state's switch
      POST /pull                     the checkout's branch; 202 (switch.pull), or "Already up to date"
      POST /refresh                  look at GitHub now

  It answers this machine only, and browsers only from the project's origins: a page elsewhere can't make
  the browser send a JSON POST here without a preflight, which only those origins pass. The Host check
  stops DNS rebinding. Other paths go on to the page.
  """

  @behaviour Plug

  import Plug.Conn

  alias Clawswap.Watcher

  @paths ["/state", "/switch", "/pull", "/refresh"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{request_path: path} = conn, _opts) when path in @paths do
    project = Clawswap.Application.project()
    origin = conn |> get_req_header("origin") |> List.first()
    own = ["http://localhost:#{project.port}", "http://127.0.0.1:#{project.port}"]
    allowed = origin && (MapSet.member?(project.origins, origin) or origin in own) && origin
    host = conn |> get_req_header("host") |> List.first() || ""

    conn = if allowed, do: conn |> put_resp_header("access-control-allow-origin", allowed) |> put_resp_header("vary", "Origin"), else: conn

    cond do
      not Regex.match?(~r/^(localhost|127\.0\.0\.1)(:\d+)?$/, host) or (origin && !allowed) ->
        json(conn, 403, %{error: "Forbidden"})

      conn.method == "OPTIONS" ->
        conn
        |> put_resp_header("access-control-allow-methods", "GET, POST")
        |> put_resp_header("access-control-allow-headers", "Content-Type")
        |> send_resp(204, "")
        |> halt()

      conn.method == "GET" and path == "/state" ->
        json(conn, 200, Watcher.state())

      conn.method != "POST" or not String.starts_with?(conn |> get_req_header("content-type") |> List.first() || "", "application/json") ->
        json(conn, 404, %{error: "Not found"})

      true ->
        {:ok, body, conn} = read_body(conn)
        post(conn, path, body)
    end
  end

  def call(conn, _opts), do: conn

  defp post(conn, "/refresh", _body), do: json(conn, 200, Watcher.refresh())

  defp post(conn, "/switch", body) do
    branch =
      case JSON.decode(if(body == "", do: "{}", else: body)) do
        {:ok, %{"branch" => branch}} -> to_string(branch)
        _ -> ""
      end

    answer(conn, Watcher.switch_to(branch))
  end

  defp post(conn, "/pull", _body), do: answer(conn, Watcher.pull())

  defp answer(conn, {:ok, state}), do: json(conn, 202, state)
  defp answer(conn, {:error, status, message}), do: json(conn, status, %{error: message})

  defp json(conn, status, body) do
    conn
    |> put_resp_header("content-type", "application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, JSON.encode!(body))
    |> halt()
  end
end

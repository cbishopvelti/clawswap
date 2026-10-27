defmodule Clawswap.GitHub do
  @moduledoc """
  Open pull requests from GitHub's API, for their titles on the keys. Keeps the ETag so an unchanged list
  is a 304, which doesn't count against the rate limit.
  """

  alias Clawswap.Run

  @doc "GITHUB_TOKEN, else the gh CLI's token if it's logged in."
  def token do
    case System.get_env("GITHUB_TOKEN") do
      token when token not in [nil, ""] ->
        token

      _ ->
        case Run.capture("gh", ["auth", "token"]) do
          {:ok, out} when out != "" -> String.trim(out)
          _ -> nil
        end
    end
  end

  @doc """
  A reader for `repo`'s open pull requests: call it with the previous reader state (nil the first time)
  and get `{:ok, pulls, state}` or `{:error, message, state}`. `pulls` is
  `%{branch => %{number, title, updated_at, draft}}`. `get` does the request (for tests).
  """
  def read_pulls(repo, token, cache, get \\ &get/2) do
    url = "https://api.github.com/repos/#{repo}/pulls?state=open&per_page=100&sort=updated&direction=desc"

    headers =
      [
        {"accept", "application/vnd.github+json"},
        {"authorization", "Bearer #{token}"},
        {"x-github-api-version", "2022-11-28"},
        {"user-agent", "clawswap"}
      ] ++ if(cache, do: [{"if-none-match", cache.etag}], else: [])

    case get.(url, headers) do
      {:ok, 304, _headers, _body} when cache != nil ->
        {:ok, cache.pulls, cache}

      {:ok, 200, response_headers, body} ->
        pulls =
          body
          |> JSON.decode!()
          |> Enum.filter(&(get_in(&1, ["head", "repo", "full_name"]) == repo))
          |> Map.new(fn p ->
            {p["head"]["ref"], %{number: p["number"], title: p["title"], updated_at: p["updated_at"], draft: !!p["draft"]}}
          end)

        etag = Enum.find_value(response_headers, fn {k, v} -> if String.downcase(k) == "etag", do: v end)
        {:ok, pulls, etag && %{etag: etag, pulls: pulls}}

      {:ok, status, _, _} ->
        {:error, "GitHub answered #{status}", cache}

      {:error, reason} ->
        {:error, reason, cache}
    end
  end

  @doc "A GET with :httpc: `{:ok, status, headers, body}` or `{:error, message}`."
  def get(url, headers) do
    :inets.start()
    :ssl.start()
    request = {String.to_charlist(url), Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)}

    case :httpc.request(:get, request, [ssl: ssl_options(), timeout: 15_000], body_format: :binary) do
      {:ok, {{_, status, _}, response_headers, body}} ->
        {:ok, status, Enum.map(response_headers, fn {k, v} -> {to_string(k), to_string(v)} end), body}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  def ssl_options do
    [verify: :verify_peer, cacerts: :public_key.cacerts_get(), customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]]
  end
end

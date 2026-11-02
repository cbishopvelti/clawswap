defmodule Clawswap.GitHub do
  @moduledoc """
  Open pull requests from GitHub's API, for their titles on the keys. Keeps the ETag so an unchanged list
  is a 304, which doesn't count against the rate limit. And the repo's webhook, for `clawswap smee`.
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
  `%{branch => %{number, title, updated_at, draft, claude}}` (`claude`: `claude_link/1` of its description).
  `get` does the request (for tests).
  """
  def read_pulls(repo, token, cache, get \\ &get/2) do
    url = "https://api.github.com/repos/#{repo}/pulls?state=open&per_page=100&sort=updated&direction=desc"

    headers = api_headers(token) ++ if(cache, do: [{"if-none-match", cache.etag}], else: [])

    case get.(url, headers) do
      {:ok, 304, _headers, _body} when cache != nil ->
        {:ok, cache.pulls, cache}

      {:ok, 200, response_headers, body} ->
        pulls =
          body
          |> JSON.decode!()
          |> Enum.filter(&(get_in(&1, ["head", "repo", "full_name"]) == repo))
          |> Map.new(fn p ->
            {p["head"]["ref"], %{number: p["number"], title: p["title"], updated_at: p["updated_at"], draft: !!p["draft"], claude: claude_link(p["body"])}}
          end)

        etag = Enum.find_value(response_headers, fn {k, v} -> if String.downcase(k) == "etag", do: v end)
        {:ok, pulls, etag && %{etag: etag, pulls: pulls}}

      {:ok, status, _, _} ->
        {:error, "GitHub answered #{status}", cache}

      {:error, reason} ->
        {:error, reason, cache}
    end
  end

  @doc """
  The Claude Code link in a PR's description, or nil: the project thread that asked for it (a Claude
  project's PR starts with one), else the session that wrote it.
  """
  def claude_link(body) when is_binary(body) do
    Enum.find_value([~r{https://claude\.ai/code/project/[^\s)\]"'<>]+}, ~r{https://claude\.ai/code/session_\w+}], fn regex ->
      case Regex.run(regex, body) do
        [link] -> link
        _ -> nil
      end
    end)
  end

  def claude_link(_), do: nil

  # The events the watcher looks again for: a branch made, deleted or pushed, a PR opened or retitled.
  @hook_events ["create", "delete", "pull_request", "push"]

  @doc """
  Makes sure `repo` has a webhook that sends to `channel`, and takes away the one that sent to
  `old_channel` (the channel this replaces) when `remove_old?` says so: it's called with that hook's URL.
  `request` does the requests (for tests). Returns `{:ok, :created | :exists, removed}` (`removed`: whether
  the old hook went) or `{:error, message}`, e.g. when the token may not manage the repo's webhooks.
  """
  def ensure_hook(repo, token, channel, old_channel, remove_old?, request \\ &request/4) do
    hooks_url = "https://api.github.com/repos/#{repo}/hooks"
    headers = api_headers(token)

    with {:ok, hooks} <- hooks(request, hooks_url, headers) do
      url_of = &get_in(&1, ["config", "url"])

      created =
        if Enum.any?(hooks, &(url_of.(&1) == channel)) do
          {:ok, :exists}
        else
          body = JSON.encode!(%{name: "web", active: true, events: @hook_events, config: %{url: channel, content_type: "json"}})

          case request.(:post, hooks_url, headers, body) do
            {:ok, 201, _, _} -> {:ok, :created}
            {:ok, status, _, answer} -> {:error, refused(status, answer)}
            {:error, reason} -> {:error, reason}
          end
        end

      with {:ok, outcome} <- created do
        removed =
          case old_channel != channel && Enum.find(hooks, &(url_of.(&1) == old_channel)) do
            %{"id" => id} -> remove_old?.(old_channel) and match?({:ok, 204, _, _}, request.(:delete, "#{hooks_url}/#{id}", headers, nil))
            _ -> false
          end

        {:ok, outcome, removed}
      end
    end
  end

  defp hooks(request, url, headers) do
    case request.(:get, url <> "?per_page=100", headers, nil) do
      {:ok, 200, _, body} -> {:ok, JSON.decode!(body)}
      {:ok, status, _, answer} -> {:error, refused(status, answer)}
      {:error, reason} -> {:error, reason}
    end
  end

  # GitHub answers 404 rather than 403 to a token that can't see the repo's settings.
  defp refused(status, _answer) when status in [403, 404],
    do:
      "GitHub answered #{status}: the token needs admin on the repo (gh's default login has it if you do; a fine-grained token needs Webhooks: read and write)"

  defp refused(status, answer) do
    message = with({:ok, %{"message" => m}} <- JSON.decode(answer), do: ": #{m}", else: (_ -> ""))
    "GitHub answered #{status}#{message}"
  end

  defp api_headers(token) do
    [
      {"accept", "application/vnd.github+json"},
      {"authorization", "Bearer #{token}"},
      {"x-github-api-version", "2022-11-28"},
      {"user-agent", "clawswap"}
    ]
  end

  @doc "A GET with :httpc: `{:ok, status, headers, body}` or `{:error, message}`."
  def get(url, headers), do: request(:get, url, headers, nil)

  @doc "A request with :httpc (`body` is JSON, or nil): `{:ok, status, headers, body}` or `{:error, message}`."
  def request(method, url, headers, body) do
    :inets.start()
    :ssl.start()
    headers = Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
    request = if body, do: {String.to_charlist(url), headers, ~c"application/json", body}, else: {String.to_charlist(url), headers}

    case :httpc.request(method, request, [ssl: ssl_options(), timeout: 15_000], body_format: :binary) do
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

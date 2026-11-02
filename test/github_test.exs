defmodule Clawswap.GitHubTest do
  use ExUnit.Case, async: true

  alias Clawswap.GitHub

  @hooks "https://api.github.com/repos/me/app/hooks"

  # A stand-in for GitHub's hooks API: answers from `hooks` and tells the test what was asked.
  defp api(hooks, post_status \\ 201) do
    test = self()

    fn method, url, _headers, body ->
      send(test, {method, url, body && JSON.decode!(body)})

      case {method, url} do
        {:get, @hooks <> "?" <> _} -> {:ok, 200, [], JSON.encode!(hooks)}
        {:post, @hooks} -> {:ok, post_status, [], ~s({"message":"Validation Failed"})}
        {:delete, @hooks <> "/" <> _} -> {:ok, 204, [], ""}
      end
    end
  end

  defp hook(id, url), do: %{"id" => id, "config" => %{"url" => url}}

  test "adds the webhook for the channel, with the events the watcher wants" do
    assert {:ok, :created, false} = GitHub.ensure_hook("me/app", "t", "https://smee.io/new", nil, fn _ -> flunk() end, api([]))
    assert_received {:post, @hooks, %{"events" => events, "config" => %{"url" => "https://smee.io/new", "content_type" => "json"}}}
    assert Enum.sort(events) == ["create", "delete", "pull_request", "push"]
  end

  test "leaves an existing webhook for the channel alone" do
    assert {:ok, :exists, false} =
             GitHub.ensure_hook("me/app", "t", "https://smee.io/a", "https://smee.io/a", fn _ -> flunk() end, api([hook(1, "https://smee.io/a")]))

    refute_received {:post, _, _}
  end

  test "removes the old channel's webhook only when asked to" do
    hooks = [hook(1, "https://smee.io/old"), hook(2, "https://example.com/ci")]

    assert {:ok, :created, true} =
             GitHub.ensure_hook("me/app", "t", "https://smee.io/new", "https://smee.io/old", fn "https://smee.io/old" -> true end, api(hooks))

    assert_received {:delete, @hooks <> "/1", nil}

    assert {:ok, :created, false} = GitHub.ensure_hook("me/app", "t", "https://smee.io/new", "https://smee.io/old", fn _ -> false end, api(hooks))
    refute_received {:delete, _, _}
  end

  test "says what the token needs when GitHub refuses" do
    refuse = fn _, _, _, _ -> {:ok, 404, [], ~s({"message":"Not Found"})} end
    assert {:error, message} = GitHub.ensure_hook("me/app", "t", "https://smee.io/new", nil, fn _ -> false end, refuse)
    assert message =~ "admin"

    assert {:error, "GitHub answered 422: Validation Failed"} = GitHub.ensure_hook("me/app", "t", "https://smee.io/new", nil, fn _ -> false end, api([], 422))
  end
end

defmodule Clawswap.Doctor do
  @moduledoc """
  `clawswap doctor`: checks what clawswap needs on this machine, and in the project's repo when it's run
  from one, and prints the fix for anything missing.

  It uses nothing but Elixir's standard library and no other clawswap module, so `bin/clawswap doctor`
  can run it with plain `elixir` before clawswap's deps are fetched or compiled (Node.js missing stops
  `mix compile`, so that's when it's most wanted).

  Each check is `%{name, level, found, why, fix}`. `level` is `:ok`, `:missing` (clawswap won't work
  without it, so doctor exits 1) or `:optional` (a part of clawswap that's optional won't work).
  """

  @tool Path.expand("../..", __DIR__)

  # The same minimums as Clawswap.Zellij and Clawswap.Tmux (doctor_test.exs checks they agree).
  @zellij [0, 44]
  @tmux [3, 1]
  @elixir [1, 19]
  @otp 26

  @doc "Runs the checks, prints them and halts: 0 when nothing needed is missing, else 1."
  def main do
    checks = checks(system())
    IO.write(report(checks))
    System.halt(if Enum.any?(checks, &(&1.level == :missing)), do: 1, else: 0)
  end

  @doc """
  What doctor looks at, for `checks/1`; tests pass their own. `cmd` runs a program and gives
  `{:ok, output}` or `:error` (also when it isn't installed), `find` is `System.find_executable/1`.
  """
  def system do
    %{
      elixir: System.version(),
      otp: to_string(:erlang.system_info(:otp_release)),
      os: :os.type(),
      env: System.get_env(),
      cmd: &cmd/2,
      find: &System.find_executable/1,
      exists?: &File.exists?/1,
      tool: @tool,
      repo: System.get_env("CLAWSWAP_REPO") || File.cwd!()
    }
  end

  defp cmd(program, args) do
    with path when is_binary(path) <- System.find_executable(program),
         {out, 0} <- System.cmd(path, args, stderr_to_stdout: true) do
      {:ok, out}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @doc "Every check, in the order they're printed."
  def checks(sys) do
    [
      elixir(sys),
      otp(sys),
      git(sys),
      multiplexer(sys),
      nodejs(sys),
      inotify(sys),
      built(sys),
      github(sys),
      chrome(sys)
    ]
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(project(sys))
  end

  defp check(name, level, found, why, fix \\ nil), do: %{name: name, level: level, found: found, why: why, fix: fix}

  defp elixir(sys) do
    version = numbers(sys.elixir)

    if at_least?(version, @elixir),
      do: check("Elixir", :ok, sys.elixir, nil),
      else:
        check(
          "Elixir",
          :missing,
          sys.elixir,
          "Hologram, the page's framework, needs 1.19 or newer.",
          "Install Elixir 1.19 or newer: https://elixir-lang.org/install.html"
        )
  end

  defp otp(sys) do
    if at_least?(numbers(sys.otp), [@otp]),
      do: check("Erlang/OTP", :ok, sys.otp, nil),
      else:
        check(
          "Erlang/OTP",
          :missing,
          sys.otp,
          "The watcher needs OTP 26 or newer.",
          "Install Erlang/OTP 26 or newer (it comes with Elixir's installers): https://elixir-lang.org/install.html"
        )
  end

  defp git(sys) do
    case version(sys, "git", ["--version"]) do
      nil -> check("git", :missing, nil, "Switching branch is git checkout and pull.", "Install git (sudo apt install git, or brew install git)")
      v -> check("git", :ok, Enum.join(v, "."), nil)
    end
  end

  # zellij or tmux: one new enough is all it takes.
  defp multiplexer(sys) do
    zellij = version(sys, "zellij", ["--version"])
    tmux = version(sys, "tmux", ["-V"])
    shown = fn name, v -> v && "#{name} #{Enum.join(v, ".")}" end

    cond do
      at_least?(zellij, @zellij) ->
        check("zellij or tmux", :ok, Enum.join(Enum.reject([shown.("zellij", zellij), at_least?(tmux, @tmux) && shown.("tmux", tmux)], &(!&1)), ", "), nil)

      at_least?(tmux, @tmux) ->
        check("zellij or tmux", :ok, shown.("tmux", tmux) <> if(zellij, do: " (zellij #{Enum.join(zellij, ".")} is too old to use)", else: ""), nil)

      true ->
        found = [shown.("zellij", zellij), shown.("tmux", tmux)] |> Enum.reject(&is_nil/1) |> Enum.join(", ")

        check(
          "zellij or tmux",
          :missing,
          if(found == "", do: nil, else: found <> ", too old"),
          "The servers run in a zellij (0.44 or newer) or tmux (3.1 or newer) session.",
          "Install tmux (sudo apt install tmux, or brew install tmux), or zellij 0.44+ from https://github.com/zellij-org/zellij/releases or cargo install --locked zellij"
        )
    end
  end

  defp nodejs(sys) do
    case version(sys, "node", ["--version"]) do
      nil ->
        check(
          "Node.js",
          :missing,
          nil,
          "mix compile needs it: Hologram bundles the page's JavaScript with esbuild, which it installs with npm. Nothing of clawswap's own is JavaScript.",
          "Install Node.js: https://nodejs.org (or sudo apt install nodejs npm, or brew install node)"
        )

      v ->
        check("Node.js", :ok, Enum.join(v, "."), nil)
    end
  end

  defp inotify(%{os: {:unix, :linux}} = sys) do
    if sys.find.("inotifywait"),
      do: check("inotify-tools", :ok, "inotifywait", nil),
      else:
        check(
          "inotify-tools",
          :missing,
          nil,
          "The page won't start without it on Linux: Hologram's dev server watches its files with inotifywait.",
          "sudo apt install inotify-tools"
        )
  end

  defp inotify(_), do: nil

  # clawswap's own deps and build, in its clone.
  defp built(sys) do
    fix = "cd #{sys.tool} && mix deps.get && mix compile"

    cond do
      !sys.exists?.(Path.join(sys.tool, "mix.exs")) -> nil
      !sys.exists?.(Path.join(sys.tool, "deps/hologram")) -> check("clawswap's deps", :missing, nil, "They haven't been fetched yet.", fix)
      !sys.exists?.(Path.join(sys.tool, "_build/dev/lib/clawswap")) -> check("clawswap's deps", :missing, "fetched", "clawswap hasn't been compiled yet.", fix)
      true -> check("clawswap's deps", :ok, "fetched and compiled", nil)
    end
  end

  defp github(sys) do
    why = "For pull-request titles on the keys, and to list only branches with an open PR."

    cond do
      sys.env["GITHUB_TOKEN"] not in [nil, ""] -> check("GitHub token", :ok, "GITHUB_TOKEN", nil)
      !sys.find.("gh") -> check("GitHub token", :optional, nil, why, "Install the gh CLI (https://cli.github.com) and run gh auth login, or set GITHUB_TOKEN")
      match?({:ok, out} when out != "", sys.cmd.("gh", ["auth", "token"])) -> check("GitHub token", :ok, "gh is logged in", nil)
      true -> check("GitHub token", :optional, "gh, not logged in", why, "gh auth login")
    end
  end

  # Walkthroughs drive Chrome through chromedriver, which needs the same major version.
  defp chrome(sys) do
    why = "Walkthroughs drive Chrome through chromedriver, and the two have to be the same major version."
    chrome = chrome_path(sys)
    driver = sys.env["CLAWSWAP_CHROMEDRIVER"] || "chromedriver"
    chrome_v = chrome && version(sys, chrome, ["--version"])
    driver_v = version(sys, driver, ["--version"])
    shown = fn name, v -> "#{name} #{Enum.join(v, ".")}" end

    case {chrome_v, driver_v} do
      {[major | _], [major | _]} ->
        check("Chrome and chromedriver", :ok, "#{shown.("Chrome", chrome_v)}, #{shown.("chromedriver", driver_v)}", nil)

      {[chrome_major | _], [_ | _]} ->
        check(
          "Chrome and chromedriver",
          :optional,
          "#{shown.("Chrome", chrome_v)}, #{shown.("chromedriver", driver_v)}",
          why,
          "Install the chromedriver for Chrome #{chrome_major} (https://googlechromelabs.github.io/chrome-for-testing/, or npx @puppeteer/browsers install chromedriver@#{chrome_major}) and point CLAWSWAP_CHROMEDRIVER at it"
        )

      {nil, nil} ->
        check(
          "Chrome and chromedriver",
          :optional,
          nil,
          why,
          "Install both, e.g. npx @puppeteer/browsers install chrome@stable chromedriver@stable, and set CLAWSWAP_CHROME and CLAWSWAP_CHROMEDRIVER if they aren't on the PATH"
        )

      {nil, _} ->
        check(
          "Chrome and chromedriver",
          :optional,
          shown.("chromedriver", driver_v) <> ", no Chrome",
          why,
          "Install Chrome #{hd(driver_v)}, or set CLAWSWAP_CHROME to the one you have"
        )

      {_, nil} ->
        check(
          "Chrome and chromedriver",
          :optional,
          shown.("Chrome", chrome_v) <> ", no chromedriver",
          why,
          "Install the chromedriver for Chrome #{hd(chrome_v)} (your package manager, or https://googlechromelabs.github.io/chrome-for-testing/), or set CLAWSWAP_CHROMEDRIVER"
        )
    end
  end

  # Where Wallaby looks for Chrome, unless CLAWSWAP_CHROME names it.
  defp chrome_path(sys) do
    case {sys.env["CLAWSWAP_CHROME"], sys.os} do
      {path, _} when path not in [nil, ""] ->
        path

      {_, {:unix, :darwin}} ->
        Enum.find(["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/Applications/Chromium.app/Contents/MacOS/Chromium"], sys.exists?)

      _ ->
        Enum.find_value(["google-chrome", "google-chrome-stable", "chromium", "chromium-browser"], sys.find)
    end
  end

  # The project's own setup, when doctor runs inside its repo.
  defp project(sys) do
    case sys.cmd.("git", ["-C", sys.repo, "rev-parse", "--show-toplevel", "--git-dir"]) do
      {:ok, out} ->
        [root, git_dir] = String.split(out, "\n", trim: true)
        git_dir = Path.expand(git_dir, sys.repo)

        # Run from clawswap's own clone there's no project to look at.
        if root == sys.tool do
          []
        else
          config =
            case Enum.find(["clawswap.exs", "clawswap.yml", "clawswap.yaml"], &sys.exists?.(Path.join(root, &1))) do
              nil -> check("Config", :missing, nil, "#{root} has no clawswap.exs (or clawswap.yml).", "clawswap init, in #{root}")
              name -> check("Config", :ok, name, nil)
            end

          [config, smee(sys, Path.join(git_dir, "clawswap.json"))]
        end

      :error ->
        []
    end
  end

  defp smee(sys, local) do
    channel =
      if sys.env["CLAWSWAP_SMEE"] not in [nil, ""] do
        sys.env["CLAWSWAP_SMEE"]
      else
        with true <- sys.exists?.(local),
             {:ok, text} <- File.read(local),
             {:ok, %{"smee" => url}} when is_binary(url) <- JSON.decode(text) do
          url
        else
          _ -> nil
        end
      end

    cond do
      channel ->
        check("Webhook", :ok, "#{channel} (this checkout's own channel)", nil)

      shared = shared_channel(sys) ->
        check("Webhook", :ok, "#{shared} (the shared channel; the daemon adds the repo's webhook for it)", nil)

      true ->
        check("Webhook", :ok, "the shared smee.io channel (the daemon makes it, and adds the repo's webhook for it)", nil)
    end
  end

  # The daemon's shared channel, as Clawswap.SharedSmee keeps it (this module stays stdlib-only).
  defp shared_channel(sys) do
    state = if sys.env["XDG_STATE_HOME"] not in [nil, ""], do: sys.env["XDG_STATE_HOME"], else: Path.join(sys.env["HOME"] || "~", ".local/state")
    file = Path.join([state, "clawswap", "smee.json"])

    with true <- sys.exists?.(file),
         {:ok, text} <- File.read(file),
         {:ok, %{"channel" => "http" <> _ = url}} <- JSON.decode(text) do
      url
    else
      _ -> nil
    end
  end

  @doc "The checks as doctor prints them."
  def report(checks) do
    lines =
      Enum.map(checks, fn c ->
        mark = %{ok: "ok      ", missing: "MISSING ", optional: "optional"}[c.level]
        head = "  #{mark}  #{c.name}#{if c.found, do: ": #{c.found}"}"
        body = for text <- [c.why, c.fix && "Fix: #{c.fix}"], text, do: "              #{text}"
        Enum.join([head | body], "\n")
      end)

    missing = Enum.count(checks, &(&1.level == :missing))
    optional = Enum.count(checks, &(&1.level == :optional))

    summary =
      cond do
        missing > 0 -> "#{missing} thing#{if missing > 1, do: "s"} clawswap needs #{if missing > 1, do: "are", else: "is"} missing."
        optional > 0 -> "clawswap has what it needs (#{optional} optional thing#{if optional > 1, do: "s"} not set up)."
        true -> "clawswap has everything it needs."
      end

    Enum.join(lines, "\n") <> "\n\n" <> summary <> "\n"
  end

  # The first version number in a program's --version output, as integers (nil if it isn't there).
  defp version(sys, program, args) do
    case sys.cmd.(program, args) do
      {:ok, out} -> numbers(out)
      :error -> nil
    end
  end

  @doc false
  def numbers(text) do
    case Regex.run(~r/(\d+)(?:\.(\d+))?(?:\.(\d+))?/, text || "", capture: :all_but_first) do
      nil -> nil
      parts -> for p <- parts, p != "", do: String.to_integer(p)
    end
  end

  @doc false
  def at_least?(nil, _), do: false
  def at_least?(version, min), do: pad(version, length(min)) >= min

  defp pad(version, n), do: Enum.take(version ++ List.duplicate(0, n), max(n, length(version)))
end

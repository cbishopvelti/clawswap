defmodule Clawswap.DoctorTest do
  use ExUnit.Case, async: true

  alias Clawswap.{Config, Doctor, Tmux, Zellij}

  # A machine with everything: programs answer with the versions in `outputs`.
  defp sys(overrides \\ %{}) do
    outputs =
      Map.merge(
        %{
          "git" => "git version 2.43.0",
          "zellij" => "zellij 0.44.1",
          "tmux" => "tmux 3.4",
          "node" => "v22.1.0",
          "google-chrome" => "Google Chrome 131.0.6778.85",
          "chromedriver" => "ChromeDriver 131.0.6778.69 (abc)",
          "gh" => "gho_token\n"
        },
        overrides[:outputs] || %{}
      )

    base = %{
      elixir: "1.19.6",
      otp: "28",
      os: {:unix, :linux},
      env: %{},
      # Not in a repo: git -C <repo> fails.
      cmd: fn
        "git", ["-C" | _] -> :error
        program, _args -> if out = outputs[program] || outputs[Path.basename(program)], do: {:ok, out}, else: :error
      end,
      find: fn program -> (program == "inotifywait" or outputs[program] != nil) && "/usr/bin/#{program}" end,
      exists?: fn _ -> true end,
      tool: "/clawswap",
      repo: "/nowhere"
    }

    Map.merge(base, Map.drop(overrides, [:outputs]))
  end

  defp levels(sys), do: Map.new(Doctor.checks(sys), &{&1.name, &1.level})
  defp find(sys, name), do: Enum.find(Doctor.checks(sys), &(&1.name == name))

  test "everything there is all ok" do
    assert levels(sys()) |> Map.values() |> Enum.uniq() == [:ok]
    assert Doctor.report(Doctor.checks(sys())) =~ "clawswap has everything it needs."
  end

  test "an old Elixir or OTP is missing" do
    assert levels(sys(%{elixir: "1.18.4"}))["Elixir"] == :missing
    assert levels(sys(%{otp: "25"}))["Erlang/OTP"] == :missing
  end

  test "zellij or tmux: either new enough will do" do
    assert levels(sys(%{outputs: %{"zellij" => nil}}))["zellij or tmux"] == :ok
    assert find(sys(%{outputs: %{"zellij" => "zellij 0.40.0"}}), "zellij or tmux").found =~ "too old to use"
    assert levels(sys(%{outputs: %{"tmux" => nil}}))["zellij or tmux"] == :ok

    old = find(sys(%{outputs: %{"zellij" => "zellij 0.40.0", "tmux" => "tmux 3.0a"}}), "zellij or tmux")
    assert old.level == :missing
    assert old.found == "zellij 0.40.0, tmux 3.0, too old"
    assert old.fix =~ "apt install tmux"
  end

  test "agrees with Zellij and Tmux on the versions they need" do
    for v <- [[0, 43, 9], [0, 44, 0], [1, 0, 0]], do: assert(Doctor.at_least?(v, [0, 44]) == Zellij.version_ok?(v))
    for v <- [[3, 0], [3, 1], [4, 0]], do: assert(Doctor.at_least?(v, [3, 1]) == Tmux.version_ok?(v))
  end

  test "Node.js and inotify-tools are needed, inotify-tools only on Linux" do
    assert find(sys(%{outputs: %{"node" => nil}}), "Node.js").fix =~ "nodejs.org"
    no_inotify = sys(%{find: fn _ -> nil end})
    assert levels(no_inotify)["inotify-tools"] == :missing
    refute Map.has_key?(levels(%{no_inotify | os: {:unix, :darwin}}), "inotify-tools")
  end

  test "says to fetch and compile clawswap's deps" do
    unfetched = find(sys(%{exists?: &(&1 == "/clawswap/mix.exs")}), "clawswap's deps")
    assert unfetched.level == :missing
    assert unfetched.fix == "cd /clawswap && mix deps.get && mix compile"
  end

  test "a GitHub token is optional: GITHUB_TOKEN, else gh logged in" do
    assert find(sys(%{env: %{"GITHUB_TOKEN" => "t"}, outputs: %{"gh" => nil}}), "GitHub token").found == "GITHUB_TOKEN"
    assert find(sys(%{outputs: %{"gh" => ""}}), "GitHub token").fix == "gh auth login"
    no_gh = sys(%{outputs: %{"gh" => nil}})
    assert levels(no_gh)["GitHub token"] == :optional
    assert find(no_gh, "GitHub token").fix =~ "cli.github.com"
  end

  test "Chrome and chromedriver need the same major version" do
    differ = find(sys(%{outputs: %{"chromedriver" => "ChromeDriver 129.0.1"}}), "Chrome and chromedriver")
    assert differ.level == :optional
    assert differ.fix =~ "chromedriver for Chrome 131"

    named =
      sys(%{
        env: %{"CLAWSWAP_CHROME" => "/opt/chrome", "CLAWSWAP_CHROMEDRIVER" => "/opt/driver"},
        outputs: %{"/opt/chrome" => "Chromium 140.0", "/opt/driver" => "ChromeDriver 140.1"}
      })

    assert levels(named)["Chrome and chromedriver"] == :ok
  end

  test "missing something needed says so in the summary" do
    report = Doctor.report(Doctor.checks(sys(%{outputs: %{"node" => nil, "git" => nil}})))
    assert report =~ "MISSING   Node.js"
    assert report =~ "2 things clawswap needs are missing."
  end

  describe "in a project's repo" do
    setup do
      root = Path.join(System.tmp_dir!(), "clawswap-doctor-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      {_, 0} = System.cmd("git", ["init", "-q", root])
      on_exit(fn -> File.rm_rf!(root) end)
      # The real git and filesystem for the project; the programs from sys/1.
      real = sys()

      cmd = fn
        "git", args -> with {out, 0} <- System.cmd("git", args, stderr_to_stdout: true), do: {:ok, out}, else: (_ -> :error)
        program, args -> real.cmd.(program, args)
      end

      %{root: root, sys: %{real | repo: root, cmd: cmd, exists?: &File.exists?/1, tool: Path.expand("../", __DIR__)}}
    end

    test "wants a config, and suggests the webhook", %{root: root, sys: sys} do
      assert find(sys, "Config").fix == "clawswap init, in #{root}"
      assert levels(sys)["Webhook"] == :optional

      File.write!(Path.join(root, "clawswap.yml"), "servers: {}\n")
      File.write!(Path.join([root, ".git", "clawswap.json"]), ~s({"smee": "https://smee.io/abc"}))
      assert find(sys, "Config").found == "clawswap.yml"
      assert find(sys, "Webhook").found == "https://smee.io/abc"
    end

    test "knows the config's names" do
      assert Config.file_names() == ["clawswap.exs", "clawswap.yml", "clawswap.yaml"]
    end
  end
end

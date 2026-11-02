defmodule Clawswap.CLI.Forgive do
  @moduledoc """
  What the command line makes of input that isn't quite right: the closest command to a typo, and the branch
  meant by a PR number, a short name or part of a branch's name.
  """

  # How alike (String.jaro_distance/2) a word must be to a candidate to be offered as "did you mean".
  @alike 0.75

  @doc "The candidate closest to `word`, when one is close enough to be the one meant; else nil."
  def closest(word, candidates) do
    word = String.downcase(word)

    by_prefix = Enum.filter(candidates, &String.starts_with?(String.downcase(&1), word))

    case by_prefix do
      [one] ->
        one

      _ ->
        candidates
        |> Enum.map(&{&1, String.jaro_distance(word, String.downcase(&1))})
        |> Enum.max_by(&elem(&1, 1), fn -> {nil, 0} end)
        |> then(fn {best, score} -> if score >= @alike, do: best end)
    end
  end

  @doc """
  The listed branch `input` names, from the watcher's branches (maps with "branch", and "short" and
  "pr" when there are). In order: the branch's full name (or origin/name), a PR number ("23" or "#23"),
  its short name or last path segment, then a part of its name, ignoring case. Returns `{:ok, branch}`,
  `{:ambiguous, [branch]}` when a part matches more than one, or `{:none, suggestion | nil}`.
  """
  def branch(input, branches) do
    input = String.trim(input)
    name = String.replace_prefix(input, "origin/", "")
    names = Enum.map(branches, & &1["branch"])
    lower = String.downcase(name)

    number = pr_number(input)
    by_pr = number && Enum.find(branches, &(get_in(&1, ["pr", "number"]) == number))

    cond do
      name in names ->
        {:ok, name}

      by_pr ->
        {:ok, by_pr["branch"]}

      (found = Enum.filter(branches, &(String.downcase(short(&1)) == lower))) != [] ->
        one_or_many(found)

      (found = Enum.filter(branches, &String.contains?(String.downcase(&1["branch"]), lower))) != [] ->
        one_or_many(found)

      true ->
        {:none, closest(name, names) || full_name(closest(name, Enum.map(branches, &short/1)), branches)}
    end
  end

  defp one_or_many([b]), do: {:ok, b["branch"]}
  defp one_or_many(many), do: {:ambiguous, Enum.map(many, & &1["branch"])}

  defp pr_number(input) do
    case Integer.parse(String.trim_leading(input, "#")) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  # The branch's short name (the config's short_name), or the part after its last /.
  defp short(b), do: b["short"] || b["branch"] |> String.split("/") |> List.last()

  defp full_name(nil, _), do: nil
  defp full_name(short, branches), do: Enum.find_value(branches, &(short(&1) == short && &1["branch"]))
end

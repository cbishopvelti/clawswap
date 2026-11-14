defmodule Clawswap.DocLinksTest do
  use ExUnit.Case, async: true

  # Messages and the starter config point people at the docs site (docs/ on GitHub Pages). Each link there
  # must name a page in docs/, and an id on it when it has a #fragment.
  test "every docs-site link in lib/ names a page and anchor that exist" do
    links =
      for file <- Path.wildcard("lib/**/*.ex"),
          [_, page, anchor] <- Regex.scan(~r{cbishopvelti\.github\.io/clawswap/([\w-]+\.html)(?:#([\w-]+))?}, File.read!(file), capture: :all),
          do: {file, page, anchor}

    assert links != []

    for {file, page, anchor} <- links do
      path = Path.join("docs", page)
      assert File.exists?(path), "#{file} links #{page}, which isn't in docs/"
      if anchor != "", do: assert(File.read!(path) =~ ~s(id="#{anchor}"), "#{file} links #{page}##{anchor}, which has no such id")
    end
  end
end

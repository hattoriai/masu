defmodule Masu.MessagesTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint MasuTest.Endpoint

  # The browser's words (DEFAULT_MESSAGES in messages.ts), as Masu.Messages
  # lists them: an app that translates every key of defaults/0 leaves
  # no word in English.
  test "defaults/0 has every word of the browser, the same" do
    source = File.read!(Path.expand("../../assets/src/messages.ts", __DIR__))

    [table] =
      Regex.run(~r/export const DEFAULT_MESSAGES: Record<string, string> = \{(.*?)\n\};/s, source,
        capture: :all_but_first
      )

    browser =
      ~r/^\s*([a-z_0-9]+):\s*"((?:[^"\\]|\\.)*)",?$/m
      |> Regex.scan(table, capture: :all_but_first)
      |> Map.new(fn [key, text] -> {key, text} end)

    assert map_size(browser) > 100
    assert Map.take(Masu.Messages.defaults(), Map.keys(browser)) == browser
  end

  test "a grid's words go apart from its config, so that they are sent once" do
    {:ok, _view, html} = live(build_conn(), "/theme")
    grid = html |> LazyHTML.from_fragment() |> LazyHTML.query("#normal")

    [config] = LazyHTML.attribute(grid, "data-masu")
    [messages] = LazyHTML.attribute(grid, "data-masu-messages")

    refute Map.has_key?(JSON.decode!(config), "messages")
    assert JSON.decode!(messages)["search"] == "Search"
  end
end

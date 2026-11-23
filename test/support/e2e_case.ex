defmodule MasuE2E.Case do
  @moduledoc """
  The browser tests (test/e2e), with playwright_ex: `mix test --only e2e`.

  Each module is `parameterize:`d over `projects/0`, one project for each
  engine, named after it, with its desktop device, which picks the browser. E2E_BROWSERS
  picks some of them (comma-separated, for example "firefox" or
  "chromium,webkit"); the default is all three. A module of tests only
  Chromium can run is `parameterize:`d over `chromium_projects/0`.
  `Playwright.Case` gives each test a `context` and `page`, and the
  `browser_name`.
  """

  use ExUnit.CaseTemplate

  @devices %{chromium: "Desktop Chrome", firefox: "Desktop Firefox", webkit: "Desktop Safari"}

  @doc "The projects of the run, as `parameterize:` takes them."
  def projects, do: for({_name, project} <- picked(), do: project)

  @doc "The Chromium project of the run, if E2E_BROWSERS picks it, for the Chromium-only tests."
  def chromium_projects, do: for({:chromium, project} <- picked(), do: project)

  defp picked do
    "E2E_BROWSERS"
    |> System.get_env("chromium,firefox,webkit")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn name ->
      if name not in ~w(chromium firefox webkit) do
        raise ~s(E2E_BROWSERS: unknown browser "#{name}", use chromium, firefox or webkit)
      end

      browser = String.to_atom(name)
      {browser, Playwright.Test.parameters([name: name] ++ Playwright.device(@devices[browser]))}
    end)
  end

  using opts do
    quote do
      use Playwright.Case, unquote(opts)

      import MasuE2E.Support

      @moduletag :e2e
    end
  end
end

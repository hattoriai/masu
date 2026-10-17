defmodule Mix.Tasks.Masu.ReleaseCheck do
  @shortdoc "Checks that priv/static holds the four bundle files and nothing else"

  @moduledoc """
  Checks the built files before a release of Masu.

      $ mix masu.release_check

  This task is for work on Masu itself; the `release` alias runs it
  after `mix masu.build` and before `mix hex.publish`. In any project
  but Masu, it stops with an error. It fails when:

    * one of the four bundle files (`masu.esm.js`, `masu.cjs.js`,
      `masu.css` and `masu-sumi.css`) is missing from `priv/static`,
      or is empty (the empty files that CI makes are not a build);
    * `priv/static` holds any other file or directory;
    * the `version` of `package.json` is not the version of `mix.exs`.
  """

  use Mix.Task

  @static "priv/static"
  @files ~w(masu.esm.js masu.cjs.js masu.css masu-sumi.css)

  @impl Mix.Task
  def run(_args) do
    config = Mix.Project.config()
    ensure_masu!(config)
    version = config[:version]

    case check(@static, "package.json", version) do
      :ok ->
        Mix.shell().info(
          "#{@static} holds the four bundle files, and nothing else, and package.json has version #{version}"
        )

      {:error, problems} ->
        Mix.raise("""
        Masu is not ready for a release:

        #{Enum.map_join(problems, "\n", &("  * " <> &1))}

        Build with `mix masu.build` (it empties #{@static} first); keep the \
        version of package.json equal to the version of mix.exs.\
        """)
    end
  end

  @doc false
  @spec ensure_masu!(keyword()) :: :ok
  def ensure_masu!(config) do
    if config[:app] == :masu do
      :ok
    else
      Mix.raise(
        "mix masu.release_check is for work on Masu itself; it checks the files of a Masu release"
      )
    end
  end

  @doc false
  @spec check(Path.t(), Path.t(), String.t()) :: :ok | {:error, [String.t()]}
  def check(static, package_json, version) do
    entries =
      case File.ls(static) do
        {:ok, entries} -> entries
        {:error, _reason} -> []
      end

    problems =
      Enum.flat_map(@files, &bundle_problems(static, &1, entries)) ++
        Enum.map(Enum.sort(entries -- @files), &"#{static}/#{&1} is not a bundle file") ++
        version_problems(package_json, version)

    if problems == [], do: :ok, else: {:error, problems}
  end

  defp bundle_problems(static, file, entries) do
    path = Path.join(static, file)

    cond do
      file not in entries -> ["#{path} is missing"]
      not File.regular?(path) -> ["#{path} is not a file"]
      File.stat!(path).size == 0 -> ["#{path} is empty"]
      true -> []
    end
  end

  defp version_problems(package_json, version) do
    with {:ok, source} <- File.read(package_json),
         {:ok, %{"version" => ^version}} <- JSON.decode(source) do
      []
    else
      _other -> ["the version of #{package_json} is not #{version}"]
    end
  end
end

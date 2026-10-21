# The server's benchmarks: `mix bench.server` (see bench/README.md).
#
# Masu.Source.List with 10,000 to 1,000,000 rows in the process, and
# Masu.Source.Ecto on PostgreSQL with 100,000 to 10,000,000 rows. Each
# job is what the grid does as a person uses it: the query prepared, a
# block of 100 rows read at the top and in the middle (by key, and by
# OFFSET after a jump), a sort, a search (the first, which makes the
# rows' search texts of a list, and the next), the count, and the count
# up to a count_limit.
#
# The jumps of an Ecto source (the scrollbar dragged to a place the grid
# did not read) can take minutes in a large table. They are not Benchee
# jobs: each runs once to warm up, then a few times, under a statement
# timeout.
#
# The results go to bench/results/server.json, for bench/report.exs.
#
# Environment:
#
#   * MASU_BENCH_DATABASE_URL - the database of the Ecto jobs
#     (postgres://localhost/masu_bench). It is made if it is not there,
#     and its tables are made once, in a minute or two for the largest.
#   * MASU_BENCH_SIZES - "small" runs only the smallest size of each
#     source, to try the script.
#   * MASU_BENCH_TIME - the seconds of each job (2).
#   * MASU_BENCH_JUMP_TIMEOUT - the seconds after which PostgreSQL stops
#     a jump's query (30).

Logger.configure(level: :warning)

small? = System.get_env("MASU_BENCH_SIZES") == "small"
time = "MASU_BENCH_TIME" |> System.get_env("2") |> String.to_integer()
jump_timeout = "MASU_BENCH_JUMP_TIMEOUT" |> System.get_env("30") |> String.to_integer()
list_sizes = if small?, do: [10_000], else: [10_000, 100_000, 1_000_000]
ecto_sizes = if small?, do: [100_000], else: [100_000, 1_000_000, 10_000_000]
block = 100

url = System.get_env("MASU_BENCH_DATABASE_URL", "postgres://localhost/masu_bench")

Application.put_env(:masu, MasuBench.Repo,
  url: url,
  pool_size: 2,
  log: false,
  timeout: :infinity
)

defmodule MasuBench.Repo do
  use Ecto.Repo, otp_app: :masu, adapter: Ecto.Adapters.Postgres
end

defmodule MasuBench.Customer do
  @moduledoc "A customer, as the development server's: in a table of each size."
  use Ecto.Schema

  schema "customers" do
    field :name, :string
    field :email, :string
    field :city, :string
    field :plan, :string
    field :seats, :integer
    field :revenue, :decimal
    field :active, :boolean
    field :signed_up, :date
    field :last_seen, :utc_datetime
  end
end

defmodule MasuBench.Data do
  @moduledoc "The rows of the benchmarks: the same customers as the development server's."

  @first ~w(Ada Alan Grace Edsger Barbara Donald Margaret Ken Radia Frances John Hedy Tim Linus Katherine Dennis Anita Guido José Yukihiro)
  @last ~w(Lovelace Turing Hopper Dijkstra Liskov Knuth Hamilton Thompson Perlman Allen Backus Lamarr Berners-Lee Torvalds Johnson Ritchie Borg Rossum Valim Matsumoto)
  @cities [
    "Lisbon",
    "Porto",
    "London",
    "Tokyo",
    "Kraków",
    "São Paulo",
    "Austin",
    "Berlin",
    "Nairobi",
    "Oslo"
  ]
  @plans ~w(free starter team business enterprise)

  def list(n), do: Enum.map(1..n, &customer/1)

  defp customer(id) do
    first = pick(@first, id * 7)
    last = pick(@last, id * 13)

    %{
      id: id,
      name: "#{first} #{last}",
      email: "#{String.downcase(first)}.#{String.downcase(last)}#{id}@example.com",
      city: if(rem(id, 17) == 0, do: nil, else: pick(@cities, id * 3)),
      plan: pick(@plans, id * 11),
      seats: rem(id * 37, 250) + 1,
      revenue: Decimal.new(rem(id * 7919, 1_000_000)) |> Decimal.div(100) |> Decimal.round(2),
      active: rem(id, 5) != 0,
      signed_up: Date.add(~D[2020-01-01], rem(id * 31, 2000)),
      last_seen: DateTime.add(~U[2026-01-01 00:00:00Z], rem(id * 104_729, 25_000_000), :second)
    }
  end

  defp pick(list, n), do: Enum.at(list, rem(n, length(list)))

  defp sql_array(list), do: "ARRAY[" <> Enum.map_join(list, ",", &"'#{&1}'") <> "]"

  @doc "The table of n customers, made once: customers_<n>."
  def table!(repo, n) do
    table = "customers_#{n}"

    made? =
      match?(
        %{rows: [[^n]]},
        repo.query("SELECT count(*) FROM #{table}", [], log: false)
        |> then(fn
          {:ok, result} -> result
          {:error, _} -> nil
        end)
      )

    unless made? do
      IO.puts("Making #{table} (#{n} rows)…")
      repo.query!("DROP TABLE IF EXISTS #{table}")

      repo.query!("""
      CREATE TABLE #{table} (
        id bigint PRIMARY KEY, name text, email text, city text, plan text,
        seats integer, revenue numeric(12, 2), active boolean, signed_up date,
        last_seen timestamp(0)
      )
      """)

      # The same values as list/1, made by the database.
      repo.query!(
        """
        INSERT INTO #{table}
        SELECT g,
          f || ' ' || l,
          lower(f) || '.' || lower(l) || g || '@example.com',
          CASE WHEN g % 17 = 0 THEN NULL ELSE (#{sql_array(@cities)})[1 + (g * 3) % 10] END,
          (#{sql_array(@plans)})[1 + (g * 11) % 5],
          (g * 37) % 250 + 1,
          ((g * 7919) % 1000000) / 100.0,
          g % 5 <> 0,
          date '2020-01-01' + ((g * 31) % 2000)::int,
          timestamp '2026-01-01' + ((g * 104729) % 25000000) * interval '1 second'
        FROM generate_series(1, $1::bigint) g,
          LATERAL (SELECT (#{sql_array(@first)})[1 + (g * 7) % 20] AS f,
                          (#{sql_array(@last)})[1 + (g * 13) % 20] AS l) names
        """,
        [n]
      )

      # The index that a sort on a column needs to be read by key: the
      # column, then the primary key, as Masu orders.
      repo.query!("CREATE INDEX ON #{table} (signed_up, id)")
      repo.query!("VACUUM ANALYZE #{table}")
    end

    table
  end
end

defmodule MasuBench.Run do
  @moduledoc "Runs the jobs of a group with Benchee, and keeps their statistics."

  def run(group, size, jobs, time) do
    IO.puts("\n== #{group}, #{size} rows")

    suite =
      Benchee.run(jobs,
        time: time,
        warmup: 0.5,
        memory_time: 0.5,
        print: [configuration: false, benchmarking: false],
        formatters: [{Benchee.Formatters.Console, extended_statistics: false}]
      )

    for scenario <- suite.scenarios do
      run = scenario.run_time_data.statistics
      memory = scenario.memory_usage_data.statistics

      %{
        group: group,
        size: size,
        job: scenario.name,
        median_us: run.median / 1000,
        p99_us: run.percentiles[99] / 1000,
        ips: run.ips,
        memory_bytes: memory.median
      }
    end
  end
end

defmodule MasuBench.Slow do
  @moduledoc """
  Runs jobs that can take minutes: each once to warm up, then up to five
  times or for ten seconds, in a transaction with a statement timeout.
  A job that PostgreSQL stops has no time, only its timeout.
  """

  @runs 5
  @budget_us 10_000_000

  def run(group, size, jobs, timeout) do
    IO.puts("\n== #{group}, #{size} rows")

    for {name, job} <- Enum.sort(jobs) do
      result =
        with {:ok, _warm} <- timed(job, timeout) do
          times(job, timeout, [], 0)
        end

      line =
        case result do
          {:ok, times} -> "#{Float.round(median(times) / 1000, 2)} ms (#{length(times)} runs)"
          :timeout -> "> #{timeout} s"
        end

      IO.puts("#{name}: #{line}")

      case result do
        {:ok, times} ->
          %{group: group, size: size, job: name, median_us: median(times), runs: length(times)}

        :timeout ->
          %{group: group, size: size, job: name, timeout_s: timeout}
      end
    end
  end

  defp times(_job, _timeout, times, spent) when length(times) == @runs or spent > @budget_us,
    do: {:ok, times}

  defp times(job, timeout, times, spent) do
    case timed(job, timeout) do
      {:ok, us} -> times(job, timeout, [us | times], spent + us)
      :timeout -> :timeout
    end
  end

  defp timed(job, timeout) do
    {:ok, us} =
      MasuBench.Repo.transaction(fn ->
        MasuBench.Repo.query!("SET LOCAL statement_timeout = '#{timeout}s'")
        {us, _rows} = :timer.tc(job)
        us
      end)

    {:ok, us}
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] == :query_canceled,
        do: :timeout,
        else: reraise(error, __STACKTRACE__)
  end

  defp median(times) do
    sorted = Enum.sort(times)
    Enum.at(sorted, div(length(sorted), 2))
  end
end

alias Masu.{Column, Query}
alias Masu.Source

columns = [
  Column.new(field: :id, type: :integer),
  Column.new(field: :name, type: :text),
  Column.new(field: :email, type: :text),
  Column.new(field: :city, type: :text),
  Column.new(field: :plan, type: :enum),
  Column.new(field: :seats, type: :integer),
  Column.new(field: :revenue, type: :decimal),
  Column.new(field: :active, type: :boolean),
  Column.new(field: :signed_up, type: :date),
  Column.new(field: :last_seen, type: :datetime)
]

query = fn opts ->
  {:ok, query} = Query.new(opts, columns)
  query
end

plain = query.([])
by_date = query.(sort: [{"signed_up", :desc}])
by_name = query.(sort: ["name"])
search = query.(search: "lovelace")
other_search = query.(search: "turing")
# A search that finds no row: every row is read to count it.
rare = query.(search: "zzz")

# --- Masu.Source.List: the rows in the LiveView's process.

list_results =
  for n <- list_sizes do
    rows = MasuBench.Data.list(n)
    state = rows |> Source.List.init([]) |> Source.List.prepare(plain, columns)
    # A state that searched once: it has the rows' search texts.
    searched = Source.List.prepare(state, search, columns)
    middle = div(n, 2)

    results =
      MasuBench.Run.run(
        "Source.List",
        n,
        %{
          "mount (init and prepare)" => fn ->
            rows |> Source.List.init([]) |> Source.List.prepare(plain, columns)
          end,
          "sort by name" => fn -> Source.List.prepare(state, by_name, columns) end,
          "search, the first" => fn -> Source.List.prepare(state, search, columns) end,
          "search, the next" => fn -> Source.List.prepare(searched, other_search, columns) end,
          "block in the middle" => fn -> Source.List.rows(state, middle, block) end
        },
        time
      )

    heap = %{
      group: "Source.List",
      size: n,
      job: "rows in the process (bytes)",
      memory_bytes: :erts_debug.flat_size(rows) * :erlang.system_info(:wordsize)
    }

    [heap | results]
  end

# --- Masu.Source.Ecto: PostgreSQL.

{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Application.ensure_all_started(:ecto_sql)

case Ecto.Adapters.Postgres.storage_up(MasuBench.Repo.config()) do
  :ok -> :ok
  {:error, :already_up} -> :ok
  {:error, reason} -> raise "MASU_BENCH_DATABASE_URL (#{url}): #{inspect(reason)}"
end

{:ok, _} = MasuBench.Repo.start_link()

%{rows: [[postgres]]} = MasuBench.Repo.query!("SHOW server_version")

ecto_results =
  for n <- ecto_sizes do
    import Ecto.Query

    table = MasuBench.Data.table!(MasuBench.Repo, n)
    source = from(c in {table, MasuBench.Customer})
    init = Source.Ecto.init(source, repo: MasuBench.Repo)
    capped = Source.Ecto.init(source, repo: MasuBench.Repo, count_limit: 10_000)
    middle = div(n, 2)

    # A state that read the row before a place, so that the block there
    # is read by key; a state that did not reads it by OFFSET (the
    # scrollbar dragged there). The row's sort values come from the index
    # alone: its whole row by OFFSET reads half the table.
    keyed = fn state, at ->
      fields = Enum.map(state.order, fn {_direction, field} -> field end)

      row =
        from(c in source,
          select: map(c, ^fields),
          order_by: ^state.order,
          offset: ^(at - 1),
          limit: 1
        )
        |> MasuBench.Repo.one!()

      Source.Ecto.seen(state, at - 1, [row])
    end

    by_id = Source.Ecto.prepare(init, plain, columns)
    by_date_state = Source.Ecto.prepare(init, by_date, columns)
    by_id_keyed = keyed.(by_id, middle)
    by_date_keyed = keyed.(by_date_state, middle)
    searched = Source.Ecto.prepare(init, search, columns)

    jobs = %{
      "first block" => fn -> Source.Ecto.rows(by_id, 0, block) end,
      "middle block, by key" => fn -> Source.Ecto.rows(by_id_keyed, middle, block) end,
      "sorted by date, middle block, by key" => fn ->
        Source.Ecto.rows(by_date_keyed, middle, block)
      end,
      "search, first block" => fn -> Source.Ecto.rows(searched, 0, block) end,
      "count" => fn -> Source.Ecto.count(by_id) end,
      "search, count" => fn -> Source.Ecto.count(searched) end,
      "count, count_limit of 10,000" => fn ->
        capped |> Source.Ecto.prepare(plain, columns) |> Source.Ecto.count()
      end,
      "search, count, count_limit of 10,000" => fn ->
        capped |> Source.Ecto.prepare(search, columns) |> Source.Ecto.count()
      end,
      "search of no row, count" => fn ->
        init |> Source.Ecto.prepare(rare, columns) |> Source.Ecto.count()
      end,
      "search of no row, count, count_limit of 10,000" => fn ->
        capped |> Source.Ecto.prepare(rare, columns) |> Source.Ecto.count()
      end
    }

    benchee = MasuBench.Run.run("Source.Ecto", n, jobs, time)

    # The jumps: to a place the grid did not read, with no block read
    # before (a first jump), and a short and a long jump from the block
    # in the middle that the grid read (the scrollbar dragged on).
    places = [{"a tenth", div(n, 10)}, {"the middle", middle}, {"nine tenths", div(n * 9, 10)}]
    orders = [{"", by_id, by_id_keyed}, {"sorted by date, ", by_date_state, by_date_keyed}]

    jumps =
      for {prefix, state, from_middle} <- orders,
          {name, from, at} <-
            Enum.map(places, fn {place, at} -> {"first jump to #{place}", state, at} end) ++
              [
                {"jump of 1,000 rows on from the middle", from_middle, middle + 1_000},
                {"jump of a tenth of the rows on from the middle", from_middle,
                 middle + div(n, 10)}
              ],
          into: %{},
          do: {prefix <> name, fn -> Source.Ecto.rows(from, at, block) end}

    benchee ++ MasuBench.Slow.run("Source.Ecto, jumps", n, jumps, jump_timeout)
  end

{commit, 0} = System.cmd("git", ["rev-parse", "--short", "HEAD"])
{dirty, 0} = System.cmd("git", ["status", "--porcelain", "--", "lib", "assets/src"])

cpu =
  case System.cmd("sysctl", ["-n", "machdep.cpu.brand_string"], stderr_to_stdout: true) do
    {cpu, 0} -> String.trim(cpu)
    _ -> to_string(:erlang.system_info(:system_architecture))
  end

report = %{
  environment: %{
    commit: String.trim(commit) <> if(dirty == "", do: "", else: " (with changes)"),
    date: Date.utc_today(),
    cpu: cpu,
    schedulers: System.schedulers_online(),
    elixir: System.version(),
    otp: System.otp_release(),
    postgres: postgres
  },
  results: List.flatten(list_results ++ ecto_results)
}

File.mkdir_p!("bench/results")
File.write!("bench/results/server.json", JSON.encode!(report))
IO.puts("\nWrote bench/results/server.json")

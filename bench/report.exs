# The report of the benchmarks: `mix bench.report` reads
# bench/results/server.json and bench/results/browser/*.json, and writes
# bench/RESULTS.md.

defmodule MasuBench.Report do
  @moduledoc false

  def ms(nil), do: "–"
  def ms(us) when us < 10, do: "#{Float.round(us * 1.0, 1)} µs"
  def ms(us) when us < 1000, do: "#{Float.round(us / 1000, 2)} ms"
  def ms(us), do: "#{round(us / 1000)} ms"

  def mb(nil), do: "–"
  def mb(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1_048_576, 2)} MB"
  def mb(bytes), do: "#{round(bytes / 1_048_576)} MB"

  def int(nil), do: "–"
  def int(n), do: n |> round() |> Integer.to_string() |> group()

  defp group(digits) do
    digits
    |> String.reverse()
    |> String.to_charlist()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  def table(header, rows) do
    lines = [header, Enum.map(header, fn _ -> "---" end) | rows]
    Enum.map_join(lines, "\n", &("| " <> Enum.join(&1, " | ") <> " |"))
  end

  # A table of jobs by size: a row for each job, a column for each size.
  def jobs(results, group, value) do
    results = Enum.filter(results, &(&1["group"] == group))
    sizes = results |> Enum.map(& &1["size"]) |> Enum.uniq() |> Enum.sort()
    jobs = results |> Enum.map(& &1["job"]) |> Enum.uniq()

    rows =
      for job <- jobs do
        cells =
          for size <- sizes do
            case Enum.find(results, &(&1["job"] == job and &1["size"] == size)) do
              nil -> "–"
              result -> value.(result)
            end
          end

        [job | cells]
      end

    table(["" | Enum.map(sizes, &"#{int(&1)} rows")], rows)
  end
end

alias MasuBench.Report

server = "bench/results/server.json" |> File.read!() |> JSON.decode!()
env = server["environment"]
results = server["results"]

browser =
  "bench/results/browser/*.json"
  |> Path.wildcard()
  |> Enum.map(&(&1 |> File.read!() |> JSON.decode!()))

timing = fn
  %{"timeout_s" => timeout} -> "> #{timeout} s (stopped)"
  %{"median_us" => median} -> Report.ms(median)
  %{"memory_bytes" => bytes} -> Report.mb(bytes)
end

runs =
  browser
  |> Enum.filter(&Map.has_key?(&1, "firstRowsMs"))
  |> Enum.sort_by(&{&1["kind"], &1["rows"]})

shown = fn
  nil -> "none"
  id -> Report.int(id)
end

runs_table =
  Report.table(
    [
      "Grid",
      "Rows",
      "First rows",
      "Server memory",
      "JS heap",
      "DOM nodes",
      "Frame p50 / p95",
      "Frames > 33 ms",
      "Long tasks",
      "After the scroll: first row, then 1 s later",
      "Jump to the middle"
    ],
    for run <- runs do
      frames = run["frames"]

      [
        Map.fetch!(
          %{
            "masu" => "Masu",
            "stream" => "LiveView, a stream of every row",
            "viewport" => "LiveView, infinite scroll"
          },
          run["kind"]
        ),
        Report.int(run["rows"]),
        "#{Report.int(run["firstRowsMs"])} ms (#{Report.int(run["loadMs"])} ms the rows' copy)",
        Report.mb(run["serverBytes"]),
        Report.mb(run["heapBytes"]),
        Report.int(run["domNodes"]),
        "#{Float.round(frames["p50"] * 1.0, 1)} / #{Float.round(frames["p95"] * 1.0, 1)} ms",
        "#{frames["over33ms"]} of #{frames["count"]}",
        "#{run["longTasks"]["count"]} (max #{round(run["longTasks"]["max"])} ms)",
        "#{shown.(run["reachedId"])}, then #{shown.(run["reachedIdAfter1s"])}",
        if(run["jumpToMiddleMs"], do: "#{round(run["jumpToMiddleMs"])} ms", else: "–")
      ]
    end
  )

lasts = Enum.filter(browser, &Map.has_key?(&1, "expectedLastRowIndex"))
browsers = ["chromium", "firefox", "webkit"]
versions = Map.new(browser, &{&1["browser"], &1["version"]})

last_table =
  Report.table(
    ["Rows" | browsers],
    for rows <- lasts |> Enum.map(& &1["rows"]) |> Enum.uniq() |> Enum.sort() do
      cells =
        for name <- browsers do
          case Enum.find(lasts, &(&1["rows"] == rows and &1["browser"] == name)) do
            nil ->
              "–"

            %{"lastRowIndex" => last, "expectedLastRowIndex" => last} ->
              "yes"

            %{"lastRowIndex" => last} ->
              "**no**: row #{Report.int((last || 1) - 1)} is the last row on the screen"
          end
        end

      [Report.int(rows) | cells]
    end
  )

markdown = """
# Benchmark results

Made by `mix bench` (see [README.md](README.md)) on #{env["date"]}, commit
#{env["commit"]}. #{env["cpu"]}, #{env["schedulers"]} schedulers, Elixir
#{env["elixir"]}, OTP #{env["otp"]}, PostgreSQL #{env["postgres"]}.
#{Enum.map_join(browsers, ", ", &"#{&1} #{versions[&1] || "–"}")}.

The numbers are of one machine. Compare the numbers of one run with
each other, not with the numbers of another machine.

## Server: `Masu.Source.List`

The rows are in the LiveView's process. The median time of each job,
and the memory of the rows.

#{Report.jobs(results, "Source.List", timing)}

## Server: `Masu.Source.Ecto` on PostgreSQL

The median time of each job. A block is 100 rows. "By key" is the
block after a block that the grid read, as when the person scrolls.
The table has an index on `(signed_up, id)`.

#{Report.jobs(results, "Source.Ecto", timing)}

## Server: jumps of `Masu.Source.Ecto` on PostgreSQL

A jump is a block of 100 rows at a place that the grid did not read, as
when the person drags the scrollbar. A first jump has no block read
before it. A jump "on from the middle" comes after the grid read the
block in the middle. The median time of up to five runs (after one run
to warm up) in ten seconds. PostgreSQL stops a query after a timeout.

#{Report.jobs(results, "Source.Ecto, jumps", timing)}

## Browser: a Masu grid and two LiveView baselines

Chromium, headless. The baselines have the same rows: a stream of every
row, and the infinite scroll of the LiveView docs (a stream of three
pages of 50 rows at most, the next page at `phx-viewport-bottom`).

"First rows" is the time from the navigation to the first rows on the
screen, with the copy of the rows into the LiveView's process (as a
read from a database). "Server memory" is the memory of the LiveView's process.
"Frame p50 / p95" are the times of the frames of a fast scroll (2,000
pixels a frame, 300 frames). "After the scroll" is the ID of the first
real row on the screen when the scroll stops, and a second later
("none": the screen shows no rows, or only rows that load). "Jump to the middle" is the time until the
rows on the screen are real rows, after the scrollbar moves to the
middle.

#{runs_table}

## Browser: the last row of a large grid

The grid scrolls to its end, and shows its last row, or not.

#{last_table}
"""

File.write!("bench/RESULTS.md", markdown)
IO.puts("Wrote bench/RESULTS.md")

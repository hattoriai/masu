# Benchmarks

The benchmarks of Masu, on the server and in the browser. The results of
the last run are in [RESULTS.md](RESULTS.md).

## Run them

You need PostgreSQL, and the browsers of the browser tests (see the
main README). Then:

```sh
mix bench           # all of them, then bench/RESULTS.md
mix bench.server    # only the server's: bench/results/server.json
mix bench.browser   # only the browser's: bench/results/browser/
mix bench.report    # bench/RESULTS.md from the results
```

The first `mix bench.server` makes the tables of the Ecto jobs in the
database `masu_bench` (`MASU_BENCH_DATABASE_URL` for another), which
takes a few minutes for ten million rows. `MASU_BENCH_SIZES=small` runs
only the smallest size, to try a change. A full run takes approximately
fifteen minutes.

Close other applications first: the numbers change with the load on the
machine.

## What they measure

**The server** (`server.exs`, with Benchee):

* `Masu.Source.List` with 10,000, 100,000 and 1,000,000 rows: the mount,
  a sort, a search, a block of 100 rows; the memory of the rows.
* `Masu.Source.Ecto` on PostgreSQL with 100,000, 1,000,000 and
  10,000,000 rows: the first block, a block in the middle by key and by
  `OFFSET`, the same in the order of a column with an index, a search,
  the count.

**The browser** (`e2e/bench/grid.bench.ts`, with Playwright, against
the `/bench` page of the development server):

* A Masu grid of 1,000 to 1,000,000 rows, and two baselines of the same
  rows without a grid: a plain LiveView stream table of every row (1,000
  to 100,000), and the infinite scroll of the LiveView docs (1,000 to
  1,000,000). The time to the first rows, the memory of the LiveView's
  process, the JS heap, the DOM nodes, the frames of a fast scroll, the
  rows on the screen after it, the time to fill the screen after a
  jump. In Chromium, with the Chrome DevTools Protocol.
* The last row of each Masu grid, in Chromium, Firefox and WebKit:
  a browser has a largest height of an element, and a grid taller than
  that does not show its last rows.

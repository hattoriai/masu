# Benchmark results

Made by `mix bench` (see [README.md](README.md)) on 2026-10-19, commit
355da19 (with changes). Apple M1 Pro, 10 schedulers, Elixir
1.20.1, OTP 29, PostgreSQL 16.14 (Homebrew).
chromium 141.0.7390.37, firefox 142.0.1, webkit 26.0.

The numbers are of one machine. Compare the numbers of one run with
each other, not with the numbers of another machine.

## Server: `Masu.Source.List`

The rows are in the LiveView's process. The median time of each job,
and the memory of the rows.

|  | 10,000 rows | 100,000 rows | 1,000,000 rows |
| --- | --- | --- | --- |
| rows in the process (bytes) | 9 MB | 86 MB | 863 MB |
| block in the middle | 0.7 µs | 0.7 µs | 0.7 µs |
| mount (init and prepare) | 0.04 ms | 0.44 ms | 245 ms |
| search, the next | 3 ms | 27 ms | 274 ms |
| sort by name | 23 ms | 396 ms | 5161 ms |
| search, the first | 36 ms | 355 ms | 5028 ms |

## Server: `Masu.Source.Ecto` on PostgreSQL

The median time of each job. A block is 100 rows. "By key" is the
block after a block that the grid read, as when the person scrolls;
"by OFFSET" is the block after a jump, as when the person drags the
scrollbar. The table has an index on `(signed_up, id)`. The `OFFSET`
jobs do not run at ten million rows: one takes minutes, as it reads
millions of rows from the disk.

|  | 100,000 rows | 1,000,000 rows | 10,000,000 rows |
| --- | --- | --- | --- |
| first block | 0.22 ms | 0.22 ms | 0.22 ms |
| middle block, by key | 0.24 ms | 0.25 ms | 0.24 ms |
| sorted by date, middle block, by key | 0.26 ms | 0.34 ms | 3 ms |
| count, count_limit of 10,000 | 0.45 ms | 0.51 ms | 0.8 ms |
| search, first block | 3 ms | 5 ms | 5 ms |
| count | 3 ms | 22 ms | 2463 ms |
| middle block, by OFFSET | 4 ms | 28 ms | – |
| sorted by date, middle block, by OFFSET | 8 ms | 159 ms | – |
| search of no row, count | 20 ms | 125 ms | 1289 ms |
| search, count | 21 ms | 128 ms | 1293 ms |
| search of no row, count, count_limit of 10,000 | 47 ms | 346 ms | 3641 ms |
| search, count, count_limit of 10,000 | 54 ms | 42 ms | 45 ms |

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

| Grid | Rows | First rows | Server memory | JS heap | DOM nodes | Frame p50 / p95 | Frames > 33 ms | Long tasks | After the scroll: first row, then 1 s later | Jump to the middle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Masu | 1,000 | 268 ms (4 ms the rows' copy) | 2 MB | 3 MB | 374 | 16.7 / 17.6 ms | 0 of 300 | 0 (max 0 ms) | 985, then 985 | 82 ms |
| Masu | 100,000 | 901 ms (363 ms the rows' copy) | 98 MB | 3 MB | 374 | 16.6 / 17.5 ms | 0 of 300 | 0 (max 0 ms) | none, then 16,666 | 72 ms |
| Masu | 500,000 | 2,936 ms (2,194 ms the rows' copy) | 505 MB | 3 MB | 374 | 16.7 / 17.3 ms | 0 of 300 | 0 (max 0 ms) | none, then 30,000 | 66 ms |
| Masu | 1,000,000 | 7,011 ms (6,118 ms the rows' copy) | 1048 MB | 3 MB | 374 | 16.7 / 16.8 ms | 0 of 300 | 0 (max 0 ms) | none, then 60,002 | 68 ms |
| LiveView, a stream of every row | 1,000 | 222 ms (3 ms the rows' copy) | 0.01 MB | 3 MB | 11,054 | 16.7 / 17.4 ms | 0 of 300 | 0 (max 0 ms) | 974, then 974 | – |
| LiveView, a stream of every row | 10,000 | 1,349 ms (32 ms the rows' copy) | 0.01 MB | 14 MB | 110,054 | 16.7 / 17.6 ms | 0 of 300 | 0 (max 0 ms) | 9,974, then 9,974 | – |
| LiveView, a stream of every row | 100,000 | 26,160 ms (329 ms the rows' copy) | 0.01 MB | 91 MB | 1,100,054 | 45.8 / 76.0 ms | 300 of 300 | 74 (max 199 ms) | 27,272, then 27,272 | – |
| LiveView, infinite scroll | 1,000 | 141 ms (3 ms the rows' copy) | 2 MB | 2 MB | 591 | 16.7 / 17.1 ms | 0 of 300 | 0 (max 0 ms) | none, then none | – |
| LiveView, infinite scroll | 100,000 | 396 ms (344 ms the rows' copy) | 98 MB | 2 MB | 591 | 16.7 / 16.9 ms | 0 of 300 | 0 (max 0 ms) | none, then none | – |
| LiveView, infinite scroll | 1,000,000 | 4,973 ms (4,890 ms the rows' copy) | 1048 MB | 2 MB | 591 | 16.7 / 17.5 ms | 0 of 300 | 0 (max 0 ms) | none, then none | – |

## Browser: the last row of a large grid

The grid scrolls to its end, and shows its last row, or not.

| Rows | chromium | firefox | webkit |
| --- | --- | --- | --- |
| 1,000 | yes | yes | yes |
| 100,000 | yes | yes | yes |
| 500,000 | yes | yes | yes |
| 1,000,000 | yes | yes | yes |

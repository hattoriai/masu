# Benchmark results

Made by `mix bench` (see [README.md](README.md)) on 2026-10-19, commit
96d721c. Apple M1 Pro, 10 schedulers, Elixir
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
| mount (init and prepare) | 0.04 ms | 0.44 ms | 271 ms |
| sort by name | 21 ms | 378 ms | 5244 ms |
| search | 36 ms | 491 ms | 4967 ms |

## Server: `Masu.Source.Ecto` on PostgreSQL

The median time of each job. A block is 100 rows. "By key" is the
block after a block that the grid read, as when the person scrolls;
"by OFFSET" is the block after a jump, as when the person drags the
scrollbar. The table has an index on `(signed_up, id)`. The `OFFSET`
jobs do not run at ten million rows: one takes minutes, as it reads
millions of rows from the disk.

|  | 100,000 rows | 1,000,000 rows | 10,000,000 rows |
| --- | --- | --- | --- |
| middle block, by key | 0.25 ms | 0.25 ms | 0.24 ms |
| first block | 0.27 ms | 0.23 ms | 0.22 ms |
| sorted by date, middle block, by key | 0.29 ms | 0.35 ms | 4 ms |
| search, first block | 2 ms | 5 ms | 5 ms |
| count | 3 ms | 26 ms | 2402 ms |
| middle block, by OFFSET | 4 ms | 27 ms | – |
| sorted by date, middle block, by OFFSET | 9 ms | 156 ms | – |
| search, count | 22 ms | 132 ms | 3168 ms |

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
| Masu | 1,000 | 230 ms (3 ms the rows' copy) | 2 MB | 3 MB | 374 | 16.7 / 17.5 ms | 0 of 300 | 0 (max 0 ms) | 985, then 985 | 73 ms |
| Masu | 100,000 | 398 ms (327 ms the rows' copy) | 98 MB | 3 MB | 374 | 16.7 / 17.5 ms | 0 of 300 | 0 (max 0 ms) | none, then 16,666 | 84 ms |
| Masu | 500,000 | 1,910 ms (1,739 ms the rows' copy) | 505 MB | 3 MB | 374 | 16.7 / 17.5 ms | 0 of 300 | 0 (max 0 ms) | none, then 30,000 | 84 ms |
| Masu | 1,000,000 | 5,975 ms (5,766 ms the rows' copy) | 1048 MB | 3 MB | 374 | 16.6 / 17.4 ms | 0 of 300 | 0 (max 0 ms) | none, then 60,002 | 70 ms |
| LiveView, a stream of every row | 1,000 | 171 ms (3 ms the rows' copy) | 0.01 MB | 3 MB | 11,054 | 16.7 / 17.5 ms | 0 of 300 | 0 (max 0 ms) | 974, then 974 | – |
| LiveView, a stream of every row | 10,000 | 1,284 ms (30 ms the rows' copy) | 0.01 MB | 14 MB | 110,054 | 16.6 / 17.5 ms | 0 of 300 | 0 (max 0 ms) | 9,974, then 9,974 | – |
| LiveView, a stream of every row | 100,000 | 23,296 ms (319 ms the rows' copy) | 0.01 MB | 84 MB | 1,100,054 | 47.5 / 81.5 ms | 300 of 300 | 88 (max 409 ms) | 27,272, then 27,272 | – |
| LiveView, infinite scroll | 1,000 | 74 ms (3 ms the rows' copy) | 2 MB | 2 MB | 591 | 16.7 / 17.3 ms | 0 of 300 | 0 (max 0 ms) | none, then none | – |
| LiveView, infinite scroll | 100,000 | 388 ms (324 ms the rows' copy) | 98 MB | 2 MB | 591 | 16.7 / 17.3 ms | 0 of 300 | 0 (max 0 ms) | none, then none | – |
| LiveView, infinite scroll | 1,000,000 | 4,930 ms (4,612 ms the rows' copy) | 1048 MB | 2 MB | 591 | 16.7 / 17.6 ms | 0 of 300 | 0 (max 0 ms) | none, then none | – |

## Browser: the last row of a large grid

The grid scrolls to its end, and shows its last row, or not.

| Rows | chromium | firefox | webkit |
| --- | --- | --- | --- |
| 1,000 | yes | yes | yes |
| 100,000 | yes | yes | yes |
| 500,000 | yes | yes | yes |
| 1,000,000 | yes | yes | yes |

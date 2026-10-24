# Contributing to Masu

Thank you for helping. This page says what to open (an issue, a pull
request, or a security report), what a pull request needs, and what the
maintainers keep for themselves. How to run the grid and its tests is in
the README, under [Development](README.md#development).

## Questions, bugs and ideas

- **A bug.** Open an issue with the bug report form. The smallest grid
  that shows it (the `<.data_grid>` and its source) is the most useful
  thing you can give.
- **An idea or a change of behaviour.** Open an issue with the feature
  request form, and say the problem before the solution.
- **A security problem.** Do not open an issue. See
  [SECURITY.md](SECURITY.md).

Search the open and closed issues first: the idea may already be planned,
or turned down for a reason given there.

## When a pull request needs an issue first

Open an issue, and agree on the change there, before a pull request that:

- adds a feature, an attribute, an option or a callback;
- changes what the grid, a source or a store does, or its public API;
- changes the wire protocol between the browser and the LiveView;
- adds a dependency;
- touches many files, or needs a design decision.

A pull request does not need an issue when it is small and its reason is
plain from the diff: a typo, a broken link, a wrong sentence in a guide,
or a bug fix with a test that fails without it. When in doubt, open the
issue: a short discussion costs less than a pull request that is not
merged.

A pull request with an issue says so: `Fixes #123` or `Closes #123`.

## A pull request

- **One change.** A fix, the guides for an unrelated case and a README
  edit are three pull requests. Each is reviewed, reverted and released
  on its own.
- **Why, not only what.** The description says the problem the change
  solves, for whom, and what happened before it: an error, a crash, a
  slow query. Say why a number was chosen when the change adds one.
- **Tests.** A bug fix has a test that fails on `main` and passes with
  the fix. A feature has tests of what it does, and of its errors.
- **Docs.** A change a user can see updates the guide it belongs to and
  the `[Unreleased]` section of [CHANGELOG.md](CHANGELOG.md).
- **The checks pass.** CI runs them; run them first:

  ```sh
  mix format --check-formatted
  mix compile --warnings-as-errors
  mix credo --strict
  mix test
  mix dialyzer
  mix docs
  ```

  `mix precommit` runs most of them at once. A change to `assets/` also
  runs `mix test.js`, and a change the browser sees `mix test.e2e`.

The pull request template has these as a checklist.

## What the maintainers keep

- **Benchmarks.** The numbers in `bench/RESULTS.md` and the README come
  from one machine, named at the top of `bench/RESULTS.md`, so that they
  compare with each other. Numbers from another machine do not. A pull
  request does not change them; if a change is about speed, put your own
  numbers in its description, with your machine. If you have an idea for
  benchmarks that hold across machines, open an issue.
- **Releases.** The version in `mix.exs`, the release headings of the
  changelog and the tags are changed by the maintainers, at a release.

## The browser's code

The grid's TypeScript is in `assets/src`, bundled into one file by esbuild
(`mix assets.build`):

- `grid.ts` is the grid's core: its rows, their drawing and scrolling, the
  query and the events. `hook.ts` is the LiveView hook that makes it.
- `features/` has a class for each of the grid's features, with its own
  state: editing, new rows, deleting, the menus and actions, history,
  filters, the toolbar, selection, details, the columns' layout, copy,
  the people of a room (`peers`), the keyboard, the pointer and opening
  a row (`activation`). The grid makes each (`this.editing`); a feature
  reaches the core through `this.grid`. A new feature is a class there, not more of `grid.ts`.
- The other modules are the parts without a grid: pure functions
  (`geometry`, `offsets`, `scroll`, `layout`, `sorting`, `filters`,
  `format`, `parse`, `tsv`), what draws an element (`header`, `toolbar`,
  `menu`, `panels`, `actions`), and the grid's records and words
  (`records`, `messages`, `config`). Their tests are in `assets/test`.

A part that runs for each row or each frame (drawing a row, scrolling)
stays in the core; a call to a feature costs a property more, which is
nothing for a key or a click, but adds up in a frame.

## Style

Match the code around your change: its naming, its comments and the way
its guides are written. `mix format` and `mix credo --strict` settle the
rest.

## License

By contributing, you agree that your contribution is released under the
MIT License of the project (see [LICENSE](LICENSE)).

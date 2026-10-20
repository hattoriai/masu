## Why

<!-- The problem this solves, for whom, and what happened before it (an error, a crash, a slow query). -->

Fixes #<!-- the issue; see CONTRIBUTING.md for when a pull request needs one -->

## What

<!-- The change, in a few lines. -->

## How it was tested

<!-- The tests added, and what you ran by hand. -->

## Checklist

- [ ] One change: anything unrelated is in its own pull request.
- [ ] A bug fix has a test that fails on `main` and passes here.
- [ ] `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test`, `mix dialyzer` and `mix docs` pass.
- [ ] `mix test.js` / `mix test.e2e` pass, for a change to `assets/` or to what the browser sees.
- [ ] The guides and the `[Unreleased]` section of `CHANGELOG.md` are updated, for a change a user can see.
- [ ] Says so here if it changes the public API or what the grid does today.
- [ ] No changes to `bench/RESULTS.md`, the README's benchmark numbers or the version (the maintainers keep those).

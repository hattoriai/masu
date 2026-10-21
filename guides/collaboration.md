# Collaboration

A grid that several people have open shows each of them the others, as a
shared spreadsheet does: who is here (their avatars above the grid),
where each of them is (a line in their color on their cell, with their
name), what each of them is typing in (a cell no one else may edit
meanwhile), and the rows they save, which flash in their color.

```heex
<.data_grid
  id="orders"
  source={Order}
  repo={Repo}
  changeset={&Order.changeset/2}
  live={{MyApp.PubSub, "orders"}}
  presence={MyAppWeb.Presence}
  user={%{id: @current_user.id, name: @current_user.name}}
>
```

## Setting up

1. A `Phoenix.Presence` module on the PubSub of `live` (`mix
   phx.gen.presence` makes one), started in your supervision tree after
   the PubSub:

   ```elixir
   defmodule MyAppWeb.Presence do
     use Phoenix.Presence, otp_app: :my_app, pubsub_server: MyApp.PubSub
   end
   ```

2. The `Masu.Live` hook in the LiveView (`on_mount Masu.Live`), and
   `live` on the grid: the people of a grid are those of its topic. See
   [Live rows](live.md).

3. `presence` and `user` on the grid. `user` is a map with an `id`, and a
   `name`, a `color` (a CSS color) and an `avatar` (an image's URL) if you
   have them. A person with no color gets one of a palette of eight, by
   their id, the same in every browser.

The people a person sees are the other users: someone with the grid
open in two tabs does not see themselves.

## Places, not positions

Each person has their own order, filters and search. A place is a row's
id and a column's key: a person sees another's line on that row wherever
it is in their own order, and no line when their filters leave the row
out (the avatar stays).

## Following someone

A click on a person's avatar follows them, as in a design tool, and shows
what they see: their order, filters and search, and their place in it
(the first row on their screen, and their cell). As they scroll, sort or
filter, the grid goes with them. Above the grid: "Following Ada", with
Stop; the grid has a ring in their color, their filter chips take it
too, and a screen reader hears "Showing Ada's view" with their filters.
Their avatar is `aria-pressed`.

Following never costs the person their place. Their own view (order,
filters, search, scroll position and selection) is kept aside:

* **Stop**, or a second click on the avatar, brings it back.
* **Scrolling, a click in the grid or a key** stops following but keeps
  Ada's view (they followed her to see it); the banner says "Ada's view",
  with "Back to your view".
* **A view of their own** (a sort, a filter or a search) is theirs from
  then on: there is nothing to go back to.

When the views already match, following only scrolls.

### Keeping a view to oneself

Someone's order, filters and search go to the others who have the grid
open, so that they can follow them: their search text included. A grid
with `share_view={false}` keeps them; whoever follows that person then
stays in their own view, and the grid scrolls to the person's cell where
the server finds it in that view (`c:Masu.Source.locate/3`), or says
"Ada is on a row your filters leave out".

## Selected ranges

The range a person selects shows to the others as a wash in their color,
on the rows of the range wherever each person's order puts them (the ids
of the range's rows go with their place, at most 500).

## Editing at the same time

A cell that someone is typing in shows "Ada is typing" to the others,
and opens no editor for them: "Ada is editing this cell". This is an
advisory lock, as a database's: it keeps two people from typing in one
cell, but it is not what keeps data safe. The server's compare-and-swap
is: an edit of a cell that changed since the person saw it is refused,
with presence or without (see [Editing](editing.md)), and the refusal
names who changed it: "Changed by Ada meanwhile." The grid knows from
its `live` topic, so the name shows with presence or without.

## The look

Every part can look the way your app does.

**The avatars** are HEEx, rendered by the server: give the grid a
`:person` slot, which gets each person as a map (`id`, `name`, `color`,
`avatar`, `initials`, `cell`, `range`, `editing`):

```heex
<:person :let={person}>
  <.avatar src={person.avatar} name={person.name} class="ring-2" style={"--tw-ring-color: #{person.color}"} />
</:person>
```

Without the slot, a person is their avatar, or their initials on their
color. The grid shows five, then "+3". Each is a `<button>` that follows
the person ("Follow Ada"), whatever the slot draws in it.

**The lines and labels** on the cells are drawn by the browser, as the
rows move. Each is a `.masu-peer` element with the person's color in
`--masu-peer-color`, and a `.masu-peer-label` with their name;
`.masu-peer-editing` while they type; a selected range is
`.masu-peer-range` elements. Following someone puts `data-following` on
the grid, their color in `--masu-follow-color`, and a `.masu-following`
banner (`data-kind` is `following`, `follow_hidden` or `their_view`) with
a `.masu-following-stop` button. Style them in CSS (see
[Theming](theming.md)), or draw the label yourself:

```js
import { Masu, configure } from "masu"

configure({
  peerLabel: (person) => (person.editing ? `✎ ${person.name}` : person.name),
})
```

`peerLabel` gives a text or an element; it gets the person as the
browser has them (`id`, `name`, `color`, `cell`, `range`, `editing`).

**The words** ("Ada is typing", "Ada is editing this cell", the name of
the avatars' group, "Follow Ada", "Following Ada", Stop, "Ada is on a
row your filters leave out", "Showing Ada's view", "Ada's view", "Back to
your view") are in the grid's `messages`: `peer_typing`, `peer_editing`,
`people`, `follow`, `following`, `stop_following`, `follow_hidden`,
`showing_view`, `their_view` and `back_to_view`.

## What travels

A person's place (their cell, range and first row on the screen) goes to the server when it changes, at most every 150
ms, and to the others through `Phoenix.Presence`, which also notices a
person who leaves or whose connection drops. A person's name, color and
avatar, and their view unless `share_view={false}`, go to everyone who
has the grid open: give `user` only what they may see.

## Agents

An agent reads and changes a grid as a person does, in an
[Issho](https://hex.pm/packages/issho) room: the people see where it is,
the cells it edits, and the rows it saves flash in its color. Its writes
go the grid's way (`Masu.Sheet`): the changeset, the read-only rules, the
compare of a cell changed meanwhile, the history and the `live` topic.
The rows, the scrolling and the queries stay the grid's own: Issho
carries only who is there and where.

Define the grid once, as `data_grid/1`'s attributes, and say which grid
an agent may use (see `Masu.Issho`):

    config :masu, Masu.Issho, grids: {MyApp.Grids, :for_agent}

then give the agent Masu's tools, with Issho's:

    tools = Issho.Tools.room() ++ Masu.Issho.tools()

`read_grid` reads rows in an order, filtered and searched;
`select_cells` points at a cell or a range; `edit_cells`, `add_rows`
and `delete_rows` write. An agent leaves a cell that someone is editing.

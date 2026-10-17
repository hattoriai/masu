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

A click on a person's avatar follows them, as in a design tool: the grid
keeps their cell in view as they move, in this person's own order (the
server finds the row's place in it, `c:Masu.Source.locate/3`), and says
so above the grid: "Following Ada", with Stop. The grid has a ring in
their color, and their avatar `aria-pressed`. Scrolling, a click in the
grid or a key stops following, as does a second click on the avatar.
When this person's filters leave the row out, the grid says so: "Ada is
on a row your filters leave out".

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
banner with a `.masu-following-stop` button. Style them in CSS (see
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
row your filters leave out") are in the grid's `messages`: `peer_typing`,
`peer_editing`, `people`, `follow`, `following`, `stop_following` and
`follow_hidden`.

## What travels

A person's place (their cell and range) goes to the server when it changes, at most every 150
ms, and to the others through `Phoenix.Presence`, which also notices a
person who leaves or whose connection drops. A person's name, color and
avatar go to everyone who has the grid open: give `user` only what they
may see.

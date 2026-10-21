# Collaboration

A grid that several people have open shows each of them the others, as a
shared spreadsheet does: who is here (their avatars above the grid),
where each of them is (a line in their color on their cell, with their
name), what each of them is typing in (a cell no one else may edit
meanwhile), and the rows they save, which flash in their color. Agents
are among them: an agent edits cells as a person does, and the people
see it on its cell (see [Agents](#agents)).

Collaboration runs on [Issho](https://hex.pm/packages/issho), collaboration
for Phoenix, as it does in Kotoba and Hakushi: Issho is the room's people,
where each is, the cells they hold, the policy, and the agents. The rows
stay the grid's: its source reads them, its writes save them, and `live`
shows the changes of the others as they land. A page with a grid, a text
and a canvas in one room has one list of people, one color for each
person, and agents that work across all three.

```heex
<.data_grid
  id="orders"
  source={Order}
  repo={Repo}
  changeset={&Order.changeset/2}
  live={{MyApp.PubSub, "orders"}}
  issho={[instance: MyApp.Issho, room: "orders"]}
  user={%{id: @current_user.id, name: @current_user.name}}
>
```

## Setting up

1. Add Issho to your dependencies (`{:issho, "~> 0.2"}`) and start it in
   your supervision tree, after the PubSub, with a policy that says who
   may be in which room (see Issho's README):

   ```elixir
   {Issho, name: MyApp.Issho, pubsub: MyApp.PubSub, policy: MyApp.Collaboration}
   ```

2. Issho's hook and Masu's in the LiveView (`on_mount Masu.Live` and
   `on_mount Issho.Live`, or in its `live_session`), and `live` on the
   grid for the rows (see [Live rows](live.md)).

3. `issho` and `user` on the grid. `issho` names the instance and the
   room, and, if the room knows the person by another value than `user`,
   `actor` (your user struct, with its `Issho.Actor`). `user` is a map
   with an `id`, and a `name`, a `color` (a CSS color) and an `avatar` (an
   image's URL) if you have them.

The grid is a place of the room: `"orders/orders"`, the room and the
grid's id. A person's cell and range go into the room's awareness, the
cell they edit is a lock of the room, and their view goes with them, for
following. The colors are Issho's: a person's own, else their color of
the room's palette in Issho's theme (`issho.css`), as Issho's list of
people and its pointers show them. The people a person sees are the
others: someone with the grid open in two tabs does not see themselves.

On a page that lists the room's people itself
(`Issho.Components.people/1`), `people={false}` leaves out the avatars
above the grid; the cells still show who is where.

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
in a room or not (see [Editing](editing.md)), and the refusal names who
changed it: "Changed by Ada meanwhile." The grid knows from its `live`
topic, so the name shows in a room or not.

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

A person's place (their cell, range and first row on the screen) goes to
the server when it changes, at most every 150 ms, and to the others
through the room's awareness; Issho's presence notices a person who
leaves or whose connection drops. A person's name, color and
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

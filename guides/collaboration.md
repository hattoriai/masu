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
  issho={[instance: MyApp.Issho, document: "orders"]}
  user={%{id: @current_user.id, name: @current_user.name}}
>
```

## Setting up

1. Add Issho to your dependencies (`{:issho, "~> 0.4.2"}`) and start it in
   your supervision tree, after the PubSub, with a policy that says who
   may be in which room (see Issho's README):

   ```elixir
   {Issho, name: MyApp.Issho, pubsub: MyApp.PubSub, policy: MyApp.Collaboration}
   ```

2. Issho's hook and Masu's in the LiveView (`on_mount Masu.Live` and
   `on_mount Issho.Live`, or in its `live_session`), and `live` on the
   grid for the rows (see [Live rows](live.md)).

3. `issho` and `user` on the grid. `issho` takes the keys of every
   component of an Issho page (`Issho.Join`, the same for Kotoba's editor
   and Hakushi's canvas): `:instance` and `:document` (required: the
   grid's name, whose room is the part before the first `"/"`); `:can`,
   `:read` for a reader; `:people` and `:follow` (below); `:on_behalf_of`
   and `:claims`, for your policy. And Masu's own `:actor`, if the room
   knows the person by another value than `user` (your user struct, with
   its `Issho.Actor`). Any other key raises. `user` is a map
   with an `id`, and a `name`, a `color` (a CSS color) and an `avatar` (an
   image's URL) if you have them.

The grid is a document of the room, by its name (`"orders"`, or
`"notebook:42/tasks"` in the room `"notebook:42"`): the same grid in two
places of the app (its page, an embed in a document, whose ids differ)
is one grid, with one people. A person's cell and range go into the room's awareness, the
cell they edit is a lock of the room, and their view goes with them, for
following. The colors are Issho's: a person's own, else their color of
the room's palette in Issho's theme (`issho.css`), as Issho's list of
people and its pointers show them. The people a person sees are the
others: someone with the grid open in two tabs does not see themselves.

On a page that lists the room's people itself
(`Issho.Components.people/1`), `issho`'s `people: false` leaves out the
avatars above the grid; the cells still show who is where.

### A person's state, and a place in the grid

What the grid says of its person in the room is in Issho's keys of their
state: `place` (their cell or range), `locks` (the cell they edit) and
`pointer`. Masu's own (that the grid is open, its view, its first row on
the screen) are under the grid's document, in `"blocks"` (see
`Issho.Awareness`), so the page's other blocks never collide with them.

A place in the grid is in its own terms, rows by their ids and columns
by their keys, never pixels, as each person has their own order and
filters. Its format is part of Masu's API, and only grows
(`Masu.Issho.Place`):

```elixir
%{"cell" => [row_id, key]}
%{"range" => %{"rows" => [row_id, ...], "keys" => [key, ...]}}
%{"cell" => [row_id, key], "x" => 0.5, "y" => 0.5}   # a pointer in a cell
```

The places the grid sets, a person's and an agent's, say what they are in
a few words too, in their `"label"` beside `"at"`: a cell's column and
its row's first cell (`Status of “Forge the blade”`), a range's size
(`Status, 3 rows`, `3 rows × 2 columns`). Issho shows it to agents and
in the comments panel; only `"at"` locates the place.

### Who wrote, and the room hears of it

A write's `by` (`Masu.Write`) is who made it, an `Issho.Identity` on a
grid with `issho`: the person, or an agent and whom it acts for. Each
saved write says so in the room, `"document.changed"` of the grid's
document (`Issho.Events`), with `by` and `data: %{op: :update, count: n}`:
a page, a job or an agent that waits for a change subscribes to it. A
component of the page asks for it with `Issho.Live.subscribe/3`'s
`:events` (`["document.changed"]`), and an agent waits for it with
Issho's `wait_for_events` tool:

```text
wait_for_events {"room": "notebook:42", "names": ["document.changed"]}
```

The grid's rows are not an Issho document, so it has no spec of events
of its own (a spec's `:events`): `"document.changed"` is what it says.

## In a document, and pointers

A grid embedded in a document (see [In a document](documents.md)) is in
its own room, whatever the document's: everyone with the grid open, in a
document or on its page, sees the others there, their cells and their
pointers.

* Give the grid its name in the room (`grid`), the same everywhere it is.
* A pointer over a cell is that cell: Issho's pointers of the grid's room
  (`Issho.Components.pointers/1`) share and draw it, the same spot of the
  same cell on every screen. On a page without them (a document of
  another room, whose pointers leave the grid to its room), the grid
  shares its person's pointer itself, and draws the others'.
* A reader of the document (`can: :read` in `issho`) is a viewer of the
  grid's room.
* The same grid twice on a page: the copy the person uses says where they
  are, the others say nothing.
* A grid that goes from the page while its LiveView stays (an embed
  deleted from the document) lets its room go: the others see the person
  leave it, or, when another grid of the room stays, leave this grid.
* Following someone into the grid, from the document's people list,
  follows them in the grid too; following from the grid's avatars brings
  it into view, once, when it is off the screen.

## Comments

Issho's comments (`Issho.Components.comments/1`, see Issho's Comments
guide) go on a grid's cells as on any place of the page: a person
selects a cell or a range, and comments on it. Each thread's mark is
drawn on its cells, wherever each person's order puts the row, and not
at all while the row is off their screen. Masu draws them with no code
of yours: the grid says where its places are.

A thread's place is the grid's (`Masu.Issho.Place`), so say it in words
with `Masu.Issho.label/2`, in the panel's `:place` slot:

```heex
<.comments id="comments" room="orders:42">
  <:place :let={%{place: place, default: default}}>
    {Masu.Issho.label(place, grid: "orders:42/orders", columns: @labels, row: &order_name/1) ||
      default}
  </:place>
</.comments>
```

`"City of Acme"` for a cell, `"Name to City of Acme"` for a range in a
row, `"City of 3 rows"` for a range of rows; `columns` are the columns'
labels by key, and `row` names a row by its id (`"row 7"` without it).
A row's number would not do: each person has their own order.

The LiveView is in the room before the panel renders
(`Issho.Live.join/4` in `mount`, when connected), and the page has
Issho's hooks (`Hooks` from `issho`) and its style sheet. An agent
comments on a cell with Issho's `comment` tool, with the grid as its
`document` and the cell as its `at`: `{"cell": [7, "city"]}`.

## Places, not positions

Each person has their own order, filters and search. A place is a row's
id and a column's key: a person sees another's line on that row wherever
it is in their own order, and no line when their filters leave the row
out (the avatar stays).

## Following someone

Following is Issho's, and a room's: follow someone, from the grid's
avatars or from the page's people list (`Issho.Components.people/1`), and
every block of the room shows what they see, the grid in its own terms:
their order, filters and search, and their place in it (the first row on
their screen, and their cell). As they scroll, sort or filter, the grid
goes with them. Someone followed who is not in the grid (in the editor
beside it) is followed there when they open it; meanwhile the grid keeps
what it shows. A grid alone in its room follows within itself, by the same
means. Above the grid: "Following Ada", with
Stop; the grid has a ring in their color, their filter chips take it
too, and a screen reader hears "Showing Ada's view" with their filters.
Their avatar is `aria-pressed`.

Following never costs the person their place. Their own view (order,
filters, search, scroll position and selection) is kept aside:

* **Stop**, or a second click on the avatar, brings it back.
* **Scrolling, a click in the grid or a key** stops following, in the
  whole room, but keeps Ada's view (they followed her to see it); the
  banner says "Ada's view", with "Back to your view". So does a Stop from
  the page's people list, or the person's own way elsewhere on the page.
* **A view of their own** (a sort, a filter or a search) is theirs from
  then on: there is nothing to go back to.

When the views already match, following only scrolls.

The look is Issho's, the same as its people list's and every other
block's on the page: the banner carries Issho's classes
(`issho-following`, `issho-following-stop`) besides its own
(`.masu-following`), the grid carries `data-following` while it follows,
and Issho's properties, on the page, restyle all of them at once:

    :root {
      --issho-following-background: #111827;  /* the person's color */
      --issho-following-text: #fff;
      --issho-following-ring: none;            /* a ring of the person's color */
    }

`--masu-follow-color` is the followed person's color, for your own rules.

A grid that should take no part in following, though the other blocks of
its room do, says so: `issho`'s `follow: false`. Its avatars are not buttons, it
shows no one followed, and its view stays its person's when the room
follows someone.

    <.data_grid id="orders" rows={@orders} issho={[instance: MyApp.Issho, document: "orders", follow: false]} user={@user} />

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
the server when it changes, at most every 150 ms (their pointer over a
cell, when the grid shares it, every 60 ms), and to the others
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

A person who pauses or stops the agent (Issho's agents bar,
`Issho.Work`) stops it in the grid too: each of these tools but
`read_grid` then says who paused it and what to do, as Issho's own tools
do, and an edit of many cells, one by one, stops at the cell it is on.

An agent moves as a person does, so that the people follow it: it goes
to each cell it edits and types in it a moment before the value lands,
and selects a range as a drag does, from its first cell. Only where it
goes is sent: each browser draws the way there, its mark gliding from cell
to cell and a range sweeping over its rows. With Issho's page
pointers, the agent's pointer goes to its cell too. For changes that land
at once:

    config :masu, Masu.Issho, pace: 0, travel: false

# Upgrading

## To Masu 0.5

Masu 0.5 hands what is the room's to [Issho](https://hex.pm/packages/issho)
0.3, as Kotoba 0.7 and Hakushi 0.3 do: following someone, and how agents
move. A grid without `issho` needs nothing.

### Why

- **Following is the room's, not the grid's.** In 0.4 a grid followed
  someone on its own: on a page with a grid, a text and a canvas, following
  Ada in the grid left the text and the canvas where they were. Following
  is now Issho's: follow Ada from the page's people list or the grid's
  avatars, and the grid shows her view, the canvas her viewport and the
  text her caret, and the page scrolls to her. A grid alone on a page
  follows within itself, as before.
- **Agents move as people do, everywhere alike.** An agent goes to each
  cell it edits and types in it before the value lands, selects a range as
  a drag does, and its pointer goes from the text to the grid as one. Only
  where it goes is sent; each browser draws the way; and it moves only for
  someone who sees it (`Issho.Motion`).

### What changes

| 0.4 | 0.5 |
| --- | --- |
| a grid followed someone on its own | following is the room's (`data-issho-following`, the `issho:following` event): the grid's avatars, the page's people list and every block of the room agree |
| scrolling or a key in the grid stopped following in the grid | it stops following in the room |
| `config :masu, Masu.Issho, pace: 120`: the agent saved, then waited | the agent goes to the cell (`travel`, true), "types" for `pace`, then saves; `pace: 0, travel: false` for changes at once |
| `{:issho, "~> 0.2"}` | `{:issho, "~> 0.3"}` |
| `issho={[instance: MyApp.Issho, room: "orders"]}` (the grid's place `"orders/<its id>"`) | `issho={[instance: MyApp.Issho, document: "orders"]}`: the keys of every component (`Issho.Join`); the grid's document is its name, whose room is the part before the first `"/"` |
| `people={false}`, `follow={false}` | `issho={[..., people: false, follow: false]}` |
| the grid's `"masu"` key at the top of a person's state | under the grid's document, in `"blocks"` |
| a `Masu.Write` had no author | its `by`: an `Issho.Identity` on a grid with `issho`, else the grid's `user`; each saved write emits `"document.changed"` in the room |

The grid's markup is the same: its avatars carry `data-issho-follow-control`,
so that pressing one is not taken for the person going their own way.

### Steps

1. **Update** `{:masu, "~> 0.5"}` and `{:issho, "~> 0.3"}`.
2. **Load Issho's script** on the page, if it is not there yet: following
   across the page, and the pointers, are its (`Hooks` from `issho`, in
   your LiveSocket). A grid follows within itself without it.
3. **Join with `document`.** `room:`, and the `people` and `follow`
   attributes, raise with what to write instead:

   ```diff
   -<.data_grid id="orders" ... issho={[instance: MyApp.Issho, room: "orders"]} follow={false} user={@user} />
   +<.data_grid id="orders" ... issho={[instance: MyApp.Issho, document: "orders", follow: false]} user={@user} />
   ```

   A grid's document is what its place in the room was: `"orders/orders"`
   for a grid `orders` in the room `"orders"` before, so give it
   `document: "orders/orders"` to keep its people's places, or a name of
   your own (`"orders"`, a room of its own).
4. **List the page's people once**: `Issho.Components.people/1`, and
   `issho`'s `people: false` on the grid, on a page with several blocks in
   the room. A click on someone there follows them.
5. **Agents' tools** name a grid by its document already
   (`"notebook:42/tasks"`): nothing changes.

## To Masu 0.4

Masu 0.4 moves a grid's people onto [Issho](https://hex.pm/packages/issho),
collaboration for Phoenix, as Kotoba 0.6 moves its shared editing there,
and as Hakushi was built. A grid that shows no people works exactly as
before: rows, sources, scrolling, queries, editing, history, views and
`live` rows are unchanged, and need nothing.

This guide is for a grid with `presence`: the avatars above it, each
person's cell, the cell someone types in, following someone.

### Why

Masu 0.3 kept its people in `Phoenix.Presence`, on its own. That was
enough for one grid on a page, and it was the only thing it could do:

- **A page has one set of people.** A page with a grid, a text and a
  canvas showed three lists of people, three colors for one person, and
  three ways of saying who may be there. In an Issho room it shows one:
  one list (`Issho.Components.people/1`), one color for each person on
  every part of the page, and the same people in the grid as in the
  editor beside it.
- **The room's policy says who is there.** `presence` showed whoever had
  the topic open. An Issho room asks your policy (`Issho.Policy`) who may
  join, read, write and hold a cell, on join and again as they work, and
  takes out someone whose access you take away.
- **Agents.** In an Issho room an agent is someone: it reads the grid,
  points at cells, edits them, adds and deletes rows the grid's way (its
  changeset, its read-only rules, the compare of a cell changed
  meanwhile, its history), the people see it on its cell, and its rows
  flash in its color. It reaches your app however you like: MCP, your
  app's own model, a job (`Masu.Issho`, `Masu.Sheet`).
- **The page as a live space.** Issho draws each person's pointer over
  the whole page (`Issho.Components.pointers/1`), and an agent at work in
  the grid at its corner.
- **What comes next is Issho's.** Following someone from page to page, a
  grid inside a text or a canvas, a grid of another app or another
  cluster: Issho's roadmap, which a grid in a room gets as it comes,
  rather than each library building its own.

Masu keeps what is Masu's: the rows. They come from your database, in
blocks, as the person scrolls, and `live` brings the others' changes as
they land, as before. Issho carries only who is there and where.

### What changes

| 0.3 | 0.4 |
| --- | --- |
| `presence={MyAppWeb.Presence}` | `issho={[instance: MyApp.Issho, room: "orders"]}` |
| `on_mount Masu.Live` | `on_mount Masu.Live` and `on_mount Issho.Live` |
| `Masu.Presence.color/1`, a palette of eight in Masu | Issho's colors: a person's own, or their color of the room's palette in Issho's theme (`issho.css`, `--issho-person-1` to `-8`) |
| a person with no color flashes rows in Masu's palette | in the room's color; with `live` and no room, in their own color, or the grid's default flash |

`user`, `share_view`, the `:person` slot, `configure({peerLabel})`, the
`.masu-peer` elements and their CSS, and the messages are as they were.
A grid given `presence` raises, and says what to give it instead.

### Steps

1. **Add Issho** to your dependencies:

   ```elixir
   {:masu, "~> 0.4"},
   {:issho, "~> 0.2"}
   ```

2. **Start it** in your supervision tree, after the PubSub, with a policy:

   ```elixir
   {Issho, name: MyApp.Issho, pubsub: MyApp.PubSub, policy: MyApp.Collaboration}
   ```

   ```elixir
   defmodule MyApp.Collaboration do
     @behaviour Issho.Policy

     # Whoever could open the grid's page may be in its room.
     @impl true
     def authorize(%Issho.Identity{key: user_id}, "orders", _action),
       do: if(MyApp.Accounts.member?(user_id), do: :ok, else: {:error, :forbidden})

     def authorize(_identity, _room, _action), do: {:error, :forbidden}

     @impl true
     def document(_identity, _id), do: {:error, :not_found}
   end
   ```

   A grid needs no Issho socket: its LiveView is the room's session.
   Mount Issho's channel (see Issho's README) when the page has Kotoba
   editors or Issho's people list or pointers, whose browsers join the
   room themselves.

3. **Add Issho's hook** next to Masu's:

   ```elixir
   live_session :default, on_mount: [Masu.Live, Issho.Live] do
   ```

4. **Give the grid its room** instead of `presence`:

   ```diff
    <.data_grid
      id="orders"
      source={Order}
      repo={Repo}
      changeset={&Order.changeset/2}
      live={{MyApp.PubSub, "orders"}}
   -  presence={MyAppWeb.Presence}
   +  issho={[instance: MyApp.Issho, room: "orders"]}
      user={%{id: @current_user.id, name: @current_user.name}}
    >
   ```

   Keep `live`: it is the rows. When the room knows the person by your
   user struct (an `Issho.Actor` of your own, as your Kotoba editors use),
   give it as `actor` (`issho={[instance: ..., room: ..., actor:
   @current_user]}`), so the person is the same one in every part of the
   page.

5. **Load Issho's theme**, for the room's colors: `issho.css` (and
   `issho-sumi.css` after it for the Sumi theme), or your own
   `--issho-person-1` to `--issho-person-8`.

6. **Remove your `Phoenix.Presence` module**, if the grid was all it was
   for.

### Then

- Give the grid's agents their tools: `Masu.Issho.tools/0`, with
  Issho's room tools, over MCP or to your own model (see
  [Collaboration](collaboration.md#agents)).
- On a page with several parts in the room, list its people once
  (`Issho.Components.people/1`) and give the grid `people={false}`.
- Show the pointers of the page's people: `Issho.Components.pointers/1`.

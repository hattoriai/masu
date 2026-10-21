# Upgrading to Masu 0.4

Masu 0.4 moves a grid's people onto [Issho](https://hex.pm/packages/issho),
collaboration for Phoenix, as Kotoba 0.6 moves its shared editing there,
and as Hakushi was built. A grid that shows no people works exactly as
before: rows, sources, scrolling, queries, editing, history, views and
`live` rows are unchanged, and need nothing.

This guide is for a grid with `presence`: the avatars above it, each
person's cell, the cell someone types in, following someone.

## Why

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

## What changes

| 0.3 | 0.4 |
| --- | --- |
| `presence={MyAppWeb.Presence}` | `issho={[instance: MyApp.Issho, room: "orders"]}` |
| `on_mount Masu.Live` | `on_mount Masu.Live` and `on_mount Issho.Live` |
| `Masu.Presence.color/1`, a palette of eight in Masu | Issho's colors: a person's own, or their color of the room's palette in Issho's theme (`issho.css`, `--issho-person-1` to `-8`) |
| a person with no color flashes rows in Masu's palette | in the room's color; with `live` and no room, in their own color, or the grid's default flash |

`user`, `share_view`, the `:person` slot, `configure({peerLabel})`, the
`.masu-peer` elements and their CSS, and the messages are as they were.
A grid given `presence` raises, and says what to give it instead.

## Steps

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

## Then

- Give the grid's agents their tools: `Masu.Issho.tools/0`, with
  Issho's room tools, over MCP or to your own model (see
  [Collaboration](collaboration.md#agents)).
- On a page with several parts in the room, list its people once
  (`Issho.Components.people/1`) and give the grid `people={false}`.
- Show the pointers of the page's people: `Issho.Components.pointers/1`.

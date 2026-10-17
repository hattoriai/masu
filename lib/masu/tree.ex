defmodule Masu.Tree do
  @moduledoc """
  Rows in a tree: children with the columns of their parent, indented,
  opened and closed.

      <.data_grid id="accounts" rows={@accounts} tree={:parent_id}>

  `tree` names the field of a row that holds its parent's id (or is a
  function of the row that gives it); a row whose parent is `nil`, or not
  among the rows, is a root. The grid shows the roots, and the children
  of each row the person opens, as one list: a tree of twenty thousand
  rows scrolls as a list of twenty thousand rows does, a block at a time.

  Sorting sorts the children of each row among themselves. A filter or a
  search keeps the rows that match and their ancestors, so that a match is
  never shown without the rows above it; while one is applied, the rows it
  keeps are open, and the person may close them.

  Both sources take `tree` (see `Masu.Source.List` and `Masu.Source.Ecto`).
  A source of your own implements `c:Masu.Source.nodes/3`.
  """

  @typedoc """
  Where a row is in the tree: its `level` (0 for a root), whether it has
  `children`, whether it is `expanded`, its `position` among its siblings
  (from 1) and how many siblings there are (`size`).
  """
  @type node_info :: %{
          level: non_neg_integer(),
          children: boolean(),
          expanded: boolean(),
          position: pos_integer(),
          size: pos_integer()
        }

  @typedoc false
  # A row of the flat list: its id, its parent's id and where it is.
  @type entry :: {term(), term(), node_info()}

  @doc false
  # The rows that show, in order: the roots, each followed by its
  # children when it is open (`open?`), at any depth. `entries` are
  # `{id, parent_id}` in the order wanted among siblings; `has_children`
  # holds ids known to have children that are not among the entries (the
  # children of a closed row a database did not read).
  @spec flatten([{term(), term()}], (term() -> boolean()), MapSet.t()) :: [entry()]
  def flatten(entries, open?, has_children \\ MapSet.new()) do
    ids = MapSet.new(entries, &elem(&1, 0))

    {roots, by_parent} =
      Enum.reduce(entries, {[], %{}}, fn {id, parent}, {roots, by_parent} ->
        if is_nil(parent) or parent == id or not MapSet.member?(ids, parent),
          do: {[id | roots], by_parent},
          else: {roots, Map.update(by_parent, parent, [id], &[id | &1])}
      end)

    by_parent = Map.new(by_parent, fn {parent, kids} -> {parent, Enum.reverse(kids)} end)
    parents = Map.new(entries)

    context = %{by_parent: by_parent, parents: parents, open?: open?, has_children: has_children}
    {flat, _seen} = walk(Enum.reverse(roots), 0, context, {[], %{}})
    Enum.reverse(flat)
  end

  # Depth first; a row is shown once, whatever cycles the data has.
  defp walk(siblings, level, context, acc) do
    size = length(siblings)

    siblings
    |> Enum.with_index(1)
    |> Enum.reduce(acc, fn {id, position}, {_flat, seen} = acc ->
      if Map.has_key?(seen, id),
        do: acc,
        else: visit(id, %{level: level, position: position, size: size}, context, acc)
    end)
  end

  defp visit(id, place, context, {flat, seen}) do
    kids = Map.get(context.by_parent, id, [])
    children = kids != [] or MapSet.member?(context.has_children, id)
    expanded = children and context.open?.(id)
    info = Map.merge(place, %{children: children, expanded: expanded})
    acc = {[{id, Map.get(context.parents, id), info} | flat], Map.put(seen, id, true)}

    if expanded and kids != [],
      do: walk(kids, place.level + 1, context, acc),
      else: acc
  end

  @doc false
  # The ids of the rows of `flat` beside the row `id` (the roots, for a
  # root) that have children.
  @spec siblings([entry()], term()) :: [term()]
  def siblings(flat, id) do
    case List.keyfind(flat, id, 0) do
      {_id, _parent, %{level: 0}} ->
        for {sibling, _parent, %{level: 0, children: true}} <- flat, do: sibling

      {_id, parent, _info} ->
        for {sibling, ^parent, %{children: true}} <- flat, do: sibling

      nil ->
        []
    end
  end

  @doc false
  # The ids to keep for a filter: those that match, and their ancestors.
  # `parent_of` gives a row's parent id (nil for a root).
  @spec with_ancestors(Enumerable.t(), (term() -> term())) :: MapSet.t()
  def with_ancestors(matching, parent_of) do
    Enum.reduce(matching, MapSet.new(), fn id, kept -> climb(id, parent_of, kept) end)
  end

  defp climb(nil, _parent_of, kept), do: kept

  defp climb(id, parent_of, kept) do
    if MapSet.member?(kept, id),
      do: kept,
      else: climb(parent_of.(id), parent_of, MapSet.put(kept, id))
  end

  @doc false
  # A row's place as the browser gets it, after its cells: level,
  # children, expanded, position and size.
  @spec to_wire(node_info()) :: list()
  def to_wire(%{level: level, children: children, expanded: expanded} = info),
    do: [level, children, expanded, info.position, info.size]
end

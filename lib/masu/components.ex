defmodule Masu.Components do
  @moduledoc """
  The grid component.

      import Masu.Components

      <.data_grid id="users" rows={@users} label="Users">
        <:col field={:name} />
        <:col field={:email} />
        <:col field={:inserted_at} type={:datetime} label="Joined" />
      </.data_grid>

  `data_grid/1` goes in a LiveView. It needs the `Masu` hook in the
  LiveSocket and the Masu CSS (see the README). The rows come from a
  list (`rows`), or from an Ecto query or schema and a repo (`source` and
  `repo`), which then sorts, filters and counts in the database; see the
  [Sources](sources.md) guide.
  """

  use Phoenix.Component

  @doc """
  Renders a data grid.

  The browser draws only the rows on the screen, and asks the grid for
  the others as the person scrolls. A click on a column's header sorts by
  it (with Shift, by it too); the edge of a header resizes its column,
  and a double click there fits the column to its content. The arrow keys
  move between the cells, Shift with them selects a range, and ⌘C (Ctrl+C)
  copies the range as text that a spreadsheet pastes.

  ## Columns

  Each `:col` is a column (see `Masu.Column`):

    * `field` - the key of the row's value (a map key or a struct field);
    * `value` - a function of the row that computes the value instead;
      it needs a `key`, and does not sort or filter with an Ecto source;
    * `key` - the name of the column in `Masu.Test` and in filters; the
      field as a string unless given;
    * `label` - the header; the field in words unless given;
    * `type` - `:text` (the default), `:enum`, `:integer`, `:number`,
      `:decimal`, `:date`, `:datetime`, `:time` or `:boolean`;
    * `width` and `min_width` - in pixels;
    * `align` - `:start`, `:center` or `:end` (numbers are at the end);
    * `sortable`, `filterable` and `searchable` - `false` to turn off,
      `searchable` is on for text and enums;
    * `editable` - in a grid that edits: `false` for a read-only column, or
      a function of the row that says whether its cell edits.

  A `:col` with content renders each cell, with the row as `:let`:

      <:col :let={user} field={:name}>
        <.link navigate={~p"/users/\#{user}"}>{user.name}</.link>
      </:col>
  """
  attr :id, :string, required: true, doc: "the id of the grid"
  attr :rows, :list, default: nil, doc: "the rows, maps or structs"

  attr :source, :any,
    default: nil,
    doc: "an Ecto query or schema (with `repo`), or `{module, opts}` of a `Masu.Source`"

  attr :repo, :atom, default: nil, doc: "the repo of an Ecto source"
  attr :repo_opts, :list, default: [], doc: "options for each call to the repo"

  attr :changeset, :any,
    default: nil,
    doc:
      "a function of a row and params that gives a changeset: the person edits the cells, see the Editing guide"

  attr :update, :any,
    default: nil,
    doc:
      "a function of a row and params that saves them: `{:ok, row}` or `{:error, changeset_or_message}`; instead of `changeset`"

  attr :row_editable, :any,
    default: nil,
    doc: "a function of a row: `false` makes every cell of the row read-only"

  attr :on_save, :any,
    default: nil,
    doc: "a function called with the rows saved by an edit, in the LiveView's process"

  attr :live, :any,
    default: nil,
    doc:
      "`{pubsub, topic}`: shows the rows that change on the topic as they change, see `Masu.Live`"

  attr :row_id, :any,
    default: nil,
    doc: "a function that gives a row's id; the `id` of the row unless given"

  attr :sort, :list,
    default: [],
    doc: "the first order: keys, `{key, :asc | :desc}` or `Masu.Sort` structs"

  attr :filters, :list,
    default: [],
    doc: "the first filters: `{key, op, value}` or `Masu.Filter` structs"

  attr :searchable, :boolean, default: false, doc: "when `true`, a search box above the grid"
  attr :label, :string, default: nil, doc: "the name of the grid for a screen reader"
  attr :label_id, :string, default: nil, doc: "the id of an element that names the grid"
  attr :row_height, :integer, default: 36, doc: "the height of a row, in pixels"
  attr :height, :string, default: "32rem", doc: "the height of the grid, as CSS"

  attr :locale, :string,
    default: nil,
    doc: "the locale that formats numbers and dates; the browser's unless given"

  attr :messages, :map,
    default: %{},
    doc: "words that replace the built-in ones (`search`, `empty`, `rows`, `loading`)"

  attr :class, :any, default: nil, doc: "classes for the grid element"
  attr :rest, :global, doc: "attributes for the grid element"

  slot :col, required: true, doc: "a column" do
    attr :field, :any
    attr :value, :any
    attr :key, :string
    attr :label, :string
    attr :type, :atom
    attr :width, :integer
    attr :min_width, :integer
    attr :align, :atom
    attr :sortable, :boolean
    attr :filterable, :boolean
    attr :searchable, :boolean
    attr :editable, :any
  end

  slot :empty, doc: "what the grid shows when it has no rows"

  def data_grid(assigns) do
    if is_nil(assigns.rows) and is_nil(assigns.source) do
      raise ArgumentError, "<.data_grid id=#{inspect(assigns.id)}> needs rows or a source"
    end

    ~H"""
    <.live_component
      module={Masu.Grid}
      id={@id}
      input={if is_nil(@rows), do: @source, else: @rows}
      repo={@repo}
      repo_opts={@repo_opts}
      live={@live}
      changeset={@changeset}
      update={@update}
      row_editable={@row_editable}
      on_save={@on_save}
      row_id={@row_id}
      sort={@sort}
      filters={@filters}
      searchable={@searchable}
      label={@label}
      label_id={@label_id}
      row_height={@row_height}
      height={@height}
      locale={@locale}
      messages={@messages}
      class={@class}
      rest={@rest}
      col={@col}
      empty={@empty}
    />
    """
  end
end

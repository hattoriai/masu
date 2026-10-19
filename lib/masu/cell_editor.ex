defmodule Masu.CellEditor do
  @moduledoc false
  # The popover of a cell's editor that is a form of the app's (a
  # column's `editor` function component), under the cell. A component of
  # its own: it renders again only when what the editor gets changes, so
  # that a render of the grid (a live change, a count) leaves what the
  # person types in it as it is.
  #
  # The app's component gets:
  #
  #   * `field` - a form field of the cell's value, named `cell[value]`:
  #     what the form posts under it is the new value;
  #   * `form` - its form;
  #   * `value`, `row`, `id` - the cell's value and its row, as the row is
  #     now, and the row's id;
  #   * `column` - the `Masu.Column`;
  #   * `label` and `label_id` - the column's label, and the id of an
  #     element that has it, for the editor's input;
  #   * `scope` - the grid's scope.

  use Phoenix.LiveComponent

  alias Masu.Column

  @impl true
  def update(assigns, socket) do
    %{editor: editor, column: column, grid: grid} = assigns
    form = to_form(%{"value" => editor.value}, as: "cell", id: "#{grid}-cell")

    editor_assigns = %{
      field: form[:value],
      form: form,
      value: editor.value,
      row: editor.row,
      id: editor.id,
      column: column,
      label: column.label,
      label_id: "#{grid}-cell-label",
      scope: assigns.scope
    }

    {:ok,
     assign(socket,
       grid: grid,
       key: column.key,
       label: column.label,
       row_id: editor.id,
       version: editor.version,
       render_editor: render_fun(column),
       editor_assigns: editor_assigns
     )}
  end

  defp render_fun(%Column{editor: {:form, fun}}), do: fun

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={"#{@grid}-cell-editor"}
      class="masu-menu masu-panel masu-cell-editor"
      popover="manual"
      role="dialog"
      aria-labelledby={"#{@grid}-cell-label"}
      tabindex="-1"
      data-key={@key}
      data-id={JSON.encode!(Masu.Value.to_wire(@row_id))}
      data-version={@version}
    >
      <span id={"#{@grid}-cell-label"} class="masu-cell-editor-label">{@label}</span>
      <form id={"#{@grid}-cell-form"} class="masu-cell-form" autocomplete="off">
        {@render_editor.(@editor_assigns)}
      </form>
    </div>
    """
  end
end

// The toolbar's menus: the columns menu, the views menu and Export
// (Masu.Export), whose link the server gives once and the browser follows.

import { ColumnsPanel, ExportPanel, FiltersPanel, ViewsPanel } from "../panels";
import { COLUMNS_ICON, EXPORT_ICON, toolbarButton, VIEWS_ICON } from "../toolbar";
import type { Grid } from "../grid";

export class Toolbar {
  /** The toolbar's buttons and their menus. */
  private columnsButton: HTMLButtonElement | null = null;
  private viewsButton: HTMLButtonElement | null = null;
  private exportButton: HTMLButtonElement | null = null;
  panel:
    | { kind: "columns"; panel: ColumnsPanel }
    | { kind: "views"; panel: ViewsPanel }
    | { kind: "export"; panel: ExportPanel }
    | { kind: "filters"; panel: FiltersPanel }
    | null = null;

  constructor(private readonly grid: Grid) {}

  /** The toolbar's buttons: the columns menu and the views menu. */
  renderToolbar(): void {
    const wanted = this.grid.config.columnsMenu || this.grid.config.views !== null || (this.grid.config.export ?? []).length > 0;
    if (!wanted && !this.columnsButton && !this.viewsButton && !this.exportButton) return;

    let toolbar = this.grid.uiEl.querySelector<HTMLElement>(":scope > .masu-toolbar");
    if (!toolbar) {
      toolbar = document.createElement("div");
      toolbar.className = "masu-toolbar";
      this.grid.uiEl.prepend(toolbar);
    }
    let actions = toolbar.querySelector<HTMLElement>(".masu-toolbar-actions");
    if (!actions) {
      actions = document.createElement("div");
      actions.className = "masu-toolbar-actions";
      toolbar.appendChild(actions);
    }

    // A menu the grid no longer has (an `export` that turned false: the
    // person is no longer an admin, say) goes, with its panel.
    if (!this.grid.config.columnsMenu && this.columnsButton) this.columnsButton = this.dropButton("columns", this.columnsButton);
    if (this.grid.config.views === null && this.viewsButton) this.viewsButton = this.dropButton("views", this.viewsButton);
    if ((this.grid.config.export ?? []).length === 0 && this.exportButton)
      this.exportButton = this.dropButton("export", this.exportButton);

    if (this.grid.config.columnsMenu && !this.columnsButton) {
      this.columnsButton = toolbarButton(this.grid.message("columns_menu", {}), "masu-columns-button", COLUMNS_ICON);
      this.columnsButton.addEventListener("click", () => this.togglePanel("columns"));
      actions.appendChild(this.columnsButton);
    }
    if (this.grid.config.views !== null && !this.viewsButton) {
      this.viewsButton = toolbarButton(this.grid.message("views_menu", {}), "masu-views-button", VIEWS_ICON);
      this.viewsButton.addEventListener("click", () => this.togglePanel("views"));
      actions.appendChild(this.viewsButton);
    }
    if ((this.grid.config.export ?? []).length > 0 && !this.exportButton) {
      this.exportButton = toolbarButton(this.grid.message("export_menu", {}), "masu-export-button", EXPORT_ICON);
      this.exportButton.addEventListener("click", () => this.togglePanel("export"));
      actions.appendChild(this.exportButton);
    }
    if (this.viewsButton) {
      // The button says which named view shows, if one does: the person's
      // own first, when a shared one is the same.
      const views = this.grid.config.views ?? [];
      const current = views.find((view) => view.current && view.mine) ?? views.find((view) => view.current);
      const text = this.viewsButton.querySelector(".masu-toolbar-text")!;
      text.textContent = current ? current.name : this.grid.message("views_menu", {});
      if (current) this.viewsButton.setAttribute("aria-label", this.grid.message("views_current", { label: current.name }));
      else this.viewsButton.removeAttribute("aria-label");
    }

    if (this.panel?.kind === "columns") this.panel.panel.refresh();
    if (this.panel?.kind === "views") this.panel.panel.refresh();
  }

  togglePanel(kind: "columns" | "views" | "export" | "filters"): void {
    const open = this.panel?.kind;
    this.closePanel(false);
    if (open === kind) return;
    this.grid.filters.closeMenu(false);
    const messages = this.grid.messages();

    if (kind === "filters") {
      if (!this.grid.filters.addFilter) return;
      const panel = new FiltersPanel(
        {
          root: this.grid.uiEl,
          messages,
          columns: this.grid.columns.flatMap((column, col) =>
            column.filterable
              ? [{ col, label: column.label, filtered: this.grid.query.filters.some((filter) => filter.key === column.key) }]
              : [],
          ),
          pick: (col) => {
            this.closePanel(false);
            this.grid.filters.openMenu(col, { chip: null });
          },
          close: () => this.closePanel(true),
        },
        this.grid.filters.addFilter,
      );
      this.panel = { kind, panel };
    } else if (kind === "export") {
      if (this.exportButton?.dataset.busy) return;
      const panel = new ExportPanel(
        {
          root: this.grid.uiEl,
          messages,
          formats: this.grid.config.export ?? [],
          start: (format) => {
            this.closePanel(true);
            this.startExport(format);
          },
          close: () => this.closePanel(true),
        },
        this.exportButton!,
      );
      this.panel = { kind, panel };
    } else if (kind === "columns") {
      const panel = new ColumnsPanel(
        {
          root: this.grid.uiEl,
          messages,
          catalog: () => this.grid.config.catalog,
          change: (layout) => this.grid.layout.sendLayout(layout),
          close: () => this.closePanel(true),
        },
        this.columnsButton!,
      );
      this.panel = { kind, panel };
    } else {
      const panel = new ViewsPanel(
        {
          root: this.grid.uiEl,
          messages,
          views: () => this.grid.config.views ?? [],
          apply: (id) => this.viewAction({ action: "apply", id }),
          reset: () => this.viewAction({ action: "reset" }),
          save: (name, shared, done) =>
            this.grid.transport.push("masu:view", { action: "save", name, shared }, (reply) => done((reply.error as string | undefined) ?? null)),
          remove: (id) => this.grid.transport.push("masu:view", { action: "delete", id }),
          close: () => this.closePanel(true),
        },
        this.viewsButton!,
      );
      this.panel = { kind, panel };
    }
  }

  /** A view applied: its rows from the first. */
  private viewAction(payload: Record<string, unknown>): void {
    this.grid.transport.push("masu:view", payload, (reply) => {
      if (reply.error) {
        this.grid.announce(String(reply.error));
        return;
      }
      this.grid.scrollToContent(0);
      this.grid.anchor = null;
      this.grid.active = { row: Math.min(this.grid.active.row, 0), col: Math.min(this.grid.active.col, this.grid.columns.length - 1) };
      this.grid.render();
      this.grid.announceCount();
    });
  }

  private dropButton(kind: "columns" | "views" | "export", button: HTMLButtonElement): null {
    if (this.panel?.kind === kind) this.closePanel(false);
    button.remove();
    return null;
  }

  closePanel(focus: boolean): void {
    if (!this.panel) return;
    const { kind, panel } = this.panel;
    this.panel = null;
    panel.destroy();
    if (focus) ({ columns: this.columnsButton, views: this.viewsButton, export: this.exportButton, filters: this.grid.filters.addFilter })[kind]?.focus();
  }

  private startExport(format: string): void {
    const button = this.exportButton;
    if (!button) return;
    button.dataset.busy = "true";
    button.setAttribute("aria-busy", "true");
    this.grid.transport.push("masu:export", { format }, (reply) => {
      delete button.dataset.busy;
      button.removeAttribute("aria-busy");
      if (typeof reply?.url !== "string") {
        this.grid.announce(this.grid.message("export_failed", {}));
        return;
      }
      // A link with `download` downloads where it is, with no tab to open
      // (a pop-up blocker stops a window opened after a round trip).
      const link = document.createElement("a");
      link.href = reply.url;
      link.download = "";
      link.style.display = "none";
      document.body.appendChild(link);
      link.click();
      link.remove();
      this.grid.announce(this.grid.message("export_started", {}));
    });
  }
}

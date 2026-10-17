// The menus of the toolbar: the columns menu (show, hide, pin and move
// columns) and the views menu (named views: apply, save, share, delete).
// Each is a small dialog under its button; Escape or a click away closes
// it, and the focus goes back to the button.

import { moveKey } from "./layout";
import type { CatalogColumn, SavedView } from "./types";

const COLUMN_SEARCH_FROM = 9;

let panels = 0;

class Panel {
  readonly el: HTMLElement;
  protected readonly anchor: HTMLElement;
  protected messages: Record<string, string>;
  private cleanups: (() => void)[] = [];

  constructor(root: HTMLElement, anchor: HTMLElement, label: string, messages: Record<string, string>, close: () => void) {
    this.anchor = anchor;
    this.messages = messages;
    this.el = document.createElement("div");
    this.el.className = "masu-menu masu-panel";
    this.el.id = `masu-panel-${++panels}`;
    this.el.setAttribute("role", "dialog");
    this.el.setAttribute("aria-label", label);
    anchor.setAttribute("aria-expanded", "true");
    anchor.setAttribute("aria-controls", this.el.id);

    this.listen(this.el, "keydown", (event) => {
      if ((event as KeyboardEvent).key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        close();
      }
    });
    this.listen(document, "mousedown", (event) => {
      const target = event.target as Node;
      if (!this.el.contains(target) && !anchor.contains(target)) close();
    });
    root.appendChild(this.el);
  }

  destroy(): void {
    for (const cleanup of this.cleanups) cleanup();
    this.anchor.setAttribute("aria-expanded", "false");
    this.el.remove();
  }

  /** Under its button, inside the grid's element, at the end of the row. */
  protected place(root: HTMLElement): void {
    const box = root.getBoundingClientRect();
    const button = this.anchor.getBoundingClientRect();
    const width = this.el.offsetWidth;
    const left = Math.max(0, Math.min(button.right - box.left - width, box.width - width));
    this.el.style.top = `${button.bottom - box.top + 4}px`;
    this.el.style.insetInlineStart = `${left}px`;
  }

  protected message(name: string, label = ""): string {
    return (this.messages[name] ?? name).replace("{label}", label);
  }

  private listen(target: EventTarget, type: string, listener: (event: Event) => void): void {
    target.addEventListener(type, listener);
    this.cleanups.push(() => target.removeEventListener(type, listener));
  }
}

export interface ColumnsHost {
  root: HTMLElement;
  messages: Record<string, string>;
  catalog(): CatalogColumn[];
  change(layout: { order?: string[]; hidden?: string[]; pinned?: Record<string, string> }): void;
  close(): void;
}

/** The columns menu: each column, shown or not, its pin, and moves. */
export class ColumnsPanel extends Panel {
  private host: ColumnsHost;
  private list: HTMLElement;
  private search: HTMLInputElement | null = null;

  constructor(host: ColumnsHost, anchor: HTMLElement) {
    super(host.root, anchor, host.messages.columns_menu ?? "Columns", host.messages, () => host.close());
    this.host = host;
    this.el.classList.add("masu-columns-panel");

    if (host.catalog().length >= COLUMN_SEARCH_FROM) {
      this.search = document.createElement("input");
      this.search.type = "search";
      this.search.className = "masu-menu-input masu-panel-search";
      this.search.placeholder = this.message("columns_search");
      this.search.setAttribute("aria-label", this.search.placeholder);
      this.search.addEventListener("input", () => this.refresh());
      this.el.appendChild(this.search);
    }

    this.list = document.createElement("ul");
    this.list.className = "masu-columns-list";
    this.el.appendChild(this.list);

    const showAll = document.createElement("button");
    showAll.type = "button";
    showAll.className = "masu-panel-action";
    showAll.textContent = this.message("show_all");
    showAll.addEventListener("click", () => host.change({ hidden: [] }));
    this.el.appendChild(showAll);

    this.refresh();
    this.place(host.root);
    (this.search ?? this.list.querySelector<HTMLElement>("input, select, button"))?.focus();
  }

  /** Draws the list again (the layout changed), keeping the focus on its control. */
  refresh(): void {
    const focused = document.activeElement as HTMLElement | null;
    const focus = focused && this.list.contains(focused) ? { key: focused.dataset.key, role: focused.dataset.role } : null;
    const catalog = this.host.catalog();
    const find = this.search?.value.trim().toLowerCase() ?? "";

    const items = catalog.flatMap((column, index) => {
      if (find && !column.label.toLowerCase().includes(find)) return [];
      const item = document.createElement("li");
      item.className = "masu-columns-item";

      const label = document.createElement("label");
      const shown = document.createElement("input");
      shown.type = "checkbox";
      shown.checked = !column.hidden;
      shown.dataset.key = column.key;
      shown.dataset.role = "shown";
      shown.addEventListener("change", () => {
        const hidden = catalog.filter((c) => (c.key === column.key ? !shown.checked : c.hidden)).map((c) => c.key);
        this.host.change({ hidden });
      });
      const text = document.createElement("span");
      text.textContent = column.label;
      label.append(shown, text);

      const pin = document.createElement("select");
      pin.className = "masu-columns-pin";
      pin.dataset.key = column.key;
      pin.dataset.role = "pin";
      pin.setAttribute("aria-label", this.message("pin", column.label));
      for (const [value, name] of [["", "pin_none"], ["start", "pin_start"], ["end", "pin_end"]]) {
        pin.appendChild(new Option(this.message(name), value, false, (column.pinned ?? "") === value));
      }
      pin.addEventListener("change", () => {
        const pinned: Record<string, string> = {};
        for (const c of catalog) {
          const value = c.key === column.key ? pin.value : (c.pinned ?? "");
          if (value) pinned[c.key] = value;
        }
        this.host.change({ pinned });
      });

      // A move passes the hidden columns (it would show nothing), and stays
      // among the columns of its pin.
      const neighbor = (step: -1 | 1): CatalogColumn | null => {
        for (let i = index + step; i >= 0 && i < catalog.length; i += step) {
          const other = catalog[i];
          if ((other.pinned ?? null) !== (column.pinned ?? null)) return null;
          if (column.hidden || !other.hidden) return other;
        }
        return null;
      };

      const move = (step: -1 | 1) => {
        const button = document.createElement("button");
        button.type = "button";
        button.className = `masu-columns-move masu-columns-${step < 0 ? "up" : "down"}`;
        button.dataset.key = column.key;
        button.dataset.role = step < 0 ? "up" : "down";
        button.setAttribute("aria-label", this.message(step < 0 ? "move_up" : "move_down", column.label));
        button.textContent = step < 0 ? "↑" : "↓";
        const other = neighbor(step);
        button.disabled = other === null;
        button.addEventListener("click", () => {
          if (!other) return;
          const order = catalog.map((c) => c.key);
          this.host.change({ order: step < 0 ? moveKey(order, column.key, other.key) : moveKey(order, other.key, column.key) });
        });
        return button;
      };

      item.append(label, pin, move(-1), move(1));
      return [item];
    });
    this.list.replaceChildren(...items);

    if (focus) {
      const again = this.list.querySelector<HTMLElement>(`[data-key="${CSS.escape(focus.key ?? "")}"][data-role="${focus.role}"]`);
      if (again && !(again as HTMLButtonElement).disabled) again.focus();
      else this.list.querySelector<HTMLElement>(`[data-key="${CSS.escape(focus.key ?? "")}"]`)?.focus();
    }
  }
}

export interface ViewsHost {
  root: HTMLElement;
  messages: Record<string, string>;
  views(): SavedView[];
  apply(id: string): void;
  reset(): void;
  save(name: string, shared: boolean, done: (error: string | null) => void): void;
  remove(id: string): void;
  close(): void;
}

/** The views menu: the named views, the grid's own view, and saving one. */
export class ViewsPanel extends Panel {
  private host: ViewsHost;
  private list: HTMLElement;
  private status: HTMLElement;

  constructor(host: ViewsHost, anchor: HTMLElement) {
    super(host.root, anchor, host.messages.views_menu ?? "Views", host.messages, () => host.close());
    this.host = host;
    this.el.classList.add("masu-views-panel");

    this.list = document.createElement("ul");
    this.list.className = "masu-views-list";
    this.el.appendChild(this.list);

    const reset = document.createElement("button");
    reset.type = "button";
    reset.className = "masu-panel-action";
    reset.textContent = this.message("view_reset");
    reset.addEventListener("click", () => host.reset());
    this.el.appendChild(reset);

    const form = document.createElement("form");
    form.className = "masu-views-form";
    const name = document.createElement("input");
    name.className = "masu-menu-input";
    name.placeholder = this.message("view_name");
    name.setAttribute("aria-label", name.placeholder);
    name.maxLength = 120;
    const shareLabel = document.createElement("label");
    shareLabel.className = "masu-views-share";
    const share = document.createElement("input");
    share.type = "checkbox";
    shareLabel.append(share, document.createTextNode(this.message("view_share")));
    const save = document.createElement("button");
    save.type = "submit";
    save.className = "masu-menu-button masu-menu-apply";
    save.textContent = this.message("view_save");
    form.append(name, shareLabel, save);
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      host.save(name.value, share.checked, (error) => {
        this.status.textContent = error ?? this.message("view_saved");
        if (!error) name.value = "";
      });
    });
    this.el.appendChild(form);

    this.status = document.createElement("p");
    this.status.className = "masu-panel-status";
    this.status.setAttribute("role", "status");
    this.el.appendChild(this.status);

    this.refresh();
    this.place(host.root);
    (this.list.querySelector<HTMLElement>("button") ?? name).focus();
  }

  refresh(): void {
    const items = this.host.views().map((view) => {
      const item = document.createElement("li");
      item.className = "masu-views-item";
      const apply = document.createElement("button");
      apply.type = "button";
      apply.className = "masu-views-apply";
      apply.textContent = view.name;
      if (view.current) apply.setAttribute("aria-current", "true");
      apply.addEventListener("click", () => this.host.apply(view.id));
      item.appendChild(apply);
      if (view.shared) {
        const tag = document.createElement("span");
        tag.className = "masu-views-shared";
        tag.textContent = this.message("view_shared");
        item.appendChild(tag);
      }
      if (view.mine) {
        const remove = document.createElement("button");
        remove.type = "button";
        remove.className = "masu-views-delete";
        remove.setAttribute("aria-label", this.message("view_delete", view.name));
        remove.textContent = "×";
        remove.addEventListener("click", () => this.host.remove(view.id));
        item.appendChild(remove);
      }
      return item;
    });
    this.list.replaceChildren(...items);
    this.list.hidden = items.length === 0;
  }
}

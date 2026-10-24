// A column's header menu: a small dialog under its header, with its
// sorts, the app's items for the column (Masu.Action), Group by, and the filter:
// the operators of the column's type and the input they need. An enum
// lists its values with how many rows have each, asked of the server,
// with a search box when there are many.

import { floats, follow, lift, place as placeAt } from "./float";
import { arity, filterValue, inputType, inputValue, makeFilter, opLabel, opsFor, type Op } from "./filters";
import type { ColumnConfig, FilterSpec } from "./types";

const VALUE_SEARCH_FROM = 8;
const SEARCH_DELAY = 200;

export interface MenuHost {
  /** The element the menu is placed in (positioned). */
  root: HTMLElement;
  column: ColumnConfig;
  current: FilterSpec | undefined;
  /** Of datetimes: whether its values have a zone (false: `NaiveDateTime`s, filtered as written). */
  zoned?: boolean;
  messages: Record<string, string>;
  format(value: unknown): string;
  fetchValues(search: string | null, done: (values: [unknown, number][]) => void): void;
  apply(filter: FilterSpec | null): void;
  close(): void;
  /** Groups the rows by the column, or stops (Masu.Group); absent when the grid does not group. */
  group?: (on: boolean) => void;
  grouped?: boolean;
  /** The app's items for the column (`:header_action`). */
  actions?: { label: string; run(): void }[];
  /** Sorts by the column, or stops (null); absent when the column does not sort. */
  sort?: { dir: "asc" | "desc" | null; set(dir: "asc" | "desc" | null): void };
  /** Whether the menu has the column's filter (false: a header's menu without it, `header_filters={false}`). */
  filters?: boolean;
}

let menus = 0;

export class FilterMenu {
  readonly el: HTMLElement;
  private host: MenuHost;
  private op: Op;
  private form: HTMLFormElement;
  private fields: HTMLElement;
  private checked = new Set<string>();
  private searchTimer: ReturnType<typeof setTimeout> | null = null;
  private cleanups: (() => void)[] = [];

  /** Under `anchor`: an element, or a function that finds it again (a chip, drawn again as the rows change). */
  constructor(host: MenuHost, anchor: HTMLElement | (() => HTMLElement)) {
    this.host = host;
    const at = typeof anchor === "function" ? anchor : () => anchor;
    const { column, current, messages } = host;
    const filters = column.filterable && host.filters !== false;
    const ops = opsFor(column.type, column.filters, column.many);
    this.op = current && ops.includes(current.op as Op) ? (current.op as Op) : ops[0];
    if (current && arity(current.op as Op) === "list" && Array.isArray(current.value)) {
      for (const value of current.value) this.checked.add(JSON.stringify(value));
    }

    const id = `masu-menu-${++menus}`;
    this.el = document.createElement("div");
    this.el.className = "masu-menu";
    this.el.setAttribute("role", "dialog");
    this.el.setAttribute(
      "aria-label",
      (filters ? (messages.filter ?? "Filter {label}") : (messages.column_menu ?? "{label} menu")).replace("{label}", column.label),
    );
    this.el.id = id;

    if (host.sort) {
      const { dir, set } = host.sort;
      const sorts = document.createElement("div");
      sorts.className = "masu-menu-items masu-menu-sorts";
      sorts.setAttribute("role", "group");
      const items: ["asc" | "desc" | null, string][] = [
        ["asc", messages.sort_asc ?? "Sort ascending"],
        ["desc", messages.sort_desc ?? "Sort descending"],
      ];
      if (dir) items.push([null, messages.sort_clear ?? "Clear sort"]);
      for (const [to, label] of items) {
        const item = button(label, "button", "masu-menu-item masu-menu-sort");
        if (to) {
          item.dataset.dir = to;
          item.setAttribute("aria-pressed", String(dir === to));
        }
        item.addEventListener("click", () => {
          host.close();
          set(to);
        });
        sorts.appendChild(item);
      }
      this.el.appendChild(sorts);
    }

    if (host.actions?.length) {
      const actions = document.createElement("div");
      actions.className = "masu-menu-items";
      actions.setAttribute("role", "group");
      for (const action of host.actions) {
        const item = button(action.label, "button", "masu-menu-item");
        item.addEventListener("click", () => {
          host.close();
          action.run();
        });
        actions.appendChild(item);
      }
      this.el.appendChild(actions);
    }

    if (host.group) {
      const group = button(
        (messages[host.grouped ? "ungroup_by" : "group_by"] ?? "Group by {label}").replace("{label}", column.label),
        "button",
        "masu-menu-group",
      );
      group.addEventListener("click", () => host.group!(!host.grouped));
      this.el.appendChild(group);
    }

    this.form = document.createElement("form");
    this.form.className = "masu-menu-form";
    // A column that does not filter: its items and Group by only.
    if (filters) this.el.appendChild(this.form);

    if (ops.length > 1) {
      const select = document.createElement("select");
      select.className = "masu-menu-op";
      select.setAttribute("aria-label", messages.condition ?? "Condition");
      for (const op of ops) {
        const option = new Option(opLabel(op, column.type, messages, column.many), op, false, op === this.op);
        select.appendChild(option);
      }
      select.addEventListener("change", () => {
        this.op = select.value as Op;
        this.renderFields();
        this.focusFirst();
      });
      this.form.appendChild(select);
    }

    this.fields = document.createElement("div");
    this.fields.className = "masu-menu-fields";
    this.form.appendChild(this.fields);

    const actions = document.createElement("div");
    actions.className = "masu-menu-actions";
    const clear = button(messages.clear ?? "Clear", "button", "masu-menu-clear");
    clear.addEventListener("click", () => host.apply(null));
    const apply = button(messages.apply ?? "Apply", "submit", "masu-menu-apply");
    actions.append(clear, apply);
    this.form.appendChild(actions);

    this.form.addEventListener("submit", (event) => {
      event.preventDefault();
      host.apply(this.filter());
    });
    this.listen(this.el, "keydown", (event) => {
      if ((event as KeyboardEvent).key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        host.close();
      }
    });
    this.listen(document, "mousedown", (event) => {
      const target = event.target as Node;
      if (!this.el.contains(target) && !at().contains(target)) host.close();
    });

    if (filters) this.renderFields();
    host.root.appendChild(this.el);
    lift(this.el);
    this.place(at());
    this.cleanups.push(follow(() => this.place(at())));
    this.focusFirst();
  }

  destroy(): void {
    for (const cleanup of this.cleanups) cleanup();
    if (this.searchTimer) clearTimeout(this.searchTimer);
    this.el.remove();
  }

  private listen(target: EventTarget, type: string, listener: (event: Event) => void): void {
    target.addEventListener(type, listener);
    this.cleanups.push(() => target.removeEventListener(type, listener));
  }

  /** Under the header (over it, if there is more room there); in a browser without popovers, inside the grid's element. */
  private place(anchor: HTMLElement): void {
    const cell = anchor.getBoundingClientRect();
    if (floats(this.el)) return placeAt(this.el, { left: cell.left, below: cell.bottom + 4, above: cell.top - 4 });
    const root = this.host.root.getBoundingClientRect();
    const width = this.el.offsetWidth;
    const left = Math.max(0, Math.min(cell.left - root.left, root.width - width));
    this.el.style.top = `${cell.bottom - root.top + 4}px`;
    this.el.style.insetInlineStart = `${left}px`;
  }

  /** The first control of the filter (the condition, else its value), not the buttons above it; else the first button. */
  private focusFirst(): void {
    const first = this.form.isConnected ? this.form.querySelector<HTMLElement>("select, input, button") : null;
    (first ?? this.el.querySelector<HTMLElement>("button"))?.focus();
  }

  private renderFields(): void {
    const { column, current, messages } = this.host;
    const same = current && current.op === this.op;
    const n = arity(this.op);
    this.fields.replaceChildren();

    if (n === 0) return;

    if (n === "list") {
      this.renderValues();
      return;
    }

    if (column.type === "boolean") {
      const select = document.createElement("select");
      select.className = "masu-menu-input";
      select.setAttribute("aria-label", column.label);
      select.append(new Option(messages.yes ?? "Yes", "true"), new Option(messages.no ?? "No", "false"));
      if (same && current.value === false) select.value = "false";
      this.fields.appendChild(select);
      return;
    }

    // An enum of known values, by one of them (a source without "is one of").
    if (column.type === "enum" && column.values?.length) {
      const select = document.createElement("select");
      select.className = "masu-menu-input";
      select.setAttribute("aria-label", column.label);
      for (const value of column.values) {
        if (value !== null) select.appendChild(new Option(this.host.format(value), String(value)));
      }
      if (same && current.value !== undefined && current.value !== null) select.value = String(current.value);
      this.fields.appendChild(select);
      return;
    }

    const values = same ? (n === 2 ? ((current.value as unknown[]) ?? []) : [current.value]) : [];
    for (let i = 0; i < n; i++) {
      const input = document.createElement("input");
      input.className = "masu-menu-input";
      input.type = inputType(column.type);
      if (input.type === "number") input.step = "any";
      if (input.type === "datetime-local") input.step = "1";
      input.setAttribute(
        "aria-label",
        n === 2 ? (i === 0 ? (messages.from ?? "From") : (messages.to ?? "To")) : column.label,
      );
      const value = values[i];
      if (value !== undefined && value !== null) input.value = inputValue(String(value), input.type);
      this.fields.appendChild(input);
      if (n === 2 && i === 0) {
        const and = document.createElement("span");
        and.className = "masu-menu-and";
        and.textContent = messages.and ?? "and";
        this.fields.appendChild(and);
      }
    }
  }

  private renderValues(): void {
    const { messages } = this.host;
    const search = document.createElement("input");
    search.type = "search";
    search.className = "masu-menu-input masu-menu-search";
    search.placeholder = messages.search_values ?? "Search values";
    search.setAttribute("aria-label", search.placeholder);
    search.hidden = true;

    const list = document.createElement("div");
    list.className = "masu-menu-values";
    list.setAttribute("role", "group");
    list.setAttribute("aria-label", this.host.column.label);
    list.textContent = messages.loading ?? "Loading";

    search.addEventListener("input", () => {
      if (this.searchTimer) clearTimeout(this.searchTimer);
      this.searchTimer = setTimeout(() => this.loadValues(list, search.value), SEARCH_DELAY);
    });
    search.addEventListener("keydown", (event) => {
      if (event.key === "Enter") event.preventDefault();
    });

    this.fields.append(search, list);
    this.loadValues(list, null, search);
  }

  private loadValues(list: HTMLElement, text: string | null, search?: HTMLInputElement): void {
    this.host.fetchValues(text && text.trim() !== "" ? text : null, (values) => {
      if (search && values.length >= VALUE_SEARCH_FROM) {
        search.hidden = false;
        search.focus();
      }
      list.replaceChildren(
        ...values.map(([value, count]) => {
          const key = JSON.stringify(value);
          const label = document.createElement("label");
          label.className = "masu-menu-value";
          const box = document.createElement("input");
          box.type = "checkbox";
          box.dataset.value = key;
          box.checked = this.checked.has(key);
          box.addEventListener("change", () => {
            if (box.checked) this.checked.add(key);
            else this.checked.delete(key);
          });
          const name = document.createElement("span");
          name.className = "masu-menu-value-name";
          name.textContent = value === null ? (this.host.messages.empty_value ?? "(empty)") : this.host.format(value);
          const counted = document.createElement("span");
          counted.className = "masu-menu-count";
          counted.textContent = new Intl.NumberFormat().format(count);
          label.append(box, name, counted);
          return label;
        }),
      );
      if (values.length === 0) list.textContent = this.host.messages.no_values ?? "No values";
      if (!search || search.hidden) list.querySelector<HTMLInputElement>("input")?.focus();
    });
  }

  private filter(): FilterSpec | null {
    const { column } = this.host;
    const n = arity(this.op);
    if (n === "list") {
      const values = [...this.checked].map((key) => JSON.parse(key) as string);
      return makeFilter(column, this.op, values);
    }
    const inputs = [...this.fields.querySelectorAll<HTMLInputElement | HTMLSelectElement>(".masu-menu-input")];
    return makeFilter(column, this.op, inputs.map((input) => filterValue(input.value, input.type, this.host.zoned ?? true)));
  }
}

function button(text: string, type: "button" | "submit", className: string): HTMLButtonElement {
  const el = document.createElement("button");
  el.type = type;
  el.className = `masu-menu-button ${className}`;
  el.textContent = text;
  return el;
}

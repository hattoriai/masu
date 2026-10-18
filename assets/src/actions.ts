// A menu of items, as an ARIA menu: the menu of a cell (a right click,
// or the context-menu key or Shift+F10 on the active cell), with the
// grid's own items and the app's (Masu.Action). The arrow keys move
// between the items, Enter or Space runs one, a letter goes to the next
// item that starts with it; Escape, Tab or a click away closes it. An
// item may be a link (a row action's `navigate` or `patch`), which
// LiveView follows, or disabled: it stays in the menu, and does nothing.

import { floats, follow, lift, place as placeAt } from "./float";

export interface MenuItem {
  label: string;
  run(): void;
  /** A line above it: the start of another group of items. */
  separated?: boolean;
  /** For a test, or a style: `masu-menuitem-<name>`. */
  name?: string;
  /** A link (a row action's `navigate` or `patch`): LiveView follows it, and a middle click opens it in a tab. */
  href?: string;
  link?: "navigate" | "patch";
  /** Shown, not available. */
  disabled?: boolean;
  /** It destroys. */
  danger?: boolean;
}

export interface ActionMenuHost {
  /** The element the menu is placed in (positioned). */
  root: HTMLElement;
  label: string;
  /** Closes the menu; `focus` gives the focus back to the grid. */
  close(focus: boolean): void;
}

let menus = 0;

export class ActionMenu {
  readonly el: HTMLElement;
  private host: ActionMenuHost;
  private items: HTMLElement[];
  private cleanups: (() => void)[] = [];

  /** A menu at `at`, a point of the screen (a click's), or under a cell's box. */
  constructor(host: ActionMenuHost, items: MenuItem[], at: { x: number; y: number }) {
    this.host = host;
    this.el = document.createElement("div");
    this.el.className = "masu-menu masu-action-menu";
    this.el.id = `masu-action-menu-${++menus}`;
    this.el.setAttribute("role", "menu");
    this.el.setAttribute("aria-label", host.label);

    this.items = items.map((item) => {
      if (item.separated && this.el.childElementCount > 0) {
        const line = document.createElement("div");
        line.className = "masu-menu-separator";
        line.setAttribute("role", "separator");
        this.el.appendChild(line);
      }
      const button = item.href && !item.disabled ? document.createElement("a") : document.createElement("button");
      if (button instanceof HTMLAnchorElement) {
        // A LiveView link: its click is LiveView's (the menu closes after it).
        button.href = item.href!;
        button.dataset.phxLink = item.link === "patch" ? "patch" : "redirect";
        button.dataset.phxLinkState = "push";
      } else {
        (button as HTMLButtonElement).type = "button";
      }
      button.className = `masu-menuitem${item.name ? ` masu-menuitem-${item.name}` : ""}${item.danger ? " masu-danger" : ""}`;
      button.setAttribute("role", "menuitem");
      button.tabIndex = -1;
      button.textContent = item.label;
      if (item.disabled) button.setAttribute("aria-disabled", "true");
      button.addEventListener("click", (event) => {
        if (item.disabled) {
          event.preventDefault();
          return;
        }
        if (button instanceof HTMLAnchorElement) {
          setTimeout(() => host.close(false), 0);
          return;
        }
        host.close(true);
        item.run();
      });
      this.el.appendChild(button);
      return button;
    });

    this.listen(this.el, "keydown", (event) => this.onKey(event as KeyboardEvent));
    this.listen(document, "mousedown", (event) => {
      if (!this.el.contains(event.target as Node)) host.close(false);
    });

    host.root.appendChild(this.el);
    lift(this.el);
    this.place(at);
    // The point moves with the grid when the page scrolls.
    const root = host.root.getBoundingClientRect();
    const offset = { x: at.x - root.left, y: at.y - root.top };
    this.cleanups.push(
      follow(() => {
        const moved = host.root.getBoundingClientRect();
        this.place({ x: moved.left + offset.x, y: moved.top + offset.y });
      }),
    );
    this.items[0]?.focus();
  }

  destroy(): void {
    for (const cleanup of this.cleanups) cleanup();
    this.el.remove();
  }

  private listen(target: EventTarget, type: string, listener: (event: Event) => void): void {
    target.addEventListener(type, listener);
    this.cleanups.push(() => target.removeEventListener(type, listener));
  }

  /** At the point, as far as it fits; in a browser without popovers, inside the grid's element. */
  private place(at: { x: number; y: number }): void {
    if (floats(this.el)) return placeAt(this.el, { left: at.x, below: at.y, above: at.y });
    const root = this.host.root.getBoundingClientRect();
    const width = this.el.offsetWidth;
    const left = Math.max(0, Math.min(at.x - root.left, root.width - width));
    this.el.style.top = `${Math.max(0, at.y - root.top)}px`;
    this.el.style.insetInlineStart = `${left}px`;
  }

  private onKey(event: KeyboardEvent): void {
    const current = this.items.indexOf(document.activeElement as HTMLElement);
    const go = (index: number) => {
      event.preventDefault();
      const count = this.items.length;
      if (count > 0) this.items[(index + count) % count].focus();
    };

    switch (event.key) {
      case "ArrowDown":
        return go(current + 1);
      case "ArrowUp":
        return go(current < 0 ? -1 : current - 1);
      case "Home":
        return go(0);
      case "End":
        return go(-1);
      case "Escape":
        event.preventDefault();
        event.stopPropagation();
        this.host.close(true);
        return;
      case "Tab":
        event.preventDefault();
        this.host.close(true);
        return;
      case "Enter":
      case " ":
        event.preventDefault();
        this.items[current]?.click();
        return;
    }

    if (event.key.length === 1 && !event.ctrlKey && !event.metaKey && !event.altKey) {
      const letter = event.key.toLowerCase();
      const count = this.items.length;
      for (let step = 1; step <= count; step++) {
        const index = (current + step) % count;
        if (this.items[index].textContent?.toLowerCase().startsWith(letter)) return go(index);
      }
    }
  }
}

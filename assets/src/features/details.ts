// Details: the server renders the open ones (the `:detail` slot) in the
// grid's element; the browser places each under its row, in a gap of its
// height, and moves the focus into it and back.

import { setStyle } from "../dom";
import type { Gap } from "../offsets";
import type { Grid } from "../grid";

export class Details {
  /** The open details, rendered by the server (the `:detail` slot), placed under their rows. */
  detailsEl: HTMLElement | null = null;
  gaps: (Gap & { el: HTMLElement })[] = [];
  detailObserver: ResizeObserver | null = null;

  constructor(private readonly grid: Grid) {}

  /** The ids of the rows whose detail is open (as JSON). */
  openDetails(): Set<string> {
    return new Set((this.grid.config.details ?? []).map(([id]) => JSON.stringify(id)));
  }

  /** Reads the open details and their heights. */
  measureDetails(): void {
    if (!this.detailsEl) return;
    const els = new Map<string, HTMLElement>();
    for (const el of this.detailsEl.children) {
      if (el instanceof HTMLElement && el.dataset.id) els.set(el.dataset.id, el);
    }
    const before = JSON.stringify(this.gaps.map((gap) => [gap.index, gap.height]));
    const width = `${this.grid.gridEl.clientWidth}px`;
    this.gaps = (this.grid.config.details ?? [])
      .flatMap(([id, index]) => {
        const el = els.get(JSON.stringify(id));
        if (!el) return [];
        setStyle(el, "width", width);
        return [{ index, height: el.offsetHeight, el }];
      })
      .sort((a, b) => a.index - b.index);

    this.detailObserver ??= new ResizeObserver(() => {
      const heights = JSON.stringify(this.gaps.map((gap) => gap.el.offsetHeight));
      if (heights === JSON.stringify(this.gaps.map((gap) => gap.height))) return;
      this.measureDetails();
    });
    this.detailObserver.disconnect();
    for (const gap of this.gaps) this.detailObserver.observe(gap.el);
    this.observeDetailStyles();

    if (JSON.stringify(this.gaps.map((gap) => [gap.index, gap.height])) !== before) {
      for (const rowEl of this.grid.rows.values()) rowEl.masuRow = undefined;
      this.grid.render();
    }
  }

  placeDetails(headHeight: number): void {
    const rh = this.grid.config.rowHeight;
    const left = Math.abs(this.grid.gridEl.scrollLeft);
    for (const gap of this.gaps) {
      setStyle(gap.el, "transform", `translate(${left}px, ${headHeight + this.grid.rowY(gap.index) + rh}px)`);
    }
  }

  /** Each detail's style, which a render of the server takes away. */
  observeDetailStyles(): void {
    if (!this.detailsEl || !this.grid.patchObserver) return;
    for (const el of this.detailsEl.children) {
      this.grid.patchObserver.observe(el, { attributes: true, attributeFilter: ["style"] });
    }
  }

  /** Whether an event comes from a detail (which may hold a grid of its own). */
  inDetail(target: EventTarget | null): boolean {
    return this.detailsEl !== null && target instanceof Node && this.detailsEl.contains(target);
  }

  /** Opens or closes the detail of a row. */
  toggleDetail(index: number, open?: boolean): void {
    const row = this.grid.dataAt(index);
    if (!row || !this.grid.config.detail) return;
    const isOpen = this.openDetails().has(JSON.stringify(row[0]));
    const next = open ?? !isOpen;
    if (next === isOpen) return;
    this.grid.transport.push("masu:detail", { id: row[0], open: next });
    this.grid.announce(this.grid.message(next ? "detail_shown" : "detail_hidden", {}));
  }

  /** Moves the focus into the open detail of a row: its first control, or the detail. */
  focusDetail(index: number): boolean {
    const gap = this.gaps.find((g) => g.index === index);
    if (!gap) return false;
    // Not the chips of a grid in it (its Add filter): the grid, as before the filter bar.
    const target =
      [...gap.el.querySelectorAll<HTMLElement>('.masu-grid, a[href], button, input, select, textarea, [tabindex]:not([tabindex="-1"])')].find(
        (el) => !el.closest(".masu-chips"),
      ) ?? gap.el;
    if (target === gap.el) gap.el.tabIndex = -1;
    target.focus();
    return true;
  }

  /** Escape in a detail gives the focus back to its row. */
  onDetailKey(event: KeyboardEvent): void {
    if (event.key !== "Escape" || event.defaultPrevented) return;
    const gap = this.gaps.find((g) => g.el.contains(event.target as Node));
    if (!gap) return;
    event.preventDefault();
    this.grid.active = { row: gap.index, col: Math.max(0, this.grid.active.col) };
    this.grid.anchor = null;
    this.grid.gridEl.focus({ preventScroll: true });
    this.grid.ensureVisible(this.grid.active);
    this.grid.render();
  }
}

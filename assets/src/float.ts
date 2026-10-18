// Menus and panels float above the page (the popover top layer), so that
// no box around the grid that cuts its overflow cuts them: under their
// anchor, or over it when there is more room there, and inside the
// viewport. A browser without popovers keeps them in the grid's element,
// where they are absolutely placed.

const MARGIN = 4;

/** Whether `el` floats in this browser. */
export function floats(el: HTMLElement): boolean {
  return typeof el.showPopover === "function";
}

/** Shows `el`, which is in the document, in the top layer. */
export function lift(el: HTMLElement): void {
  if (!floats(el)) return;
  if (!el.hasAttribute("popover")) el.setAttribute("popover", "manual");
  if (!el.matches(":popover-open")) el.showPopover();
}

/** Takes `el` out of the top layer. */
export function drop(el: HTMLElement): void {
  if (floats(el) && el.matches(":popover-open")) el.hidePopover();
}

export interface Spot {
  /** Where its start goes, in the viewport. */
  left: number;
  /** Its top when under its anchor. */
  below: number;
  /** Its bottom when over its anchor. */
  above: number;
}

/**
 * Places a lifted `el` at `spot`: under the anchor if it fits there, else
 * on the side with more room, as high as that room. `set` sets a style
 * property.
 */
export function place(
  el: HTMLElement,
  spot: Spot,
  set: (name: string, value: string) => void = (name, value) => el.style.setProperty(name, value),
): void {
  const width = el.offsetWidth;
  const height = el.scrollHeight;
  const viewport = { width: document.documentElement.clientWidth, height: window.innerHeight };
  const roomBelow = viewport.height - spot.below - MARGIN;
  const roomAbove = spot.above - MARGIN;
  const under = height <= roomBelow || roomBelow >= roomAbove;
  const room = Math.max(under ? roomBelow : roomAbove, 0);
  const left = Math.max(MARGIN, Math.min(spot.left, viewport.width - width - MARGIN));
  const top = under ? spot.below : Math.max(MARGIN, spot.above - Math.min(height, room));

  set("left", `${left}px`);
  set("top", `${top}px`);
  set("max-height", `${room}px`);
}

/** Calls `again` when the page or a box around the anchor scrolls, or the viewport changes; returns the cleanup. */
export function follow(again: () => void): () => void {
  window.addEventListener("scroll", again, true);
  window.addEventListener("resize", again);
  return () => {
    window.removeEventListener("scroll", again, true);
    window.removeEventListener("resize", again);
  };
}

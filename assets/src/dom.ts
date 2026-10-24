// Small helpers of the DOM: writes that the patch watcher hears only when
// they change something, text of HTML, the width of a cell's text, the
// person's motion, the element that scrolls a page.

import type { CellValue } from "./types";

/** Sets a style property when it changes: the patch watcher hears every set. */
export function setStyle(el: HTMLElement, name: string, value: string): void {
  if (el.style.getPropertyValue(name) !== value) el.style.setProperty(name, value);
}

export function setAttribute(el: HTMLElement, name: string, value: string): void {
  if (el.getAttribute(name) !== value) el.setAttribute(name, value);
}

export function escapeHTML(text: string): string {
  return text.replace(/[&<>"']/g, (char) => `&#${char.charCodeAt(0)};`);
}

export function htmlText(value: CellValue): string {
  if (typeof value !== "string" || value === "") return "";
  const template = document.createElement("template");
  template.innerHTML = value;
  return (template.content.textContent ?? "").replace(/\s+/g, " ").trim();
}

let measurer: HTMLCanvasElement | null = null;

export function textWidth(cell: HTMLElement): number {
  measurer ??= document.createElement("canvas");
  const context = measurer.getContext("2d");
  if (!context) return cell.scrollWidth;
  const style = getComputedStyle(cell);
  context.font = `${style.fontStyle} ${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;
  return context.measureText(cell.textContent ?? "").width;
}

// The person's motion: the app's word for it (Issho's data-issho-motion), else the browser's setting.
export function reducedMotion(): boolean {
  const said = document.documentElement.dataset.isshoMotion;
  if (said === "reduced" || said === "full") return said === "reduced";
  return typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;
}

// The element that scrolls a grid's page: its nearest ancestor that
// scrolls, else the document's.
export function scrollParent(el: HTMLElement): Element {
  for (let node = el.parentElement; node && node !== document.body; node = node.parentElement) {
    const overflow = getComputedStyle(node).overflowY;
    if ((overflow === "auto" || overflow === "scroll") && node.scrollHeight > node.clientHeight) return node;
  }
  return document.scrollingElement ?? document.documentElement;
}

/** A value short enough for a menu's item. */
export function clip(text: string): string {
  return text.length > 40 ? `${text.slice(0, 39)}…` : text;
}

export const FOCUSABLE = 'input:not([type="hidden"]), select, textarea, button, [contenteditable="true"], [tabindex]:not([tabindex="-1"])';

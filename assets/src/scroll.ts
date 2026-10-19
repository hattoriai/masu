// A grid taller than a browser draws: Firefox draws no element taller
// than 17,895,697 pixels, Chromium and WebKit none taller than 33,554,428,
// and a million rows of 36 pixels are 36,000,000. The scroll box of such a
// grid is MAX_HEIGHT tall; the grid keeps its own place in the content,
// which the scrollbar's place gives in proportion (the ends are the ends),
// and a wheel moves by its own pixels, as in any other grid.

/** The height of the tallest scroll box: below every browser's limit, with room. */
export const MAX_HEIGHT = 10_000_000;

/** The pixels from the scrollbar's end that are its end. */
const END = 2;

/** The height of the scroll box for content `height` pixels tall. */
export function boxHeight(height: number): number {
  return Math.min(height, MAX_HEIGHT);
}

/**
 * The place in the content for the scrollbar at `scrollTop`, where the
 * box scrolls to `maxScroll` and the content to `maxContent`.
 */
export function toContent(scrollTop: number, maxScroll: number, maxContent: number): number {
  if (maxScroll <= 0) return 0;
  // Firefox stops a scroll box a pixel or two short of its end.
  if (scrollTop >= maxScroll - END) return maxContent;
  return clamp((scrollTop / maxScroll) * maxContent, 0, maxContent);
}

/** The scrollbar's place for the place `content` in the content. */
export function toScroll(content: number, maxScroll: number, maxContent: number): number {
  if (maxContent <= 0) return 0;
  return clamp((content / maxContent) * maxScroll, 0, maxScroll);
}

/**
 * A wheel's move in pixels: its `delta` is in pixels, lines (a row
 * each) or pages (a screen each), by its `deltaMode`.
 */
export function wheelPixels(delta: number, deltaMode: number, rowHeight: number, pageHeight: number): number {
  if (deltaMode === 1) return delta * rowHeight;
  if (deltaMode === 2) return delta * pageHeight;
  return delta;
}

export function clamp(value: number, min: number, max: number): number {
  return Math.min(Math.max(value, min), max);
}

import { expect, test, type Page } from "@playwright/test";
import { grid, header, openPage } from "./support";

// A column that grows (`grow`), on the Grow page: the name (200px and
// grow) takes the room that city (130), plan (120), seats (100) and active
// (90, pinned to the end) leave.

const BASE = 200 + 130 + 120 + 100 + 90;

/** The tracks the grid draws its columns at, in pixels. */
const cols = (page: Page) =>
  page.locator("#grow-content").evaluate((el) =>
    (el as HTMLElement).style.getPropertyValue("--masu-cols").split(" ").map((track) => parseFloat(track)),
  );

/** The room of the grid's box: its width, without a scrollbar. */
const room = (page: Page) => grid(page, "grow").evaluate((el) => el.clientWidth);

test.beforeEach(async ({ page }) => {
  await openPage(page, "/grow");
});

test("the column that grows takes the room the others leave: no empty room after the last", async ({ page }) => {
  const width = await room(page);
  expect(width).toBeGreaterThan(BASE);
  await expect.poll(async () => (await cols(page)).reduce((a, b) => a + b, 0)).toBe(width);
  const [name, ...others] = await cols(page);
  expect(name).toBe(width - (BASE - 200));
  expect(others).toEqual([130, 120, 100, 90]);

  // The column pinned to the end is at the grid's end; the header and the rows have the same tracks.
  const box = (await grid(page, "grow").boundingBox())!;
  const active = (await header(page, "grow", "active").boundingBox())!;
  expect(Math.abs(active.x + active.width - (box.x + width))).toBeLessThanOrEqual(1);
  const cell = (await page.locator("#grow-r0-c0").boundingBox())!;
  expect(Math.round(cell.width)).toBe(name);
  await expect(grid(page, "grow")).toHaveJSProperty("scrollWidth", width);
});

test("it follows the width of the window, down to its own width; then the grid scrolls sideways", async ({ page }) => {
  const wide = await room(page);
  await page.setViewportSize({ width: 900, height: 720 });
  await expect.poll(() => room(page)).toBeLessThan(wide);
  const width = await room(page);
  await expect.poll(async () => (await cols(page))[0]).toBe(width - (BASE - 200));

  await page.setViewportSize({ width: 500, height: 720 });
  await expect.poll(async () => (await cols(page))[0]).toBe(200);
  expect(await grid(page, "grow").evaluate((el) => el.scrollWidth > el.clientWidth)).toBe(true);
});

test("a person who resizes it gives it their width: it grows no more", async ({ page }) => {
  const resizer = header(page, "grow", "name").locator(".masu-resizer");
  const box = (await resizer.boundingBox())!;
  const before = (await cols(page))[0];
  await page.mouse.move(box.x + 4, box.y + box.height / 2);
  await page.mouse.down();
  await page.mouse.move(box.x + 4 - 100, box.y + box.height / 2, { steps: 4 });
  await page.mouse.up();
  await expect.poll(async () => (await cols(page))[0]).toBe(before - 100);

  // The room it left stays empty, and a wider window does not grow it.
  await page.setViewportSize({ width: 1400, height: 720 });
  await expect.poll(() => room(page)).toBeGreaterThan(BASE + 400);
  expect((await cols(page))[0]).toBe(before - 100);

  // Another column's width: the others keep theirs.
  const city = header(page, "grow", "city").locator(".masu-resizer");
  const cityBox = (await city.boundingBox())!;
  await page.mouse.move(cityBox.x + 4, cityBox.y + cityBox.height / 2);
  await page.mouse.down();
  await page.mouse.move(cityBox.x + 54, cityBox.y + cityBox.height / 2, { steps: 4 });
  await page.mouse.up();
  await expect.poll(async () => (await cols(page)).slice(0, 2)).toEqual([before - 100, 180]);
});

test("another column's resize takes its room from the column that grows", async ({ page }) => {
  const width = await room(page);
  const city = header(page, "grow", "city").locator(".masu-resizer");
  const box = (await city.boundingBox())!;
  await page.mouse.move(box.x + 4, box.y + box.height / 2);
  await page.mouse.down();
  await page.mouse.move(box.x + 54, box.y + box.height / 2, { steps: 4 });
  await page.mouse.up();
  await expect.poll(async () => (await cols(page)).slice(0, 2)).toEqual([width - (BASE - 200) - 50, 180]);
  await expect(grid(page, "grow")).toHaveJSProperty("scrollWidth", width);
});

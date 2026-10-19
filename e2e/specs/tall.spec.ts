import { expect, test, type Page } from "@playwright/test";
import { grid, openPage } from "./support";

// A grid taller than a browser draws an element: 100,000 rows of 360
// pixels are 36,000,000 pixels, more than Firefox (17,895,697) and
// Chromium and WebKit (33,554,428) draw.

const rows = 100_000;
// The header is a row's height too: the box has room for two rows.
const path = `/bench?rows=${rows}&row_height=360&height=1200px`;

test.describe.configure({ timeout: 120_000 });

/** The indexes (from 0) of the rows wholly on the screen, once they are real rows. */
async function shownRows(page: Page): Promise<number[]> {
  const box = grid(page, "bench");
  await expect(box.locator(".masu-row.masu-loading")).toHaveCount(0);
  return box.evaluate((el) => {
    const frame = el.getBoundingClientRect();
    const head = el.querySelector(".masu-head")!.getBoundingClientRect();
    return [...el.querySelectorAll<HTMLElement>(".masu-body .masu-row")]
      .filter((row) => {
        const rect = row.getBoundingClientRect();
        return rect.top >= head.bottom - 1 && rect.bottom <= frame.bottom + 1;
      })
      .map((row) => Number(row.getAttribute("aria-rowindex")) - 2)
      .sort((a, b) => a - b);
  });
}

test("the scrollbar at its end shows the last row", async ({ page }) => {
  await openPage(page, path);
  await grid(page, "bench").evaluate((el) => (el.scrollTop = el.scrollHeight));
  await expect.poll(async () => (await shownRows(page)).at(-1)).toBe(rows - 1);
});

test("the scrollbar in the middle shows the rows of the middle", async ({ page }) => {
  await openPage(page, path);
  await grid(page, "bench").evaluate((el) => (el.scrollTop = (el.scrollHeight - el.clientHeight) / 2));
  await expect.poll(async () => Math.abs((await shownRows(page))[0] - rows / 2)).toBeLessThan(20);
});

test("Ctrl+↓ goes to the last row", async ({ page }) => {
  await openPage(page, path);
  await page.locator("#bench .masu-row[aria-rowindex='2'] .masu-cell").first().click();
  await page.keyboard.press("ControlOrMeta+ArrowDown");
  await expect.poll(async () => (await shownRows(page)).at(-1)).toBe(rows - 1);
  await expect(page.locator("#bench .masu-cell.masu-active")).toBeVisible();
});

test("a wheel moves the rows by its pixels, not in proportion", async ({ page }) => {
  await openPage(page, path);
  const box = grid(page, "bench");
  await box.hover();
  await page.mouse.wheel(0, 720);
  // 720 pixels are two rows of 360.
  await expect.poll(async () => (await shownRows(page))[0]).toBe(2);
  await page.mouse.wheel(0, -720);
  await expect.poll(async () => (await shownRows(page))[0]).toBe(0);
});

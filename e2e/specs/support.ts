// Helpers for the browser tests.

import { expect, type Locator, type Page } from "@playwright/test";

/** Opens a page and waits for the LiveView to connect and the grid to draw its rows. */
export async function openPage(page: Page, path = "/"): Promise<void> {
  await page.goto(path);
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible();
  await expect(page.locator(".masu .masu-body .masu-row").first()).toBeVisible();
}

/** The scroll box of a grid, which has the grid role and the focus. */
export function grid(page: Page, id: string): Locator {
  return page.locator(`#${id}-grid`);
}

/** The header cell of a column. */
export function header(page: Page, id: string, key: string): Locator {
  return page.locator(`#${id} .masu-hcell[data-key="${key}"]`);
}

/** The cells of the row at `index` (from 0), as the grid shows them. */
export async function rowText(page: Page, id: string, index: number): Promise<string[]> {
  const row = page.locator(`#${id} .masu-body .masu-row[aria-rowindex="${index + 2}"]`);
  await expect(row).not.toHaveClass(/masu-loading/);
  return (await row.locator(".masu-cell").allTextContents()).map((text) => text.trim());
}

/** Waits for the grid to apply its last query. */
export async function settled(page: Page, id: string): Promise<void> {
  await expect(page.locator(`#${id}`)).not.toHaveClass(/masu-busy/);
}

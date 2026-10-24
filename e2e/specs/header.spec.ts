import { expect, test } from "@playwright/test";
import { header, openPage, rowText, settled } from "./support";

// The headers (dev.exs, /header): the filter bar, the default; the
// filters in the bar alone (header_filters={false}); and the leaner
// header of filter_bar={false}.

test.beforeEach(async ({ page }) => {
  await openPage(page, "/header");
});

test("the filter bar: Add filter lists the columns, and one picked opens its menu", async ({ page }) => {
  const add = page.locator("#bar .masu-add-filter");
  await expect(add).toHaveText("Add filter");
  await add.click();
  const panel = page.locator("#bar .masu-filters-panel");
  await expect(panel.locator(".masu-menu-item")).toHaveText(["Handle", "Title", "Slug", "Views", "Visitors"]);
  await expect(panel.locator('.masu-menu-item[data-filtered="true"]')).toHaveText(["Views"]);

  await panel.locator(".masu-menu-item", { hasText: "Title" }).click();
  await expect(panel).toHaveCount(0);
  // The column's filter alone, under Add filter.
  const menu = page.locator("#bar .masu-menu");
  await expect(menu).toHaveAttribute("aria-label", "Filter Title");
  await expect(menu.locator(".masu-menu-sort")).toHaveCount(0);
  const addBox = (await add.boundingBox())!;
  const menuBox = (await menu.boundingBox())!;
  expect(Math.abs(menuBox.y - (addBox.y + addBox.height + 4))).toBeLessThan(2);
  await menu.locator(".masu-menu-input").fill("tide");
  await menu.locator(".masu-menu-input").press("Enter");
  await settled(page, "bar");

  await expect(page.locator("#bar .masu-chip-text")).toHaveText(["Views at least 50", "Title contains tide"]);
  expect(await rowText(page, "bar", 0)).toContain("Low Tide");
  await expect(add).toBeFocused();

  // A chip opens its filter, to change it.
  await page.locator("#bar .masu-chip-text", { hasText: "Views" }).click();
  await expect(menu).toHaveAttribute("aria-label", "Filter Views");
  await expect(menu.locator(".masu-menu-input")).toHaveValue("50");
});

test("the filter bar: a header's menu sorts, and a chip takes its filter away", async ({ page }) => {
  await header(page, "bar", "visitors").hover();
  await header(page, "bar", "visitors").locator(".masu-filter-button").click();
  const menu = page.locator("#bar .masu-menu");
  await expect(menu.locator(".masu-menu-sort")).toHaveText(["Sort ascending", "Sort descending"]);
  await menu.locator(".masu-menu-sort", { hasText: "Sort ascending" }).click();
  await settled(page, "bar");
  await expect(header(page, "bar", "visitors")).toHaveAttribute("aria-sort", "ascending");
  expect((await rowText(page, "bar", 0))[4]).toBe("38");

  await page.locator("#bar .masu-chip-remove").click();
  await settled(page, "bar");
  await expect(page.locator("#bar .masu-chip")).toHaveCount(0);
  // The bar stays, with Add filter.
  await expect(page.locator("#bar .masu-add-filter")).toBeVisible();
});

test("a header of numbers keeps its label clear of its button, over its values", async ({ page }) => {
  for (const id of ["bar", "bar-only", "lean"]) {
    const cell = header(page, id, "views");
    await cell.hover();
    const label = (await cell.locator(".masu-label").boundingBox())!;
    const button = (await cell.locator(".masu-filter-button").boundingBox())!;
    expect(button.x + button.width, id).toBeLessThanOrEqual(label.x);
  }
});

test("the leaner header: a funnel on each header that filters, and no Add filter", async ({ page }) => {
  await expect(page.locator("#lean .masu-add-filter")).toHaveCount(0);
  await expect(header(page, "lean", "views").locator(".masu-filter-button")).toHaveAttribute("data-active", "true");
  await expect(header(page, "lean", "title").locator(".masu-filter-button")).toHaveAttribute("aria-label", "Filter Title");
});

test("the filters in the bar alone: a header's menu sorts, and has no filter", async ({ page }) => {
  await header(page, "bar-only", "title").hover();
  const button = header(page, "bar-only", "title").locator(".masu-filter-button");
  await expect(button).toHaveAttribute("aria-label", "Title menu");
  await button.click();
  const menu = page.locator("#bar-only .masu-menu");
  await expect(menu).toHaveAttribute("aria-label", "Title menu");
  await expect(menu.locator(".masu-menu-sort")).toHaveText(["Sort ascending", "Sort descending"]);
  await expect(menu.locator(".masu-menu-form")).toHaveCount(0);
  await page.keyboard.press("Escape");

  await page.locator("#bar-only .masu-add-filter").click();
  await page.locator("#bar-only .masu-filters-panel .masu-menu-item", { hasText: "Title" }).click();
  await expect(menu).toHaveAttribute("aria-label", "Filter Title");
  await expect(menu.locator(".masu-menu-form")).toHaveCount(1);
});

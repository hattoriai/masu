import { expect, test } from "@playwright/test";
import { header, openPage, rowText, settled } from "./support";

// A source that runs some filters only (the Some filters page: Lotus
// Web's = ≠ > < ≥ ≤ LIKE, null and not null): the menus offer those.
// Its columns: name, city (an enum), seats, signed up.

test.beforeEach(async ({ page }) => {
  await openPage(page, "/limited");
});

test("an enum without 'is one of' filters by one of its values", async ({ page }) => {
  await header(page, "limited", "city").hover();
  await header(page, "limited", "city").locator(".masu-filter-button").click();
  const menu = page.locator("#limited .masu-menu");
  const op = menu.locator(".masu-menu-op");
  await expect(op.locator("option")).toHaveText(["is", "is not", "is empty", "is not empty"]);
  await expect(menu.locator(".masu-menu-value")).toHaveCount(0);

  await menu.locator("select.masu-menu-input").selectOption("Porto");
  await menu.locator(".masu-menu-apply").click();
  await settled(page, "limited");
  await expect(page.locator("#limited .masu-chip-text")).toHaveText(["City is Porto"]);
  expect((await rowText(page, "limited", 0))[1]).toBe("Porto");
});

test("a number still has between, which Masu runs as ≥ and ≤", async ({ page }) => {
  await header(page, "limited", "seats").hover();
  await header(page, "limited", "seats").locator(".masu-filter-button").click();
  const op = page.locator("#limited .masu-menu-op");
  await expect(op.locator("option")).toHaveText([
    "is",
    "is not",
    "greater than",
    "at least",
    "less than",
    "at most",
    "between",
    "is empty",
    "is not empty",
  ]);
  await op.selectOption("between");
  await page.locator("#limited .masu-menu-input").nth(0).fill("10");
  await page.locator("#limited .masu-menu-input").nth(1).fill("12");
  await page.locator("#limited .masu-menu-input").nth(1).press("Enter");
  await settled(page, "limited");
  await expect(page.locator("#limited .masu-chip-text")).toHaveText(["Seats between 10 and 12"]);
  const seats = Number((await rowText(page, "limited", 0))[2]);
  expect(seats).toBeGreaterThanOrEqual(10);
  expect(seats).toBeLessThanOrEqual(12);
});

test("a cell's menu filters an enum by its value with 'is'", async ({ page }) => {
  const [, city] = await rowText(page, "limited", 0);
  await page.locator("#limited-r0-c1").click({ button: "right" });
  await page.locator('#limited [role="menu"]').getByRole("menuitem", { name: `Filter by ${city}`, exact: true }).click();
  await settled(page, "limited");
  await expect(page.locator("#limited .masu-chip-text")).toHaveText([`City is ${city}`]);
});

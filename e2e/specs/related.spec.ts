import { expect, test } from "@playwright/test";
import { header, openPage, rowText, settled } from "./support";

// Fields of related rows (the Related page): the customer's name and
// their company's country, one value each, and the tags, many values.

test.beforeEach(async ({ page }) => {
  await openPage(page, "/related");
});

test("a column of a related row's field sorts and filters as any other", async ({ page }) => {
  await header(page, "related", "customer.name").click();
  await settled(page, "related");
  await expect(header(page, "related", "customer.name")).toHaveAttribute("aria-sort", "ascending");
  const first = (await rowText(page, "related", 0))[2];
  const second = (await rowText(page, "related", 1))[2];
  expect(first.localeCompare(second)).toBeLessThanOrEqual(0);

  await header(page, "related", "country").hover();
  await header(page, "related", "country").locator(".masu-filter-button").click();
  const menu = page.locator("#related .masu-menu");
  await menu.locator(".masu-menu-value", { hasText: "Japan" }).locator("input").check();
  await menu.locator(".masu-menu-apply").click();
  await settled(page, "related");
  await expect(page.locator("#related .masu-chip-text")).toHaveText(["Country is one of Japan"]);
  expect((await rowText(page, "related", 0))[3]).toBe("Japan");
});

test("a column of many values shows them apart, filters by has any, all or none of, and does not sort", async ({ page }) => {
  const tags = header(page, "related", "tags");
  expect(await tags.getAttribute("aria-sort")).toBeNull();

  await tags.hover();
  await tags.locator(".masu-filter-button").click();
  const menu = page.locator("#related .masu-menu");
  await expect(menu.locator(".masu-menu-op option")).toHaveText(["has any of", "has all of", "has none of", "has none", "has some"]);
  await expect(menu.locator(".masu-menu-group")).toHaveCount(0);

  await menu.locator(".masu-menu-op").selectOption("all_of");
  await menu.locator(".masu-menu-value", { hasText: "gift" }).locator("input").check();
  await menu.locator(".masu-menu-value", { hasText: "bulk" }).locator("input").check();
  await menu.locator(".masu-menu-apply").click();
  await settled(page, "related");

  const chip = await page.locator("#related .masu-chip-text").textContent();
  expect(chip).toMatch(/^Tags has all of (gift, bulk|bulk, gift)$/);
  const cell = (await rowText(page, "related", 0))[4];
  expect(cell.split(", ")).toEqual(expect.arrayContaining(["gift", "bulk"]));
});

test("a cell's menu of many values filters by none or some", async ({ page }) => {
  await page.locator("#related-r0-c4").click({ button: "right" });
  const menu = page.locator('#related [role="menu"]');
  await expect(menu.getByRole("menuitem", { name: "Filter by none", exact: true })).toBeVisible();
  await menu.getByRole("menuitem", { name: "Filter by none", exact: true }).click();
  await settled(page, "related");
  await expect(page.locator("#related .masu-chip-text")).toHaveText(["Tags has none"]);
  expect((await rowText(page, "related", 0))[4]).toBe("");
});

import { expect, test } from "@playwright/test";
import { header, openPage, rowText, settled } from "./support";

// A query tool's results (the Results page): column names and rows as
// lists of values, of no types. The grid learns each column's type.

test.beforeEach(async ({ page }) => {
  await openPage(page, "/results");
});

test("each column shows as the type of its values", async ({ page }) => {
  await expect(page.locator("#results .masu-hcell .masu-label")).toHaveText([
    "Id",
    "Name",
    "City",
    "Plan",
    "Seats",
    "Revenue",
    "Active",
    "Signed up",
    "Last seen",
  ]);
  const cells = await rowText(page, "results", 13);
  expect(cells[0]).toBe("14");
  expect(cells[5]).toBe("1,108.66");
  expect(cells[6]).toBe("✓");
  expect(cells[7]).toMatch(/^\d{1,2} [A-Z][a-z]{2} \d{4}$/);
  await expect(header(page, "results", "revenue")).toHaveClass(/masu-align-end/);

  // A number's filters, not text's.
  await header(page, "results", "seats").hover();
  await header(page, "results", "seats").locator(".masu-filter-button").click();
  await expect(page.locator("#results .masu-menu-op option", { hasText: "between" })).toHaveCount(1);
  await expect(page.locator("#results .masu-menu-op option", { hasText: "contains" })).toHaveCount(0);
});

test("another query brings other columns; the view keeps what is of those there still", async ({ page }) => {
  await header(page, "results", "seats").click();
  await settled(page, "results");
  await header(page, "results", "city").hover();
  await header(page, "results", "city").locator(".masu-filter-button").click();
  await page.locator("#results .masu-menu-input").fill("o");
  await page.locator("#results .masu-menu-input").press("Enter");
  await settled(page, "results");
  await expect(page.locator("#results .masu-chip-text")).toHaveText(["City contains o"]);

  await page.locator("#run select").selectOption("plans");
  await expect(page.locator("#results .masu-hcell .masu-label")).toHaveText(["Plan", "Customers", "Revenue", "Seats"]);
  await expect(page.locator("#results .masu-chip")).toHaveCount(0);
  await expect(page.locator("#results .masu-status")).toHaveText("Part of this view no longer applies: city");
  await expect(header(page, "results", "seats")).toHaveAttribute("aria-sort", "ascending");
  const first = Number((await rowText(page, "results", 0))[3]);
  const second = Number((await rowText(page, "results", 1))[3]);
  expect(first).toBeLessThanOrEqual(second);
});

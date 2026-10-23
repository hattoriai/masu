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

test.describe("in a browser far from UTC", () => {
  test.use({ timezoneId: "Asia/Tokyo" });

  test("a datetime without a zone filters as the cells show it, not moved to the browser's time", async ({ page }) => {
    await page.locator("#run select").selectOption("logins");
    await expect(page.locator("#results .masu-hcell .masu-label")).toHaveText(["Id", "Name", "Logged in at"]);

    // "14 Mar 2026, 05:12": as written, in no zone.
    const [id, , shown] = await rowText(page, "results", 0);
    const [, day, mon, year, hour, minute] = shown.match(/^(\d{1,2}) ([A-Z][a-z]{2}) (\d{4}), (\d{2}):(\d{2})$/)!;
    const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    const date = `${year}-${String(months.indexOf(mon) + 1).padStart(2, "0")}-${day.padStart(2, "0")}T${hour}:${minute}`;

    await header(page, "results", "logged_in_at").hover();
    await header(page, "results", "logged_in_at").locator(".masu-filter-button").click();
    const menu = page.locator("#results .masu-menu");
    await menu.locator(".masu-menu-op").selectOption("between");
    const next = new Date(new Date(`${date}Z`).getTime() + 60_000).toISOString().slice(0, 16);
    await menu.locator(".masu-menu-input").nth(0).fill(date);
    await menu.locator(".masu-menu-input").nth(1).fill(next);
    await menu.locator(".masu-menu-apply").click();
    await settled(page, "results");

    expect((await rowText(page, "results", 0))[0]).toBe(id);
    expect((await rowText(page, "results", 0))[2]).toBe(shown);
  });
});

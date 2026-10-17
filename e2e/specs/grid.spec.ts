import { expect, test } from "@playwright/test";
import { grid, header, openPage, rowText, settled } from "./support";

test.describe("a grid of a hundred thousand rows", () => {
  test.beforeEach(async ({ page }) => {
    await openPage(page, "/");
  });

  test("draws only the rows on the screen, with the count for a screen reader", async ({ page }) => {
    await expect(grid(page, "customers")).toHaveAttribute("aria-rowcount", "100001");
    const drawn = await page.locator("#customers .masu-body .masu-row").count();
    expect(drawn).toBeGreaterThan(10);
    expect(drawn).toBeLessThan(60);
    expect((await rowText(page, "customers", 0)).slice(0, 2)).toEqual(["1", "Ken Torvalds"]);
  });

  test("scrolls to any row, and asks the server for the rows it lacks", async ({ page }) => {
    await grid(page, "customers").evaluate((el) => (el.scrollTop = el.scrollHeight));
    expect((await rowText(page, "customers", 99_999))[0]).toBe("100,000");

    await grid(page, "customers").evaluate((el) => (el.scrollTop = 36 * 50_000));
    expect((await rowText(page, "customers", 50_005))[0]).toBe("50,006");
  });

  test("formats numbers, decimals, dates and booleans in the locale", async ({ page }) => {
    const cells = await rowText(page, "customers", 13);
    expect(cells[5]).toBe("19");
    expect(cells[6]).toBe("1,108.66");
    expect(cells[7]).toBe("✓");
    expect(cells[8]).toMatch(/^\d{1,2} [A-Z][a-z]{2} \d{4}$/);
  });

  test("a click on a header sorts, a second click turns the order, Shift adds a column", async ({ page }) => {
    const revenue = header(page, "customers", "revenue");
    await revenue.click();
    await revenue.click();
    await settled(page, "customers");
    await expect(revenue).toHaveAttribute("aria-sort", "descending");
    expect((await rowText(page, "customers", 0))[6]).toBe("9,999.49");

    await header(page, "customers", "plan").click();
    await header(page, "customers", "seats").click({ modifiers: ["Shift"] });
    await settled(page, "customers");
    await expect(header(page, "customers", "plan")).toHaveAttribute("aria-sort", "ascending");
    await expect(header(page, "customers", "seats").locator(".masu-sort")).toHaveText("2");
    const [first, second] = [await rowText(page, "customers", 0), await rowText(page, "customers", 1)];
    expect([first[4], second[4]]).toEqual(["business", "business"]);
    expect(Number(first[5])).toBeLessThanOrEqual(Number(second[5]));
  });

  test("searches as the person types, and says how many rows it found", async ({ page }) => {
    await page.locator("#customers .masu-search").fill("kraków");
    await expect(grid(page, "customers")).toHaveAttribute("aria-rowcount", "9413");
    await expect(page.locator("#customers .masu-status")).toHaveText("9,412 rows");
    expect((await rowText(page, "customers", 0))[3]).toBe("Kraków");

    await page.locator("#customers .masu-search").fill("no such customer");
    await expect(page.locator("#customers .masu-empty")).toBeVisible();
    await expect(page.locator("#customers .masu-empty")).toHaveText("No rows");
  });

  test("the keyboard moves the active cell, which a screen reader follows", async ({ page }) => {
    await grid(page, "customers").focus();
    await page.keyboard.press("ArrowRight");
    await page.keyboard.press("ArrowDown");
    await expect(grid(page, "customers")).toHaveAttribute("aria-activedescendant", "customers-r1-c1");
    await expect(page.locator("#customers-r1-c1")).toHaveClass(/masu-active/);

    await page.keyboard.press("Control+End");
    await expect(grid(page, "customers")).toHaveAttribute("aria-activedescendant", "customers-r99999-c9");

    await page.keyboard.press("Control+Home");
    await page.keyboard.press("ArrowUp");
    await expect(grid(page, "customers")).toHaveAttribute("aria-activedescendant", "customers-h0");
    await page.keyboard.press("Enter");
    await settled(page, "customers");
    await expect(header(page, "customers", "id")).toHaveAttribute("aria-sort", "ascending");
  });

  test("Shift with the arrows selects a range, and copy gives tab-separated values", async ({ page, context, browserName }) => {
    test.skip(browserName !== "chromium", "only Chromium lets a test read the clipboard");
    await context.grantPermissions(["clipboard-read", "clipboard-write"]);
    await grid(page, "customers").focus();
    await page.keyboard.press("ArrowRight");
    await page.keyboard.press("Shift+ArrowRight");
    await page.keyboard.press("Shift+ArrowDown");
    await expect(page.locator("#customers .masu-selected")).toHaveCount(4);

    await page.keyboard.press("ControlOrMeta+c");
    await expect
      .poll(() => page.evaluate(() => navigator.clipboard.readText()))
      .toBe("Ken Torvalds\tken.torvalds1@example.com\nKatherine Hamilton\tkatherine.hamilton2@example.com");
    await expect(page.locator("#customers .masu-status")).toHaveText("2 rows copied");
  });

  test("dragging the edge of a header resizes its column, a double click fits it", async ({ page }) => {
    const resizer = header(page, "customers", "name").locator(".masu-resizer");
    const box = (await resizer.boundingBox())!;
    await page.mouse.move(box.x + 4, box.y + box.height / 2);
    await page.mouse.down();
    await page.mouse.move(box.x + 104, box.y + box.height / 2, { steps: 4 });
    await page.mouse.up();
    const cols = () => grid(page, "customers").evaluate((el) => el.style.getPropertyValue("--masu-cols").split(" "));
    expect((await cols())[1]).toBe("290px");

    await resizer.dblclick();
    const fitted = parseInt((await cols())[1], 10);
    expect(fitted).toBeGreaterThan(100);
    expect(fitted).toBeLessThan(290);
  });
});

test("a small grid takes the place of a plain table", async ({ page }) => {
  await openPage(page, "/small");
  await expect(grid(page, "small")).toHaveAttribute("aria-rowcount", "9");
  await expect(page.locator("#small .masu-body .masu-row")).toHaveCount(8);
  expect(await rowText(page, "small", 7)).toEqual(["Anita Liskov", "anita.liskov8@example.com"]);
});

test.describe("live rows", () => {
  test("a row that changes on the topic flashes, and the person keeps their place", async ({ page }) => {
    await openPage(page, "/live");
    await expect(grid(page, "quotes")).toHaveAttribute("aria-rowcount", "2001");
    await expect(page.locator("#quotes .masu-changed").first()).toBeAttached({ timeout: 10_000 });

    await grid(page, "quotes").evaluate((el) => (el.scrollTop = 36 * 600));
    const before = await grid(page, "quotes").evaluate((el) => el.scrollTop);
    await expect(page.locator("#quotes .masu-changed").first()).toBeAttached({ timeout: 10_000 });
    expect(await grid(page, "quotes").evaluate((el) => el.scrollTop)).toBe(before);
    await expect(grid(page, "quotes")).toHaveAttribute("aria-rowcount", "2001");
  });

  test("a sorted grid stays sorted as the rows change", async ({ page }) => {
    await openPage(page, "/live");
    const price = header(page, "quotes", "price");
    await price.click();
    await price.click();
    await settled(page, "quotes");
    await expect(page.locator("#quotes .masu-changed").first()).toBeAttached({ timeout: 10_000 });
    const top = await Promise.all([0, 1, 2, 3, 4].map(async (i) => Number((await rowText(page, "quotes", i))[1].replace(/,/g, ""))));
    expect([...top].sort((a, b) => b - a)).toEqual(top);
  });
});

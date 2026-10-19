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
    const cols = () => page.locator("#customers-content").evaluate((el) => (el as HTMLElement).style.getPropertyValue("--masu-cols").split(" "));
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

test.describe("the filter menu", () => {
  test.beforeEach(async ({ page }) => {
    await openPage(page, "/");
  });

  test("an enum lists its values with their counts, and filters by the ones ticked", async ({ page }) => {
    await header(page, "customers", "plan").hover();
    await header(page, "customers", "plan").locator(".masu-filter-button").click();
    const menu = page.locator("#customers .masu-menu");
    await expect(menu).toHaveAttribute("role", "dialog");
    await expect(menu.locator(".masu-menu-value")).toHaveCount(5);
    await expect(menu.locator(".masu-menu-value", { hasText: "team" }).locator(".masu-menu-count")).toHaveText("20,000");

    await menu.locator(".masu-menu-value", { hasText: "team" }).click();
    await menu.locator(".masu-menu-value", { hasText: "free" }).click();
    await menu.locator(".masu-menu-apply").click();
    await settled(page, "customers");

    await expect(menu).toHaveCount(0);
    await expect(grid(page, "customers")).toHaveAttribute("aria-rowcount", "40001");
    await expect(page.locator("#customers .masu-chip-text")).toHaveText(["Plan is one of team, free"]);
    await expect(header(page, "customers", "plan").locator(".masu-filter-button")).toHaveAttribute("data-active", "true");
  });

  test("a number takes a range, and the chips take the filters away", async ({ page }) => {
    await header(page, "customers", "seats").hover();
    await header(page, "customers", "seats").locator(".masu-filter-button").click();
    await page.locator("#customers .masu-menu-op").selectOption("between");
    await page.locator("#customers .masu-menu-input").nth(0).fill("10");
    await page.locator("#customers .masu-menu-input").nth(1).fill("20");
    await page.locator("#customers .masu-menu-input").nth(1).press("Enter");
    await settled(page, "customers");

    await expect(page.locator("#customers .masu-chip-text")).toHaveText(["Seats between 10 and 20"]);
    const seats = Number((await rowText(page, "customers", 0))[5]);
    expect(seats).toBeGreaterThanOrEqual(10);
    expect(seats).toBeLessThanOrEqual(20);

    await page.locator("#customers .masu-chip-remove").click();
    await settled(page, "customers");
    await expect(page.locator("#customers .masu-chip")).toHaveCount(0);
    await expect(grid(page, "customers")).toHaveAttribute("aria-rowcount", "100001");
  });

  test("Alt+↓ on a header opens its menu, Escape gives the focus back", async ({ page }) => {
    await grid(page, "customers").focus();
    await page.keyboard.press("ArrowUp");
    await page.keyboard.press("ArrowRight");
    await page.keyboard.press("ArrowRight");
    await page.keyboard.press("ArrowRight");
    await page.keyboard.press("Alt+ArrowDown");
    await expect(page.locator("#customers .masu-menu")).toHaveAttribute("aria-label", "Filter City");
    await expect(page.locator("#customers .masu-menu-op")).toBeFocused();

    await page.locator("#customers .masu-menu-op").selectOption("is_nil");
    await page.locator("#customers .masu-menu-apply").press("Enter");
    await settled(page, "customers");
    await expect(page.locator("#customers .masu-chip-text")).toHaveText(["City is empty"]);
    await expect(grid(page, "customers")).toHaveAttribute("aria-rowcount", "5883");

    await page.keyboard.press("Alt+ArrowDown");
    await page.keyboard.press("Escape");
    await expect(page.locator("#customers .masu-menu")).toHaveCount(0);
    await expect(grid(page, "customers")).toBeFocused();
  });
});

test.describe("editing", () => {
  test.beforeEach(async ({ page }) => {
    await openPage(page, "/");
  });

  const cell = (page: import("@playwright/test").Page, row: number, col: number) => page.locator(`#customers-r${row}-c${col}`);

  test("typing on a cell edits it, Enter saves and moves down", async ({ page }) => {
    await cell(page, 0, 1).click();
    await page.keyboard.type("Rui Freitas");
    await expect(page.locator("#customers .masu-editor")).toHaveValue("Rui Freitas");
    await page.keyboard.press("Enter");

    await expect(cell(page, 0, 1)).toHaveText("Rui Freitas");
    await expect(page.locator("#customers .masu-editor")).toHaveCount(0);
    await expect(grid(page, "customers")).toHaveAttribute("aria-activedescendant", "customers-r1-c1");
    await expect(grid(page, "customers")).toBeFocused();
  });

  test("the changeset's error goes on the cell, with the old value", async ({ page }) => {
    await cell(page, 1, 5).click();
    await page.keyboard.press("Enter");
    await page.locator("#customers .masu-editor").fill("0");
    await page.keyboard.press("Enter");

    await expect(cell(page, 1, 5)).toHaveAttribute("aria-invalid", "true");
    await expect(cell(page, 1, 5)).toHaveAttribute("title", "must be greater than 0");
    await expect(cell(page, 1, 5)).toHaveText("75");
    await expect(page.locator("#customers .masu-status")).toHaveText("Seats: must be greater than 0");
  });

  test("Escape gives up, and undo and redo take an edit back and again", async ({ page }) => {
    await cell(page, 2, 1).dblclick();
    await page.keyboard.type(" Jr");
    await page.keyboard.press("Escape");
    await expect(cell(page, 2, 1)).toHaveText("Alan Matsumoto");

    await cell(page, 2, 1).click();
    await page.keyboard.type("Grace");
    await page.keyboard.press("Tab");
    await expect(cell(page, 2, 1)).toHaveText("Grace");
    await expect(grid(page, "customers")).toHaveAttribute("aria-activedescendant", "customers-r2-c2");

    await page.keyboard.press("ControlOrMeta+z");
    await expect(cell(page, 2, 1)).toHaveText("Alan Matsumoto");
    await page.keyboard.press("ControlOrMeta+Shift+z");
    await expect(cell(page, 2, 1)).toHaveText("Grace");
  });

  test("Space turns a boolean, and Delete empties the cells of a range", async ({ page }) => {
    await cell(page, 0, 7).click();
    await page.keyboard.press("Space");
    await expect(cell(page, 0, 7)).toHaveText("");
    await page.keyboard.press("Space");
    await expect(cell(page, 0, 7)).toHaveText("✓");

    await cell(page, 0, 3).click();
    await page.keyboard.press("Shift+ArrowDown");
    await page.keyboard.press("Delete");
    await expect(cell(page, 0, 3)).toHaveText("");
    await expect(cell(page, 1, 3)).toHaveText("");
  });

  test("a paste from a spreadsheet fills the cells from the active one", async ({ page, context, browserName }) => {
    test.skip(browserName !== "chromium", "only Chromium lets a test write the clipboard");
    await context.grantPermissions(["clipboard-read", "clipboard-write"]);
    await cell(page, 5, 3).click();
    await page.evaluate(() => navigator.clipboard.writeText("Porto\tteam\nFaro\tnot a plan"));
    await page.keyboard.press("ControlOrMeta+v");

    await expect(cell(page, 5, 3)).toHaveText("Porto");
    await expect(cell(page, 5, 4)).toHaveText("team");
    await expect(cell(page, 6, 4)).toHaveAttribute("aria-invalid", "true");
    await expect(cell(page, 6, 3)).toHaveAttribute("title", "Not saved: the row has an error.");
    await expect(cell(page, 6, 3)).toHaveText("Porto");
  });

  test("Ctrl+D fills a range down with its first row", async ({ page }) => {
    await cell(page, 5, 5).click();
    await page.keyboard.press("Shift+ArrowDown");
    await page.keyboard.press("Shift+ArrowDown");
    await page.keyboard.press("ControlOrMeta+d");
    await expect(cell(page, 6, 5)).toHaveText("223");
    await expect(cell(page, 7, 5)).toHaveText("223");
  });

  test("a row or a cell that its state makes read-only does not edit", async ({ page }) => {
    // Row 4 (Radia) is on the enterprise plan: the whole row is read-only.
    await expect(cell(page, 3, 1)).toHaveClass(/masu-locked/);
    await cell(page, 3, 1).click();
    await page.keyboard.type("X");
    await expect(page.locator("#customers .masu-editor")).toHaveCount(0);
    await expect(cell(page, 3, 1)).toHaveText("Radia Berners-Lee");

    // Row 5 (Dennis) is not active: his revenue is read-only, his name is not.
    await expect(cell(page, 4, 6)).toHaveAttribute("aria-readonly", "true");
    await expect(cell(page, 4, 1)).toHaveAttribute("aria-readonly", "false");
    await cell(page, 4, 6).dblclick();
    await expect(page.locator("#customers .masu-editor")).toHaveCount(0);
  });

  test("a column with editable={false} does not edit", async ({ page }) => {
    await cell(page, 0, 0).click();
    await page.keyboard.type("9");
    await expect(page.locator("#customers .masu-editor")).toHaveCount(0);
    await expect(cell(page, 0, 0)).toHaveText("1");
  });
});

test.describe("two people", () => {
  // Without presence, nothing stops Ada from editing the cell Alan types
  // in: the server's compare-and-swap is what refuses his stale edit.
  test("an edit shows in the other browser, and an edit of a cell changed meanwhile is refused", async ({ browser }) => {
    const room = `conflict-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const ada = await (await browser.newContext({ locale: "en-GB" })).newPage();
    const alan = await (await browser.newContext({ locale: "en-GB" })).newPage();
    await openPage(ada, `/together?as=Ada&room=${room}&presence=0`);
    await openPage(alan, `/together?as=Alan&room=${room}&presence=0`);
    const cell = (page: import("@playwright/test").Page, row: number, col: number) => page.locator(`#together-r${row}-c${col}`);

    // Alan starts to type in Ken's name; Ada saves it first.
    await cell(alan, 0, 1).click();
    await alan.keyboard.type("Alan's Ken");
    await cell(ada, 0, 1).click();
    await ada.keyboard.type("Ada's Ken");
    await ada.keyboard.press("Enter");
    await expect(cell(ada, 0, 1)).toHaveText("Ada's Ken");

    await alan.keyboard.press("Enter");
    await expect(cell(alan, 0, 1)).toHaveAttribute("title", "Changed by Ada meanwhile.");
    await expect(cell(alan, 0, 1)).toHaveText("Ada's Ken");

    // A cell of the same row that no one else changed is saved, and shows
    // in Ada's browser.
    await cell(alan, 0, 2).click();
    await alan.keyboard.type("Faro");
    await alan.keyboard.press("Enter");
    await expect(cell(ada, 0, 2)).toHaveText("Faro");
    await expect(cell(ada, 0, 1)).toHaveText("Ada's Ken");

    await ada.context().close();
    await alan.context().close();
  });
});

test.describe("presence", () => {
  test("each person sees the others, where they are, what they type, and what they save", async ({ browser }) => {
    const room = `presence-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const open = async (name: string) => {
      const page = await (await browser.newContext({ locale: "en-GB" })).newPage();
      await openPage(page, `/together?as=${name}&room=${room}`);
      return page;
    };
    const ada = await open("Ada");
    const alan = await open("Alan");

    await expect(ada.locator("#together .masu-person")).toHaveAttribute("title", "Alan");
    await expect(alan.locator("#together .masu-person")).toHaveAttribute("title", "Ada");

    await alan.locator("#together-r2-c1").click();
    await expect(ada.locator("#together .masu-peer .masu-peer-label")).toHaveText("Alan");

    await alan.keyboard.type("Al");
    await expect(ada.locator("#together .masu-peer-editing .masu-peer-label")).toHaveText("Alan is typing");

    await ada.locator("#together-r2-c1").dblclick();
    await expect(ada.locator("#together .masu-editor")).toHaveCount(0);
    await expect(ada.locator("#together .masu-status")).toHaveText("Alan is editing this cell");

    await alan.keyboard.press("Enter");
    const color = await ada.locator("#together .masu-person").evaluate((el) => (el as HTMLElement).style.getPropertyValue("--masu-peer-color"));
    const flashed = ada.locator("#together .masu-changed");
    await expect(flashed.first()).toBeAttached();
    expect(await flashed.first().evaluate((el) => (el as HTMLElement).style.getPropertyValue("--masu-flash"))).toBe(color);

    await alan.context().close();
    await expect(ada.locator("#together .masu-person")).toHaveCount(0);
    await ada.context().close();
  });

  const twoPeople = async (browser: import("@playwright/test").Browser, prefix: string, alanParams = "") => {
    const room = `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const open = async (name: string, params: string) => {
      const page = await (await browser.newContext({ locale: "en-GB" })).newPage();
      await openPage(page, `/together?as=${name}&room=${room}&rows=300${params}`);
      return page;
    };
    return { ada: await open("Ada", ""), alan: await open("Alan", alanParams) };
  };
  const scrollTop = (page: import("@playwright/test").Page) => grid(page, "together").evaluate((el) => el.scrollTop);

  test("a click on an avatar shows that person's view and place; Stop brings back one's own", async ({ browser }) => {
    const { ada, alan } = await twoPeople(browser, "follow");

    // Ada reads a little way down, in her own order.
    await ada.locator("#together-r0-c1").click();
    await ada.keyboard.press("PageDown");
    await ada.keyboard.press("PageDown");
    const adaTop = await scrollTop(ada);
    expect(adaTop).toBeGreaterThan(0);

    // Alan turns the order and reads further down.
    await header(alan, "together", "id").click();
    await header(alan, "together", "id").click();
    await settled(alan, "together");
    await alan.locator("#together-r0-c1").click();
    for (let i = 0; i < 5; i++) await alan.keyboard.press("PageDown");

    const avatar = ada.locator("#together .masu-person");
    await avatar.click();
    await expect(avatar).toHaveAttribute("aria-pressed", "true");
    await expect(ada.locator("#together .masu-following")).toContainText("Following Alan");
    await expect(header(ada, "together", "id")).toHaveAttribute("aria-sort", "descending");
    await expect.poll(async () => Math.abs((await scrollTop(ada)) - (await scrollTop(alan)))).toBeLessThan(40);
    await expect(ada.locator("#together .masu-peer .masu-peer-label")).toHaveText("Alan");

    // Alan moves on; Ada's grid goes with him.
    await alan.keyboard.press("Control+Home");
    await expect.poll(() => scrollTop(ada)).toBe(0);

    await ada.locator("#together .masu-following-stop").click();
    await expect(ada.locator("#together .masu-following")).toHaveCount(0);
    await expect(header(ada, "together", "id")).toHaveAttribute("aria-sort", "none");
    await expect.poll(() => scrollTop(ada)).toBe(adaTop);
    await expect(avatar).toHaveAttribute("aria-pressed", "false");

    await ada.context().close();
    await alan.context().close();
  });

  test("scrolling while following keeps that person's view, with a way back", async ({ browser }) => {
    const { ada, alan } = await twoPeople(browser, "takeover");
    await alan.locator(".masu-search").fill("an");
    await settled(alan, "together");
    await alan.locator("#together-r0-c1").click();

    await ada.locator("#together .masu-person").click();
    await expect(ada.locator(".masu-search")).toHaveValue("an");

    await grid(ada, "together").hover();
    await ada.mouse.wheel(0, 300);
    await expect(ada.locator("#together .masu-following")).toContainText("Alan's view");
    await expect(ada.locator(".masu-search")).toHaveValue("an");
    await expect(ada.locator("#together .masu-person")).toHaveAttribute("aria-pressed", "false");

    await ada.getByRole("button", { name: "Back to your view" }).click();
    await expect(ada.locator(".masu-search")).toHaveValue("");
    await expect(ada.locator("#together .masu-following")).toHaveCount(0);

    await ada.context().close();
    await alan.context().close();
  });

  test("a person whose grid keeps its view is followed in one's own order", async ({ browser }) => {
    const { ada, alan } = await twoPeople(browser, "private", "&share=0");

    // Alan turns the order: his first row is the last of Ada's.
    await header(alan, "together", "id").click();
    await header(alan, "together", "id").click();
    await settled(alan, "together");
    await alan.locator("#together-r0-c1").click();

    await ada.locator("#together .masu-person").click();
    await expect(ada.locator("#together .masu-following")).toContainText("Following Alan");
    await expect(header(ada, "together", "id")).toHaveAttribute("aria-sort", "none");
    await expect(ada.locator("#together-r299-c1")).toBeInViewport();

    await alan.keyboard.press("Control+End");
    await expect(ada.locator("#together-r0-c5")).toBeInViewport();

    await ada.context().close();
    await alan.context().close();
  });

  test("each person sees the range the others selected", async ({ browser }) => {
    const room = `range-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const open = async (name: string) => {
      const page = await (await browser.newContext({ locale: "en-GB" })).newPage();
      await openPage(page, `/together?as=${name}&room=${room}`);
      return page;
    };
    const ada = await open("Ada");
    const alan = await open("Alan");

    await alan.locator("#together-r1-c1").click();
    await alan.keyboard.press("Shift+ArrowDown");
    await alan.keyboard.press("Shift+ArrowDown");
    await alan.keyboard.press("Shift+ArrowRight");
    await expect(ada.locator("#together .masu-peer-range")).toHaveCount(3);

    await alan.keyboard.press("ArrowUp");
    await expect(ada.locator("#together .masu-peer-range")).toHaveCount(0);

    await ada.context().close();
    await alan.context().close();
  });
});

test.describe("layout and views", () => {
  const person = (name: string) => `${name}-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`;
  const headers = (page: import("@playwright/test").Page) => page.locator("#views .masu-hcell .masu-label").allTextContents();

  test("pinned columns stay in place while the others scroll sideways", async ({ page }) => {
    await page.setViewportSize({ width: 900, height: 760 });
    await openPage(page, `/views?as=${person("ada")}`);
    const id = page.locator("#views-r0-c0");
    const city = page.locator("#views-r0-c2");
    const revenue = page.locator('#views .masu-hcell[data-key="revenue"]');
    const before = (await id.boundingBox())!.x;
    const cityBefore = (await city.boundingBox())!.x;
    const gridBox = (await grid(page, "views").boundingBox())!;

    await grid(page, "views").evaluate((el) => (el.scrollLeft = 300));
    await expect.poll(async () => (await city.boundingBox())!.x).toBeLessThan(cityBefore - 200);
    expect((await id.boundingBox())!.x).toBe(before);
    const end = (await revenue.boundingBox())!;
    expect(Math.abs(end.x + end.width - (gridBox.x + gridBox.width))).toBeLessThan(4);
    await expect(id).toHaveClass(/masu-pinned-start/);
  });

  test("a selected cell of a pinned column shows the selection on every second row too", async ({ page }) => {
    await openPage(page, `/views?as=${person("ada")}`);
    const odd = page.locator("#views-r0-c0");
    const even = page.locator("#views-r1-c0");
    await odd.click();
    await page.keyboard.press("Shift+ArrowDown");
    await expect(even).toHaveClass(/masu-selected/);
    await page.mouse.move(0, 0);
    const image = (cell: typeof odd) => cell.evaluate((el) => getComputedStyle(el).backgroundImage);
    expect(await image(even)).toBe(await image(odd));
  });

  test("a drag on a header moves its column, and Alt+Shift+→ on a header too", async ({ page }) => {
    await openPage(page, `/views?as=${person("ada")}`);
    const plan = (await page.locator('#views .masu-hcell[data-key="plan"] .masu-label').boundingBox())!;
    const city = (await header(page, "views", "city").boundingBox())!;
    await page.mouse.move(plan.x + 5, plan.y + 5);
    await page.mouse.down();
    await page.mouse.move(city.x + 10, city.y + 10, { steps: 6 });
    await expect(page.locator("#views .masu-drop")).toBeVisible();
    await page.mouse.up();

    await expect.poll(() => headers(page)).toEqual(["ID", "Name", "Plan", "City", "Seats", "Active", "Signed up", "Last seen", "Revenue"]);
    expect(await rowText(page, "views", 0)).toEqual(expect.arrayContaining(["1", "Ken Torvalds"]));
    // The drag did not sort.
    await expect(header(page, "views", "plan")).toHaveAttribute("aria-sort", "none");

    await page.locator("#views-r0-c2").click();
    await page.keyboard.press("ArrowUp");
    await page.keyboard.press("Alt+Shift+ArrowRight");
    await expect.poll(() => headers(page)).toEqual(["ID", "Name", "City", "Plan", "Seats", "Active", "Signed up", "Last seen", "Revenue"]);
    await expect(page.locator("#views .masu-status")).toHaveText("Plan moved");
  });

  test("the columns menu hides, shows, pins and moves columns", async ({ page }) => {
    await openPage(page, `/views?as=${person("ada")}`);
    await page.getByRole("button", { name: "Columns" }).click();
    const menu = page.getByRole("dialog", { name: "Columns" });

    await menu.getByRole("checkbox", { name: "Seats" }).uncheck();
    await menu.getByRole("checkbox", { name: "Email" }).check();
    await expect.poll(() => headers(page)).toEqual(["ID", "Name", "Email", "City", "Plan", "Active", "Signed up", "Last seen", "Revenue"]);

    await menu.getByRole("combobox", { name: "Pin City" }).selectOption("start");
    await expect(header(page, "views", "city")).toHaveClass(/masu-pinned-start/);
    await expect.poll(() => headers(page)).toEqual(["ID", "Name", "City", "Email", "Plan", "Active", "Signed up", "Last seen", "Revenue"]);

    await menu.getByRole("button", { name: "Move Active up" }).click();
    await expect.poll(() => headers(page)).toEqual(["ID", "Name", "City", "Email", "Active", "Plan", "Signed up", "Last seen", "Revenue"]);
    // The focus stays on the button, for the next move.
    await expect(menu.getByRole("button", { name: "Move Active up" })).toBeFocused();

    await page.keyboard.press("Escape");
    await expect(menu).toHaveCount(0);
    await expect(page.getByRole("button", { name: "Columns" })).toBeFocused();
  });

  test("a filter on a column that the person hides keeps its chip", async ({ page }) => {
    await openPage(page, `/views?as=${person("ada")}`);
    await header(page, "views", "plan").locator(".masu-filter-button").click();
    await page.getByRole("checkbox", { name: /^team/ }).check();
    await page.locator("#views .masu-menu-apply").click();
    await settled(page, "views");
    const chip = page.locator("#views .masu-chip:not(.masu-chip-group) .masu-chip-text");
    await expect(chip).toHaveText("Plan is one of team");

    await page.getByRole("button", { name: "Columns" }).click();
    await page.getByRole("checkbox", { name: "Plan" }).uncheck();
    await expect.poll(() => headers(page)).not.toContain("Plan");
    await expect(chip).toHaveText("Plan is one of team");
    await expect(chip).toBeDisabled();
  });

  test("the view goes into the URL, and the link opens it in another browser", async ({ page, browser }) => {
    await openPage(page, `/views?as=${person("ada")}`);
    await page.locator(".masu-search").fill("Oslo");
    await settled(page, "views");
    await header(page, "views", "revenue").click();
    await header(page, "views", "revenue").click();
    await page.getByRole("button", { name: "Columns" }).click();
    await page.getByRole("checkbox", { name: "Seats" }).uncheck();
    await expect(page).toHaveURL(/views\[hide\]=email%2Cseats/);
    await expect(page).toHaveURL(/views\[sort\]=-revenue/);

    const other = await (await browser.newContext({ locale: "en-GB" })).newPage();
    await openPage(other, page.url().replace(/as=[^&]+/, `as=${person("alan")}`));
    await expect.poll(() => headers(other)).toEqual(["ID", "Name", "City", "Plan", "Active", "Signed up", "Last seen", "Revenue"]);
    await expect(header(other, "views", "revenue")).toHaveAttribute("aria-sort", "descending");
    await expect(other.locator(".masu-search")).toHaveValue("Oslo");
    expect(await rowText(other, "views", 0)).toEqual(await rowText(page, "views", 0));
    await other.context().close();
  });

  test("a saved view comes back, and a shared one is in the others' views menu", async ({ page, browser }) => {
    const ada = person("ada");
    await openPage(page, `/views?as=${ada}`);
    await header(page, "views", "seats").click();
    await page.getByRole("button", { name: "Columns" }).click();
    await page.getByRole("checkbox", { name: "City" }).uncheck();
    await page.keyboard.press("Escape");

    const name = `Seats ${Math.random().toString(36).slice(2, 6)}`;
    await page.getByRole("button", { name: "Views" }).click();
    await page.getByPlaceholder("Name this view").fill(name);
    await page.getByRole("checkbox", { name: "Share with everyone" }).check();
    await page.getByRole("button", { name: "Save view" }).click();
    await expect(page.getByRole("dialog", { name: "Views" }).getByRole("status")).toHaveText("View saved");
    await expect(page.locator(".masu-views-button")).toContainText(name);

    // The last view of the person comes back, without the URL.
    await openPage(page, `/views?as=${ada}`);
    await expect.poll(() => headers(page)).not.toContain("City");
    await expect(header(page, "views", "seats")).toHaveAttribute("aria-sort", "ascending");

    const alan = await (await browser.newContext({ locale: "en-GB" })).newPage();
    await openPage(alan, `/views?as=${person("alan")}`);
    await expect.poll(() => headers(alan)).toContain("City");
    await alan.getByRole("button", { name: "Views" }).click();
    await alan.getByRole("button", { name, exact: true }).click();
    await expect.poll(() => headers(alan)).not.toContain("City");
    await expect(header(alan, "views", "seats")).toHaveAttribute("aria-sort", "ascending");
    await expect(alan.getByRole("button", { name: `Delete ${name}` })).toHaveCount(0);

    await alan.getByRole("button", { name: "The grid's own view" }).click();
    await expect.poll(() => headers(alan)).toContain("City");
    await alan.context().close();
  });
});

test.describe("trees", () => {
  const row = (page: import("@playwright/test").Page, index: number) => page.locator(`#files .masu-body .masu-row[aria-rowindex="${index + 2}"]`);

  test("→ opens a row, ← closes it or goes to its parent, and * opens a level", async ({ page }) => {
    await openPage(page, "/tree");
    await expect(page.locator("#files-grid")).toHaveAttribute("role", "treegrid");
    await expect(page.locator("#files-grid")).toHaveAttribute("aria-rowcount", "201");
    await expect(row(page, 0)).toHaveAttribute("aria-level", "1");
    await expect(row(page, 0)).toHaveAttribute("aria-expanded", "false");
    await expect(row(page, 0)).toHaveAttribute("aria-setsize", "200");

    await page.locator("#files-r0-c0").click();
    await page.keyboard.press("ArrowRight");
    await expect(row(page, 0)).toHaveAttribute("aria-expanded", "true");
    await expect(page.locator("#files-r1-c0")).toHaveText("Part 1");
    await expect(row(page, 1)).toHaveAttribute("aria-level", "2");

    await page.keyboard.press("ArrowDown");
    await page.keyboard.press("ArrowRight");
    await expect(page.locator("#files-r2-c0")).toHaveText("File 1.txt");
    await expect(row(page, 2)).not.toHaveAttribute("aria-expanded");

    // ← on a file goes to its folder, then closes it.
    await page.keyboard.press("ArrowDown");
    await page.keyboard.press("ArrowLeft");
    await expect(page.locator("#files-grid")).toHaveAttribute("aria-activedescendant", "files-r1-c0");
    await page.keyboard.press("ArrowLeft");
    await expect(page.locator("#files-r2-c0")).toHaveText("Part 2");

    // The arrow closes the project; * opens every project.
    await page.locator("#files-r0-c0 .masu-twisty").click();
    await expect(page.locator("#files-grid")).toHaveAttribute("aria-rowcount", "201");
    await page.keyboard.press("*");
    await expect(page.locator("#files-grid")).toHaveAttribute("aria-rowcount", "2201");
    await expect(page.locator("#files-r11-c0")).toHaveText("Project 2");
  });

  test("a search keeps the rows that match and their folders, and a deep tree scrolls", async ({ page }) => {
    await openPage(page, "/tree");
    await page.locator(".masu-search").fill("Part 10");
    await settled(page, "files");
    await expect(page.locator("#files-grid")).toHaveAttribute("aria-rowcount", "401");
    await expect(page.locator("#files-r0-c0")).toHaveText("Project 1");
    await expect(page.locator("#files-r1-c0")).toHaveText("Part 10");
    // The project is open on what matches; the part has none of its files.
    await expect(row(page, 0)).toHaveAttribute("aria-expanded", "true");
    await expect(row(page, 1)).not.toHaveAttribute("aria-expanded");

    await page.locator(".masu-search").fill("");
    await expect(page.locator("#files-grid")).toHaveAttribute("aria-rowcount", "201");
    await page.locator("#files-r0-c0").click();
    await page.keyboard.press("Shift+*");
    await expect(page.locator("#files-grid")).toHaveAttribute("aria-rowcount", "2201");
    await page.keyboard.press("Control+End");
    await expect(page.locator("#files-r2199-c0")).toHaveText("Part 10");
  });
});

test.describe("details", () => {
  test("Alt+→ opens a row's detail under it, Alt+↓ goes into it, Escape comes back", async ({ page }) => {
    await openPage(page, "/details");
    const below = page.locator("#orders-r2-c0");
    const before = (await below.boundingBox())!.y;

    await page.locator("#orders-r1-c1").click();
    await page.keyboard.press("Alt+ArrowRight");
    const detail = page.locator("#orders .masu-detail");
    await expect(detail).toBeVisible();
    await expect(detail).toContainText("Alan Matsumoto ordered 5 lines.");
    await expect(page.locator("#orders > .masu-status")).toHaveText("Details shown");

    // The rows under it move down by its height.
    const box = (await detail.boundingBox())!;
    await expect.poll(async () => (await below.boundingBox())!.y).toBeGreaterThan(before + box.height - 2);
    expect(Math.abs(box.y - (before))).toBeLessThan(2);

    await page.keyboard.press("Alt+ArrowDown");
    await expect(page.locator("#lines-2-grid")).toBeFocused();
    await page.keyboard.press("ArrowDown");
    await page.keyboard.press("ArrowDown");
    await expect(page.locator("#lines-2-grid")).toHaveAttribute("aria-activedescendant", "lines-2-r2-c0");
    // The outer grid did not move.
    await expect(page.locator("#orders-grid")).toHaveAttribute("aria-activedescendant", "orders-r1-c1");

    await page.keyboard.press("Escape");
    await expect(page.locator("#orders-grid")).toBeFocused();
    await page.keyboard.press("Alt+ArrowLeft");
    await expect(detail).toHaveCount(0);
    await expect.poll(async () => (await below.boundingBox())!.y).toBe(before);
  });

  test("a detail stays under its row as the grid scrolls and sorts", async ({ page }) => {
    await openPage(page, "/details");
    await page.locator("#orders-r0-c0 .masu-detail-toggle").click();
    const detail = page.locator("#orders .masu-detail");
    await expect(detail).toContainText("Katherine Hamilton ordered");

    await header(page, "orders", "number").click();
    await header(page, "orders", "number").click();
    await settled(page, "orders");
    // SO-10001 is last now: the detail goes with it.
    await page.locator("#orders-r0-c0").click();
    await grid(page, "orders").evaluate((el) => (el.scrollTop = el.scrollHeight));
    await expect(page.locator("#orders-r1999-c0")).toContainText("SO-10001");
    await expect(detail).toBeInViewport();
    const rowBox = (await page.locator("#orders-r1999-c0").boundingBox())!;
    const box = (await detail.boundingBox())!;
    expect(Math.abs(box.y - (rowBox.y + rowBox.height))).toBeLessThan(3);
  });
});

test.describe("groups", () => {
  const row = (page: import("@playwright/test").Page, index: number) => page.locator(`#groups .masu-body .masu-row[aria-rowindex="${index + 2}"]`);

  test("groups open on their groups and their rows, with their counts and totals", async ({ page }) => {
    await openPage(page, "/groups");
    await expect(page.locator("#groups-grid")).toHaveAttribute("role", "treegrid");
    await expect(page.locator("#groups-r0-c0 .masu-group-label")).toHaveText("Plan: business");
    await expect(page.locator("#groups-r0-c0 .masu-group-count")).toHaveText("20,000");
    await expect(row(page, 0)).toHaveClass(/masu-group-row/);
    await expect(row(page, 0)).toHaveAttribute("aria-expanded", "false");
    await expect(page.locator("#groups-r0-c3")).toHaveText("2,490,000");

    // The totals of every row, at the bottom.
    const totals = page.locator("#groups .masu-totals");
    await expect(totals.locator(".masu-cell").first()).toHaveText("Total");
    await expect(totals.locator(".masu-cell").nth(3)).toHaveText("12,550,000");

    await page.locator("#groups-r0-c0").click();
    await page.keyboard.press("ArrowRight");
    await expect(page.locator("#groups-r1-c0 .masu-group-label")).toHaveText(/^City: /);
    await expect(row(page, 1)).toHaveAttribute("aria-level", "2");
    await page.keyboard.press("ArrowDown");
    await page.keyboard.press("ArrowRight");
    await expect(row(page, 2)).toHaveAttribute("aria-level", "3");
    await expect(row(page, 2)).not.toHaveClass(/masu-group-row/);
    await expect(page.locator("#groups-r2-c1")).toHaveText("business");

    // ← on the group's row closes it.
    await page.keyboard.press("ArrowUp");
    await page.keyboard.press("ArrowLeft");
    await expect(row(page, 2)).toHaveClass(/masu-group-row/);
  });

  test("the header menu groups by a column, a chip stops it, and a total sorts the groups", async ({ page }) => {
    await openPage(page, "/groups");
    await expect(page.locator("#groups .masu-chip-group")).toHaveText(["Grouped by Plan×", "Grouped by City×"]);
    await page.getByRole("button", { name: "Stop grouping by Plan" }).click();
    await expect(page.locator("#groups-r0-c0 .masu-group-label")).toHaveText(/^City: /);

    await header(page, "groups", "active").locator(".masu-filter-button").click();
    await page.getByRole("button", { name: "Group by Active" }).click();
    await expect(page.locator("#groups .masu-chip-group")).toHaveText(["Grouped by City×", "Grouped by Active×"]);

    await page.getByRole("button", { name: "Stop grouping by City" }).click();
    await expect(page.locator("#groups-r0-c0 .masu-group-label")).toHaveText(/^Active: /);
    await expect(page.locator("#groups .masu-body .masu-group-row")).toHaveCount(2);

    await page.getByRole("button", { name: "Stop grouping by Active" }).click();
    await page.locator("#groups-r0-c0").click();
    await page.keyboard.press("ArrowUp");
    // Grouped by plan again, sorted by the groups' revenue.
    await header(page, "groups", "plan").locator(".masu-filter-button").click();
    await page.getByRole("button", { name: "Group by Plan" }).click();
    await header(page, "groups", "revenue").click();
    await settled(page, "groups");
    const ascending = await page.locator("#groups-r0-c0 .masu-group-label").textContent();
    await header(page, "groups", "revenue").click();
    await settled(page, "groups");
    await expect(page.locator("#groups-r0-c0 .masu-group-label")).not.toHaveText(ascending!);
  });

  test("with no more groups, no first cell keeps a group's indent", async ({ page }) => {
    await openPage(page, "/groups");
    await page.locator("#groups-r0-c0").click();
    await page.keyboard.press("ArrowRight");
    await expect(row(page, 1)).toHaveAttribute("aria-level", "2");
    await page.keyboard.press("ArrowDown");
    await page.keyboard.press("ArrowRight");
    await expect(row(page, 2)).toHaveAttribute("aria-level", "3");

    await page.getByRole("button", { name: "Stop grouping by Plan" }).click();
    await page.getByRole("button", { name: "Stop grouping by City" }).click();
    await expect(page.locator("#groups-grid")).toHaveAttribute("role", "grid");
    await settled(page, "groups");
    await expect(page.locator("#groups .masu-body .masu-tree-cell")).toHaveCount(0);
    const indents = await page
      .locator("#groups .masu-body .masu-row > .masu-cell:first-child")
      .evaluateAll((cells) => new Set(cells.map((cell) => getComputedStyle(cell).paddingInlineStart)).size);
    expect(indents).toBe(1);
  });
});

test.describe("selection and export", () => {
  const person = () => `sel-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`;
  const box = (page: import("@playwright/test").Page, row: number) => page.locator(`#views-r${row}-c0 .masu-select`);

  test("boxes select rows, Shift a range, Space and Ctrl too; the header's box every row of the query", async ({ page }) => {
    await openPage(page, `/views?as=${person()}`);
    const bar = page.locator("#views .masu-selection-bar");
    const all = page.locator("#views .masu-select-all");

    await box(page, 1).click();
    await box(page, 4).click({ modifiers: ["Shift"] });
    await expect(bar).toContainText("4 selected");
    await expect(box(page, 2)).toBeChecked();
    await expect(page.locator("#views .masu-body .masu-row-chosen")).toHaveCount(4);
    await expect(all).toHaveJSProperty("indeterminate", true);

    // Space on the first column, and Ctrl and a click, take a row out.
    await page.locator("#views-r2-c1").click();
    await page.keyboard.press("ArrowLeft");
    await page.keyboard.press("Space");
    await expect(box(page, 2)).not.toBeChecked();
    await page.locator("#views-r3-c2").click({ modifiers: ["ControlOrMeta"] });
    await expect(bar).toContainText("2 selected");

    // Every row of the query: a search, then the header's box.
    await page.locator(".masu-search").fill("Oslo");
    await expect(grid(page, "views")).not.toHaveAttribute("aria-rowcount", "10001");
    await all.click();
    await expect(bar).toContainText(/^All [\d,]+ selected/);
    await expect(all).toBeChecked();
    await expect(box(page, 0)).toBeChecked();
    await box(page, 0).click();
    await expect(bar).not.toContainText("All");

    await bar.getByRole("button", { name: "Clear" }).click();
    await expect(bar).toHaveCount(0);
    await expect(box(page, 1)).not.toBeChecked();
  });

  test("the Export menu downloads the rows of the query, as CSV and as XLSX", async ({ page }) => {
    await openPage(page, `/views?as=${person()}`);
    await page.locator(".masu-search").fill("Oslo");
    // The search applies after a pause in the typing.
    await expect(grid(page, "views")).not.toHaveAttribute("aria-rowcount", "10001");
    const count = Number((await grid(page, "views").getAttribute("aria-rowcount"))!) - 1;

    const csv = page.waitForEvent("download");
    await page.getByRole("button", { name: "Export" }).click();
    await page.getByRole("dialog", { name: "Export" }).getByRole("button", { name: "CSV" }).click();
    const file = await csv;
    expect(file.suggestedFilename()).toMatch(/^views-\d{4}-\d{2}-\d{2}\.csv$/);
    const text = require("fs").readFileSync(await file.path(), "utf8") as string;
    const lines = text.trim().split("\r\n");
    expect(lines[0]).toBe("ID,Name,City,Plan,Seats,Active,Signed up,Last seen,Revenue");
    expect(lines).toHaveLength(count + 1);
    // The search's rows (it reads every text column).
    expect(lines.slice(1).every((line) => line.includes("Oslo"))).toBe(true);
    await expect(page.locator("#views > .masu-status")).toHaveText("The export is downloading");
    await expect(page.getByRole("button", { name: "Export" })).not.toHaveAttribute("aria-busy");

    const xlsx = page.waitForEvent("download");
    await page.getByRole("button", { name: "Export" }).click();
    await page.getByRole("button", { name: "Excel (XLSX)" }).click();
    const workbook = await xlsx;
    expect(workbook.suggestedFilename()).toMatch(/\.xlsx$/);
    const bytes = require("fs").readFileSync(await workbook.path()) as Buffer;
    // A zip: "PK" first.
    expect(bytes.subarray(0, 2).toString()).toBe("PK");
  });
});

test.describe("new and deleted rows, and editors", () => {
  const status = (page: import("@playwright/test").Page) => page.locator("#tasks > .masu-status");
  const cell = (page: import("@playwright/test").Page, row: number, col: number) => page.locator(`#tasks-r${row}-c${col}`);

  test.beforeEach(async ({ page }) => {
    await openPage(page, "/tasks");
  });

  test("a new row is a draft until the person leaves it; its errors stay on its cells", async ({ page }) => {
    await expect(grid(page, "tasks")).toHaveAttribute("aria-rowcount", "32");
    await grid(page, "tasks").evaluate((el) => (el.scrollTop = el.scrollHeight));
    await expect(cell(page, 30, 0)).toHaveText("+ New row");

    await grid(page, "tasks").focus();
    await page.keyboard.press("Control+Enter");
    await expect(status(page)).toHaveText("New row");
    await expect(page.locator("#tasks .masu-draft")).toHaveCount(1);
    await page.keyboard.type("Write the guide");
    await page.keyboard.press("Enter");
    // Enter goes to the row below: "+ New row". The draft saves.
    await expect(status(page)).toHaveText("Row added");
    await expect(page.locator("#tasks .masu-draft")).toHaveCount(0);
    await expect(grid(page, "tasks")).toHaveAttribute("aria-rowcount", "33");
    await expect(cell(page, 30, 0)).toHaveText("Write the guide");
    await expect(cell(page, 30, 1)).toHaveText("todo");

    // A draft with no title: refused, it stays, with the error on its cell.
    await cell(page, 31, 0).click();
    await expect(page.locator("#tasks .masu-draft")).toHaveCount(1);
    await page.keyboard.press("ArrowRight");
    await page.keyboard.press("ArrowRight");
    await page.keyboard.type("2");
    await page.keyboard.press("Enter");
    await expect(status(page)).toHaveText("Title: can't be blank");
    await expect(page.locator("#tasks .masu-draft .masu-invalid")).toHaveCount(1);
    await expect(grid(page, "tasks")).toHaveAttribute("aria-rowcount", "34");

    // Escape lets it go.
    await page.keyboard.press("ArrowUp");
    await page.keyboard.press("Escape");
    await expect(status(page)).toHaveText("New row discarded");
    await expect(page.locator("#tasks .masu-draft")).toHaveCount(0);
    await expect(grid(page, "tasks")).toHaveAttribute("aria-rowcount", "33");
  });

  test("Ctrl+Delete deletes rows after a question, Ctrl+Z brings them back, and the bar deletes those selected", async ({ page }) => {
    await cell(page, 0, 0).click();
    await page.keyboard.press("Shift+ArrowDown");
    await page.keyboard.press("Control+Delete");
    const question = page.getByRole("alertdialog");
    await expect(question).toContainText("Delete 2 rows?");
    await expect(question.getByRole("button", { name: "Delete" })).toBeFocused();
    await page.keyboard.press("Escape");
    await expect(question).toHaveCount(0);
    await expect(grid(page, "tasks")).toBeFocused();

    await page.keyboard.press("Control+Delete");
    await page.getByRole("alertdialog").getByRole("button", { name: "Delete" }).click();
    await expect(status(page)).toHaveText("2 rows deleted");
    await expect(cell(page, 0, 0)).toHaveText("Task 3");

    await page.keyboard.press("Control+z");
    await expect(status(page)).toHaveText("2 rows brought back");
    await expect(cell(page, 0, 0)).toHaveText("Task 1");
    await expect(cell(page, 1, 0)).toHaveText("Task 2");

    // A row that is done does not delete (deletable); the others do.
    await page.locator("#tasks-r2-c0 .masu-select").click();
    await page.locator("#tasks-r3-c0 .masu-select").click();
    const bar = page.locator("#tasks .masu-selection-bar");
    await bar.getByRole("button", { name: "Delete" }).click();
    await page.getByRole("alertdialog").getByRole("button", { name: "Delete" }).click();
    await expect(status(page)).toHaveText("Row deleted This row cannot be deleted.");
    await expect(cell(page, 2, 0)).toHaveText("Task 3");
    await expect(cell(page, 3, 0)).toHaveText("Task 5");
  });

  test("an enum edits with its values, a number with one decimal, and a value the server would refuse stays in the editor", async ({ page }) => {
    await expect(cell(page, 0, 2)).toHaveText("3.5");
    await expect(cell(page, 3, 2)).toHaveText("1.0");

    await cell(page, 0, 1).click();
    await page.keyboard.type("re");
    await expect(page.locator("#tasks .masu-choice")).toHaveText(["review"]);
    await page.keyboard.press("Enter");
    await expect(cell(page, 0, 1)).toHaveText("review");

    await page.keyboard.press("ArrowUp");
    await page.keyboard.press("F2");
    await expect(page.locator("#tasks .masu-choice")).toHaveText(["todo", "doing", "review", "done"]);
    await expect(page.locator("#tasks .masu-choice[aria-selected=true]")).toHaveText("review");
    await page.keyboard.press("ArrowDown");
    await page.keyboard.press("Enter");
    await expect(cell(page, 0, 1)).toHaveText("done");

    await cell(page, 0, 2).click();
    await page.keyboard.type("lots");
    await page.keyboard.press("Enter");
    await expect(status(page)).toHaveText("Estimate: Not a number");
    await expect(page.locator("#tasks .masu-editor")).toHaveAttribute("aria-invalid", "true");
    await page.keyboard.press("Escape");
    await expect(cell(page, 0, 2)).toHaveText("3.5");
  });

  test("a paste past the last row adds the rest as new rows, and shows the one refused", async ({ page, context, browserName }) => {
    test.skip(browserName !== "chromium", "only Chromium lets a test write the clipboard");
    await context.grantPermissions(["clipboard-read", "clipboard-write"]);
    await grid(page, "tasks").evaluate((el) => (el.scrollTop = el.scrollHeight));
    await cell(page, 29, 0).click();
    await page.evaluate(() => navigator.clipboard.writeText("Alpha\ttodo\nBeta\tdoing\n\tdone"));
    await page.keyboard.press("ControlOrMeta+v");
    const question = page.getByRole("alertdialog");
    await expect(question).toContainText("Add 2 new rows for the rest of the paste?");
    await question.getByRole("button", { name: "Add rows" }).click();
    await expect(status(page)).toHaveText("Title: can't be blank");
    await expect(cell(page, 29, 0)).toHaveText("Alpha");
    await expect(cell(page, 30, 0)).toHaveText("Beta");
    await expect(page.locator("#tasks .masu-draft")).toHaveCount(1);
    await expect(grid(page, "tasks")).toHaveAttribute("aria-activedescendant", "tasks-r31-c0");
  });
});

test("an undo right after an edit waits for the edit's save", async ({ page }) => {
  // A slow network: the server's messages come half a second late.
  let delay = 0;
  await page.routeWebSocket(/\/live\/websocket/, (ws) => {
    const server = ws.connectToServer();
    server.onMessage((message) => {
      if (delay > 0) setTimeout(() => ws.send(message), delay);
      else ws.send(message);
    });
  });
  await openPage(page, "/");
  const name = page.locator("#customers-r2-c1");
  await name.click();
  delay = 500;
  await page.keyboard.type("Grace");
  await page.keyboard.press("Tab");
  await page.keyboard.press("ControlOrMeta+z");
  await expect(name).toHaveText("Alan Matsumoto");
  await page.keyboard.press("ControlOrMeta+Shift+z");
  await expect(name).toHaveText("Grace");
});

test("two changes of a cell, the second before the first's save, both save", async ({ page }) => {
  let delay = 0;
  await page.routeWebSocket(/\/live\/websocket/, (ws) => {
    const server = ws.connectToServer();
    server.onMessage((message) => {
      if (delay > 0) setTimeout(() => ws.send(message), delay);
      else ws.send(message);
    });
  });
  await openPage(page, "/");
  const active = page.locator("#customers-r0-c7");
  await active.click();
  delay = 500;
  await page.keyboard.press("Space");
  await page.keyboard.press("Space");
  // Both saves answered, half a second each: the cell is back as it was.
  await page.waitForTimeout(2000);
  await expect(active).toHaveText("✓");
});

test.describe("rows without a count, and pages", () => {
  test.beforeEach(async ({ page }) => {
    await openPage(page, "/pages");
  });

  test("a source that does not count: the grid scrolls over the rows it read, and grows", async ({ page }) => {
    const engine = grid(page, "engine");
    await expect(engine).toHaveAttribute("aria-rowcount", "-1");
    const height = () => page.locator("#engine .masu-body").evaluate((el) => parseFloat((el as HTMLElement).style.height));
    // The rows read (a block, read ahead), and a block more.
    await expect.poll(height).toBe(36 * 200);

    await engine.evaluate((el) => (el.scrollTop = el.scrollHeight));
    await expect.poll(height).toBeGreaterThan(36 * 200);
    await expect(page.locator('#engine .masu-row[aria-rowindex="201"]')).toContainText("200");
    await expect(engine).toHaveAttribute("aria-rowcount", "-1");
  });

  test("a grid of pages: the pager goes from page to page, and the page goes into the URL", async ({ page }) => {
    const pager = page.locator("#report .masu-pager");
    await expect(pager.locator(".masu-pager-range")).toHaveText("1–25 of 100,000");
    await expect(pager.getByRole("button", { name: "Previous" })).toBeDisabled();
    // The page's rows, and no more: its last is the 25th.
    await grid(page, "report").evaluate((el) => (el.scrollTop = el.scrollHeight));
    await expect(page.locator('#report .masu-row[aria-rowindex="26"]')).toContainText("25");
    await expect(page.locator('#report .masu-row[aria-rowindex="27"]')).toHaveCount(0);

    await pager.getByRole("button", { name: "Next" }).click();
    await expect(pager.locator(".masu-pager-range")).toHaveText("26–50 of 100,000");
    await expect(page).toHaveURL(/report%5Bpage%5D=2|report\[page\]=2/);
    await expect(page.locator('#report .masu-row[aria-rowindex="27"]')).toContainText("26");
    await expect(grid(page, "report")).toHaveJSProperty("scrollTop", 0);

    await pager.getByLabel("Page").fill("4000");
    await pager.getByLabel("Page").press("Enter");
    await expect(pager.locator(".masu-pager-range")).toHaveText("99,976–100,000 of 100,000");
    await expect(pager.getByRole("button", { name: "Next" })).toBeDisabled();

    // The keys stay on the page: ↑ from its first row goes to the header.
    await page.locator('#report .masu-row[aria-rowindex="99977"] .masu-cell').first().click();
    await page.keyboard.press("ArrowUp");
    await expect(grid(page, "report")).toHaveAttribute("aria-activedescendant", "report-h0");

    await page.reload();
    await expect(page.locator("#report .masu-pager-range")).toHaveText("99,976–100,000 of 100,000");
  });

  test("a page is one read of the source, and the next page is not read ahead", async ({ page }) => {
    const reads: string[] = [];
    page.on("websocket", (ws) =>
      ws.on("framesent", (frame) => {
        const text = String(frame.payload);
        // The report's reads: blocks of its page size, 25.
        if (text.includes('"masu:rows"') && text.includes('"count":25')) reads.push(text);
      }),
    );
    await page.reload();
    await expect(page.locator("#report .masu-pager-range")).toHaveText("1–25 of 100,000");
    // The first page came with the grid: nothing to read.
    await page.waitForTimeout(300);
    expect(reads).toHaveLength(0);

    await page.locator("#report .masu-pager").getByRole("button", { name: "Next" }).click();
    await expect(page.locator('#report .masu-row[aria-rowindex="27"]')).toContainText("26");
    await page.waitForTimeout(300);
    expect(reads).toHaveLength(1);
    expect(reads[0]).toContain('"from":25');
  });

  test("in a grid of pages, a new row goes on the last page", async ({ page }) => {
    const range = page.locator("#notes .masu-pager-range");
    await expect(range).toHaveText("1–5 of 12");
    await page.locator("#notes-r0-c0").click();
    await page.keyboard.press("Control+Enter");
    await expect(range).toHaveText("11–12 of 12");
    await expect(page.locator("#notes .masu-draft")).toHaveCount(1);
    await page.keyboard.type("Thirteen");
    await page.keyboard.press("Enter");
    await expect(page.locator("#notes > .masu-status")).toHaveText("Row added");
    await expect(range).toHaveText("11–13 of 13");
    await expect(page.locator("#notes-r12-c0")).toHaveText("Thirteen");
  });
});

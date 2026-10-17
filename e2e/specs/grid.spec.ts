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

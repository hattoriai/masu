import { expect, test, type Page } from "@playwright/test";
import { grid, header, openPage, rowText, settled } from "./support";

// Menus of the app's own (Masu.Action), on the Menus page: the menu of a
// cell, with the grid's items and the app's, and the app's items in a
// header menu. Its columns: name, city, plan, revenue, active.

const cell = (page: Page, row: number, col: number) => page.locator(`#menus-r${row}-c${col}`);
const menu = (page: Page) => page.locator('#menus [role="menu"]');
const item = (page: Page, name: string) => menu(page).getByRole("menuitem", { name, exact: true });

test.beforeEach(async ({ page }) => {
  await openPage(page, "/menus");
});

test("a right click opens a cell's menu, whose items filter and sort by the cell", async ({ page }) => {
  const [, city, plan] = await rowText(page, "menus", 0);

  await cell(page, 0, 2).click({ button: "right" });
  await expect(menu(page)).toHaveAttribute("aria-label", "Plan: actions");
  await expect(menu(page).getByRole("menuitem")).toHaveText([
    "Copy",
    "Copy with headers",
    `Filter by ${plan}`,
    `Exclude ${plan}`,
    "Filter by empty",
    "Filter by not empty",
    "Sort ascending",
    "Sort descending",
    "Open",
    "Mark",
  ]);
  await expect(menu(page).getByRole("separator")).toHaveCount(3);
  await item(page, `Filter by ${plan}`).click();
  await settled(page, "menus");
  await expect(menu(page)).toHaveCount(0);
  await expect(page.locator("#menus .masu-chip-text")).toHaveText([`Plan is one of ${plan}`]);

  await cell(page, 0, 1).click({ button: "right" });
  await item(page, `Exclude ${city}`).click();
  await settled(page, "menus");
  await expect(page.locator("#menus .masu-chip-text")).toHaveText([`Plan is one of ${plan}`, `City is not ${city}`]);
  expect((await rowText(page, "menus", 0))[1]).not.toBe(city);

  await cell(page, 0, 3).click({ button: "right" });
  await item(page, "Sort descending").click();
  await settled(page, "menus");
  await expect(header(page, "menus", "revenue")).toHaveAttribute("aria-sort", "descending");
  const first = Number((await rowText(page, "menus", 0))[3].replace(/,/g, ""));
  const second = Number((await rowText(page, "menus", 1))[3].replace(/,/g, ""));
  expect(first).toBeGreaterThanOrEqual(second);
});

test("Shift+F10 opens the menu of the active cell: the arrows move, Escape gives the focus back", async ({ page }) => {
  await cell(page, 2, 0).click();
  await page.keyboard.press("Shift+F10");
  await expect(menu(page)).toBeVisible();
  await expect(item(page, "Copy")).toBeFocused();

  await page.keyboard.press("ArrowDown");
  await expect(item(page, "Copy with headers")).toBeFocused();
  await page.keyboard.press("End");
  await expect(item(page, "Card")).toBeFocused();
  await page.keyboard.press("ArrowDown");
  await expect(item(page, "Copy")).toBeFocused();
  await page.keyboard.press("s");
  await expect(item(page, "Sort ascending")).toBeFocused();

  await page.keyboard.press("Escape");
  await expect(menu(page)).toHaveCount(0);
  await expect(grid(page, "menus")).toBeFocused();
  await expect(grid(page, "menus")).toHaveAttribute("aria-activedescendant", "menus-r2-c0");

  // Enter runs the item, and the focus comes back too.
  await page.keyboard.press("Shift+F10");
  await page.keyboard.press("End");
  await page.keyboard.press("ArrowUp");
  await page.keyboard.press("ArrowUp");
  await expect(item(page, "Open")).toBeFocused();
  await page.keyboard.press("Enter");
  const [name] = await rowText(page, "menus", 2);
  await expect(page.locator("#said")).toHaveText(`Opened ${name}`);
  await expect(grid(page, "menus")).toBeFocused();
});

test("the app's items: a JS command, with the cell in the event before it, and a panel the server renders", async ({ page }) => {
  const [name] = await rowText(page, "menus", 1);
  const heard = page.evaluate(
    () =>
      new Promise((resolve) =>
        document.getElementById("menus")!.addEventListener("masu:action", (event) => resolve((event as CustomEvent).detail), { once: true }),
      ),
  );
  await cell(page, 1, 0).click({ button: "right" });
  await item(page, "Mark").click();
  await expect(page.locator("#js-mark")).toHaveAttribute("data-marked", "yes");
  expect(await heard).toEqual({ grid: "menus", kind: "cell", action: "Mark", column: "name", id: 2, value: name });

  await cell(page, 1, 0).click({ button: "right" });
  await item(page, "Card").click();
  const panel = page.locator("#menus-action-panel");
  await expect(panel).toBeVisible();
  await expect(panel).toHaveAttribute("role", "dialog");
  await expect(panel.locator("#card strong")).toHaveText(name);
  await expect(panel).toBeFocused();
  // Under the cell.
  const cellBox = (await cell(page, 1, 0).boundingBox())!;
  const panelBox = (await panel.boundingBox())!;
  expect(Math.abs(panelBox.y - (cellBox.y + cellBox.height + 4))).toBeLessThan(2);

  await page.keyboard.press("Escape");
  await expect(panel).toHaveCount(0);
  await expect(grid(page, "menus")).toBeFocused();
});

test("a header menu has the app's items for the column, and a panel goes under its header", async ({ page }) => {
  await header(page, "menus", "name").hover();
  await header(page, "menus", "name").locator(".masu-filter-button").click();
  const dialog = page.locator('#menus .masu-menu[role="dialog"]');
  await expect(dialog.locator(".masu-menu-item")).toHaveText(["Sort ascending", "Sort descending", "Explain"]);
  await dialog.locator(".masu-menu-item", { hasText: "Explain" }).click();
  await expect(page.locator("#said")).toHaveText("About name");
  await expect(dialog).toHaveCount(0);

  // A right click on a header opens its menu too.
  await header(page, "menus", "revenue").click({ button: "right" });
  await expect(dialog.locator(".masu-menu-item")).toHaveText(["Sort ascending", "Sort descending", "Explain", "Column stats"]);
  await dialog.locator(".masu-menu-item", { hasText: "Column stats" }).click();
  const panel = page.locator("#menus-action-panel");
  await expect(panel.locator("#stats dt")).toHaveText(["Lowest", "Highest", "Average"]);
  const headerBox = (await header(page, "menus", "revenue").boundingBox())!;
  const panelBox = (await panel.boundingBox())!;
  expect(Math.abs(panelBox.y - (headerBox.y + headerBox.height + 4))).toBeLessThan(2);

  // A click away closes it.
  await page.locator("#menus-label").click();
  await expect(panel).toHaveCount(0);
});

test("Copy with headers copies the cell, or the range it is in, with the columns' labels", async ({ page, context, browserName }) => {
  test.skip(browserName !== "chromium", "only Chromium lets a test read the clipboard");
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  const rows = [await rowText(page, "menus", 0), await rowText(page, "menus", 1)];

  await cell(page, 0, 0).click();
  await cell(page, 1, 1).click({ modifiers: ["Shift"] });
  await cell(page, 1, 0).click({ button: "right" });
  await item(page, "Copy with headers").click();
  await expect.poll(() => page.evaluate(() => navigator.clipboard.readText())).toBe(
    `Name\tCity\n${rows[0][0]}\t${rows[0][1]}\n${rows[1][0]}\t${rows[1][1]}`,
  );

  // A right click out of the range: the cell alone.
  await cell(page, 3, 2).click({ button: "right" });
  await item(page, "Copy").click();
  await expect.poll(() => page.evaluate(() => navigator.clipboard.readText())).toBe((await rowText(page, "menus", 3))[2]);
});

test("a grid with no menu of its cells leaves the browser's own", async ({ page }) => {
  await openPage(page, "/small");
  const prevented = page.evaluate(
    () =>
      new Promise((resolve) =>
        document.addEventListener("contextmenu", (event) => resolve(event.defaultPrevented), { once: true }),
      ),
  );
  await page.locator("#small-r0-c0").click({ button: "right" });
  expect(await prevented).toBe(false);
  await expect(page.locator('#small [role="menu"]')).toHaveCount(0);
});

test("in a short box that cuts its overflow, a menu and a panel float above the page, whole", async ({ page }) => {
  // The grid in a box as short as Lotus Web's results, which hides what
  // overflows it.
  await page.locator("#menus").evaluate((el) => {
    const box = document.createElement("div");
    Object.assign(box.style, { height: "140px", overflow: "hidden" });
    el.replaceWith(box);
    box.appendChild(el);
    el.style.height = "100%";
  });

  const whole = async (selector: string) => {
    const shown = await page.locator(selector).evaluate((el) => {
      const r = el.getBoundingClientRect();
      const x = Math.min(Math.max(r.left + 8, 0), innerWidth - 1);
      // The element is what the page shows at its corners: no box clips it.
      const at = (y: number) => el.contains(document.elementFromPoint(x, y));
      return {
        open: el.matches(":popover-open"),
        inside: r.top >= 0 && r.bottom <= innerHeight,
        top: at(r.top + 4),
        bottom: at(r.bottom - 4),
      };
    });
    expect(shown).toEqual({ open: true, inside: true, top: true, bottom: true });
  };

  await header(page, "menus", "name").hover();
  await header(page, "menus", "name").locator(".masu-filter-button").click();
  await whole('#menus .masu-menu[role="dialog"]');
  await page.keyboard.press("Escape");

  await header(page, "menus", "revenue").click({ button: "right" });
  await page.locator('#menus .masu-menu[role="dialog"] .masu-menu-item', { hasText: "Column stats" }).click();
  await expect(page.locator("#stats dt")).toHaveText(["Lowest", "Highest", "Average"]);
  await whole("#menus-action-panel");
});

test("a cell of numbers filters by its value as a bound, and one of text by a part", async ({ page }) => {
  const [name, , , revenue] = await rowText(page, "menus", 0);

  await cell(page, 0, 3).click({ button: "right" });
  await expect(menu(page).getByRole("menuitem")).toContainText([
    `Filter by ${revenue}`,
    `Exclude ${revenue}`,
    `Greater than ${revenue}`,
    `Less than ${revenue}`,
    `At least ${revenue}`,
    `At most ${revenue}`,
    "Filter by empty",
  ]);
  await item(page, `At least ${revenue}`).click();
  await settled(page, "menus");
  await expect(page.locator("#menus .masu-chip-text")).toHaveText([`Revenue at least ${revenue}`]);
  const bound = Number(revenue.replace(/,/g, ""));
  for (let row = 0; row < 3; row++) {
    const text = (await rowText(page, "menus", row))[3];
    if (text !== undefined) expect(Number(text.replace(/,/g, ""))).toBeGreaterThanOrEqual(bound);
  }

  await cell(page, 0, 0).click({ button: "right" });
  await expect(item(page, `Greater than ${name}`)).toHaveCount(0);
  const [first] = await rowText(page, "menus", 0);
  await item(page, `Contains ${first}`).click();
  await settled(page, "menus");
  await expect(page.locator("#menus .masu-chip-text")).toContainText([`Name contains ${first}`]);
});

test("a cell's menu is as tall as its items, whatever height the app's styles give popovers", async ({ page }) => {
  const height = async () => {
    await cell(page, 0, 2).click({ button: "right" });
    await expect(menu(page)).toBeVisible();
    const box = (await menu(page).boundingBox())!;
    await page.keyboard.press("Escape");
    await expect(menu(page)).toHaveCount(0);
    return box.height;
  };
  const own = await height();
  await page.addStyleTag({ content: "[popover] { height: 100%; }" });
  expect(await height()).toBe(own);
});

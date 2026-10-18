import { expect, test, type Page } from "@playwright/test";
import { grid, openPage, rowText, settled } from "./support";

// Actions of the app's own (Masu.Action), on the Actions page: on the
// rows selected (the bar above the grid), and on each row (the menu at
// its end, and in the menu of its cells). Its columns: name, city, plan,
// active.

const menu = (page: Page) => page.locator('#actions [role="menu"]');
const item = (page: Page, name: string) => menu(page).getByRole("menuitem", { name, exact: true });
const more = (page: Page, row: number) => page.locator(`#actions-r${row}-actions .masu-row-actions-button`);
const bar = (page: Page) => page.locator("#actions .masu-selection-bar");
const task = (page: Page) => page.locator("#actions .masu-task");

test.beforeEach(async ({ page }) => {
  await openPage(page, "/actions");
});

test("the button at a row's end opens its actions: a link, an action, one that is not available", async ({ page }) => {
  // The first customer that is active, and the first that is not.
  const rows = await Promise.all([0, 1, 2, 3, 4].map((i) => rowText(page, "actions", i)));
  const active = rows.findIndex((cells) => cells[3] === "✓");
  const inactive = rows.findIndex((cells) => cells[3] === "");

  await more(page, active).click();
  await expect(menu(page)).toHaveAttribute("aria-label", "Row actions");
  await expect(menu(page).getByRole("menuitem")).toHaveText(["Open", "Deactivate", "Remove"]);
  await expect(item(page, "Open")).toHaveAttribute("href", /\/actions\?open=\d+/);
  await expect(item(page, "Deactivate")).not.toHaveAttribute("aria-disabled", "true");

  await item(page, "Deactivate").click();
  await expect(task(page)).toHaveText(`${rows[active][0]} deactivated`);
  await settled(page, "actions");
  await expect.poll(async () => (await rowText(page, "actions", active))[3]).toBe("");

  await more(page, inactive).click();
  await expect(item(page, "Deactivate")).toHaveAttribute("aria-disabled", "true");
  await page.keyboard.press("ArrowDown");
  await expect(item(page, "Deactivate")).toBeFocused();
  await page.keyboard.press("Enter");
  // Not available: the menu stays, and nothing runs.
  await expect(menu(page)).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(menu(page)).toHaveCount(0);
  await expect(grid(page, "actions")).toBeFocused();
});

test("a link patches the LiveView's URL, as a link does", async ({ page }) => {
  const [name] = await rowText(page, "actions", 0);
  await more(page, 0).click();
  await item(page, "Open").click();
  await expect(page).toHaveURL(/\/actions\?open=\d+$/);
  await expect(page.locator("#said")).toHaveText(`Opened ${name}`);
});

test("Shift+F10 on a cell opens its menu with the row's actions, and an action asks first", async ({ page }) => {
  const [name] = await rowText(page, "actions", 1);
  await page.locator("#actions-r1-c1").click();
  await page.keyboard.press("Shift+F10");
  await expect(menu(page).getByRole("menuitem")).toHaveText(["Open", "Deactivate", "Remove"]);
  await expect(menu(page).locator(":focus")).toHaveText("Open");
  await page.keyboard.press("End");
  await page.keyboard.press("Enter");

  const question = page.locator("#actions .masu-confirm");
  await expect(question).toContainText("Remove this customer?");
  await question.getByRole("button", { name: "Remove" }).click();
  await settled(page, "actions");
  await expect.poll(async () => (await rowText(page, "actions", 1))[0]).not.toBe(name);
});

test("the bar of the rows selected has the actions; one runs on them, and the selection clears", async ({ page }) => {
  await page.locator("#actions-r0-c0 .masu-select").click();
  await page.locator("#actions-r1-c0 .masu-select").click();
  await expect(bar(page)).toContainText("2 selected");
  await expect(bar(page).getByRole("button")).toHaveText(["Deactivate", "Export later", "Remove", "Clear"]);

  await bar(page).getByRole("button", { name: "Deactivate" }).click();
  await expect(task(page)).toHaveText("2 deactivated");
  await expect(bar(page)).toHaveCount(0);
  await expect.poll(async () => (await rowText(page, "actions", 0))[3]).toBe("");
});

test("an action asks first with the count, and one that goes on later says how far it is", async ({ page }) => {
  await page.locator("#actions-r0-c0 .masu-select").click();
  await page.locator("#actions-r1-c0 .masu-select").click();
  await page.locator("#actions-r2-c0 .masu-select").click();

  await bar(page).getByRole("button", { name: "Remove" }).click();
  const question = page.locator("#actions .masu-confirm");
  await expect(question).toContainText("Remove 3 customers?");
  await question.getByRole("button", { name: "Cancel" }).click();
  await expect(bar(page)).toContainText("3 selected");

  await bar(page).getByRole("button", { name: "Export later" }).click();
  await expect(task(page)).toHaveText(/Export later: (running…|\d of 3)/);
  await expect(task(page)).toHaveText("3 exported", { timeout: 5000 });
});

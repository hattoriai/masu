import { expect, test } from "@playwright/test";
import { grid, openPage, rowText } from "./support";

// Rows that open (`on_row_activate`), on the Open a row page: a click on a
// row, or Enter on it, patches the URL to the row, and the page shows it
// in a panel. Its columns: name, city (read-only), seats (edits), and a
// link.

const cell = (row: number, col: number) => `#open-r${row}-c${col}`;

test.beforeEach(async ({ page }) => {
  await openPage(page, "/open");
});

test("a click on a row opens it", async ({ page }) => {
  const [name] = await rowText(page, "open", 2);
  await page.locator(cell(2, 1)).click();
  await expect(page).toHaveURL(/\/open\?open=\d+$/);
  await expect(page.locator("#opened")).toHaveText(`Opened ${name}`);
  // The grid keeps the focus, on the cell clicked.
  await expect(grid(page, "open")).toBeFocused();
  await expect(grid(page, "open")).toHaveAttribute("aria-activedescendant", "open-r2-c1");
});

test("Enter on a row's active cell opens it", async ({ page }) => {
  const [name] = await rowText(page, "open", 1);
  await grid(page, "open").focus();
  await page.keyboard.press("ArrowDown");
  await page.keyboard.press("Enter");
  await expect(page.locator("#opened")).toHaveText(`Opened ${name}`);
});

test("a cell that edits is the editor's: a click and Enter do not open its row", async ({ page }) => {
  await page.locator(cell(0, 2)).click();
  await page.keyboard.press("Enter");
  await expect(page.locator("#open .masu-editor")).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(page.locator("#open .masu-editor")).toHaveCount(0);
  await expect(page.locator("#opened")).toHaveCount(0);
  await expect(page).toHaveURL(/\/open$/);
});

test("a click that ends an editor does not open a row", async ({ page }) => {
  await page.locator(cell(0, 2)).dblclick();
  await expect(page.locator("#open .masu-editor")).toBeVisible();
  await page.locator(cell(1, 0)).click();
  await expect(page.locator("#open .masu-editor")).toHaveCount(0);
  await expect(page.locator("#opened")).toHaveCount(0);
});

test("a link in a cell is a link", async ({ page }) => {
  await page.locator(`${cell(0, 3)} a`).click();
  await expect(page).toHaveURL(/\/open\?site=\d+$/);
  await expect(page.locator("#site")).toHaveText(/Site of \d+/);
  await expect(page.locator("#opened")).toHaveCount(0);
});

test("selecting a range, by a drag or Shift and a click, opens no row", async ({ page }) => {
  await page.locator(cell(0, 0)).click({ modifiers: ["Shift"] });
  await page.locator(cell(2, 1)).click({ modifiers: ["Shift"] });
  await expect(page.locator("#open .masu-selected").first()).toBeVisible();

  const from = await page.locator(cell(3, 0)).boundingBox();
  const to = await page.locator(cell(5, 1)).boundingBox();
  await page.mouse.move(from!.x + 10, from!.y + 10);
  await page.mouse.down();
  await page.mouse.move(to!.x + 10, to!.y + 10, { steps: 5 });
  await page.mouse.up();
  await expect(page.locator("#opened")).toHaveCount(0);
  await expect(page).toHaveURL(/\/open$/);
});

import { expect, test, type Page } from "@playwright/test";
import { grid, openPage } from "./support";

// The history of cells (Masu.History), on the History page: a budget of
// item, owner, amount, kept in memory by the server for the whole run;
// each test edits rows of its own.

const cell = (page: Page, row: number, col: number) => page.locator(`#budget-r${row}-c${col}`);
const popover = (page: Page) => page.locator('#budget [role="dialog"].masu-history');

async function type(page: Page, row: number, col: number, text: string, shown = text) {
  await cell(page, row, col).click();
  await page.keyboard.type(text);
  await page.keyboard.press("Enter");
  await expect(cell(page, row, col)).toHaveText(shown);
}

test.beforeEach(async ({ page }) => {
  await openPage(page, "/history");
});

test("a cell's history: its values, who and when, from its menu and Ctrl+Alt+H; Restore brings one back", async ({ page }) => {
  const before = (await cell(page, 0, 2).textContent())!.trim();
  await type(page, 0, 2, "1250", "1,250");
  await type(page, 0, 2, "1300", "1,300");

  await cell(page, 0, 2).click({ button: "right" });
  await page.locator('#budget [role="menu"]').getByRole("menuitem", { name: "History", exact: true }).click();
  await expect(popover(page)).toHaveAccessibleName("Amount: history");
  const entries = popover(page).locator(".masu-history-entry");
  await expect(entries.first()).toContainText("1,300");
  await expect(entries.first()).toContainText("was 1,250");
  await expect(entries.first()).toContainText("Ada");
  await expect(popover(page).getByRole("button").first()).toBeFocused();
  await page.keyboard.press("Escape");
  await expect(popover(page)).toHaveCount(0);
  await expect(grid(page, "budget")).toBeFocused();

  // The value before the first change, from the keyboard.
  await page.keyboard.press("Control+Alt+h");
  await popover(page).getByRole("button", { name: `Restore ${before}` }).click();
  await expect(cell(page, 0, 2)).toHaveText(before);

  await page.keyboard.press("Control+Alt+h");
  await expect(entries.first()).toContainText("restored");
});

test("a row's history, and a paste undone at once", async ({ page }) => {
  await cell(page, 3, 1).click();
  await page.evaluate(() => {
    const data = new DataTransfer();
    data.setData("text/plain", "Tim\t99");
    document.querySelector("#budget-grid")!.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true }));
  });
  await expect(cell(page, 3, 2)).toHaveText("99");

  await cell(page, 3, 0).click({ button: "right" });
  await page.locator('#budget [role="menu"]').getByRole("menuitem", { name: "Row history" }).click();
  await expect(popover(page).locator(".masu-history-entry")).toHaveCount(2);
  await popover(page).getByRole("button", { name: "Undo all 2" }).click();
  await expect(cell(page, 3, 1)).toHaveText("Linus");
  await expect(cell(page, 3, 2)).toHaveText("35");
});

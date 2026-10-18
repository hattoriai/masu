import { expect, test, type Page } from "@playwright/test";
import { grid, openPage } from "./support";

// Editors of the app's own, on the Editors page: editors of the browser's
// given to configure({editors}) (a slider with options, a color), and
// forms the server renders in a popover (notes in a text area, a window
// of two days). Its columns: title, score, color, notes, window.

const cell = (page: Page, row: number, col: number) => page.locator(`#editors-r${row}-c${col}`);
const popover = (page: Page) => page.locator("#editors-cell-editor");

test.beforeEach(async ({ page }) => {
  await openPage(page, "/editors");
});

test("an editor of the browser's: Enter opens it with its options, its keys are its own, Enter saves", async ({ page }) => {
  const before = Number(await cell(page, 0, 1).textContent());
  await cell(page, 0, 1).click();
  await page.keyboard.press("Enter");
  const slider = page.locator("#editors .masu-own-editor input[type=range]");
  await expect(slider).toBeFocused();
  await expect(slider).toHaveAttribute("step", "5");
  await expect(slider).toHaveAttribute("aria-label", "Score");
  await page.keyboard.press("ArrowRight");
  await page.keyboard.press("Enter");
  await expect(slider).toHaveCount(0);
  await expect(cell(page, 0, 1)).not.toHaveText(String(before));
  // Enter moved down, as it does for the grid's own editors.
  await expect(grid(page, "editors")).toBeFocused();
  await expect(grid(page, "editors")).toHaveAttribute("aria-activedescendant", "editors-r1-c1");

  // Escape lets an edit go; undo brings the saved one back.
  await cell(page, 0, 1).click();
  await page.keyboard.press("Enter");
  await page.keyboard.press("ArrowRight");
  await page.keyboard.press("Escape");
  await expect(slider).toHaveCount(0);
  await page.keyboard.press("Control+z");
  await expect(cell(page, 0, 1)).toHaveText(String(before));
});

test("a form the server renders: a popover under the cell, labelled, that keeps Enter, and saves with Ctrl+Enter", async ({ page }) => {
  await cell(page, 0, 3).click();
  await page.keyboard.press("Enter");
  await expect(popover(page)).toHaveAttribute("role", "dialog");
  await expect(popover(page)).toHaveAccessibleName("Notes");
  const area = popover(page).locator("textarea");
  await expect(area).toBeFocused();
  await page.keyboard.type("Ring Ada");
  await page.keyboard.press("Enter");
  await page.keyboard.type("twice");
  await page.keyboard.press("Control+Enter");
  await expect(popover(page)).toHaveCount(0);
  await expect(cell(page, 0, 3)).toHaveText("Ring Ada twice");
  await expect(grid(page, "editors")).toBeFocused();

  await page.keyboard.press("Control+z");
  await expect(cell(page, 0, 3)).toHaveText("");

  // Escape lets it go.
  await page.keyboard.press("Enter");
  await expect(area).toBeFocused();
  await page.keyboard.type("nope");
  await page.keyboard.press("Escape");
  await expect(popover(page)).toHaveCount(0);
  await expect(cell(page, 0, 3)).toHaveText("");
});

test("a form posts params (from and to); the server's error goes on the cell, which keeps its value", async ({ page }) => {
  const shown = (await cell(page, 1, 4).textContent())!.trim();
  await cell(page, 1, 4).dblclick();
  await popover(page).locator("input[type=date]").first().fill("2027-04-30");
  await popover(page).getByRole("button", { name: "Save" }).click();
  await expect(cell(page, 1, 4)).toHaveAttribute("title", "ends before it starts");
  await expect(cell(page, 1, 4)).toHaveText(shown);

  await cell(page, 1, 4).dblclick();
  await popover(page).locator("input[type=date]").first().fill("2027-03-01");
  await popover(page).getByRole("button", { name: "Save" }).click();
  await expect(cell(page, 1, 4)).toHaveText(/2027-03-01 → /);
  await expect(cell(page, 1, 4)).not.toHaveAttribute("title", /.+/);
});

test("a click away saves a form", async ({ page }) => {
  await cell(page, 2, 3).click();
  await page.keyboard.press("Enter");
  await popover(page).locator("textarea").fill("Left by a click");
  await cell(page, 5, 0).click();
  await expect(popover(page)).toHaveCount(0);
  await expect(cell(page, 2, 3)).toHaveText("Left by a click");
});

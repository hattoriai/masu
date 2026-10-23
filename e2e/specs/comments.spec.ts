// Issho's comments on a shared grid (dev.exs, /comments): a thread on a
// cell, said in words, and its mark on that cell on each person's screen,
// whatever their order.

import { expect, test, type Locator, type Page } from "@playwright/test";
import { grid, header, openPage } from "./support";

/** The top right corner of a box, where a thread's mark goes. */
async function corner(locator: Locator): Promise<{ x: number; y: number }> {
  const box = (await locator.boundingBox())!;
  return { x: box.x + box.width, y: box.y };
}

/** The cell of a column in the row whose Name is `name`, as this page shows it. */
function cellOf(page: Page, name: string, col: number): Locator {
  return page.locator("#customers .masu-body .masu-row", { has: page.locator(".masu-cell", { hasText: name }) }).locator(`.masu-cell[aria-colindex="${col + 1}"]`);
}

/** The page's one mark, over the top right corner of the cell. */
async function expectMarkOn(page: Page, cell: Locator): Promise<void> {
  const mark = page.locator(".issho-comment-mark");
  await expect(mark).toBeVisible();
  await expect
    .poll(async () => {
      const [box, at] = [(await mark.boundingBox())!, await corner(cell)];
      return at.x >= box.x && at.x <= box.x + box.width && at.y >= box.y && at.y <= box.y + box.height;
    })
    .toBe(true);
}

test("a thread on a cell: its place in words, and its mark on the cell, in each person's order", async ({ browser }) => {
  const room = `comments-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  const ada = await (await browser.newContext({ locale: "en-GB" })).newPage();
  const alan = await (await browser.newContext({ locale: "en-GB" })).newPage();
  const errors: string[] = [];
  ada.on("pageerror", (error) => errors.push(error.message));
  await openPage(ada, `/comments?as=Ada&room=${room}`);
  await openPage(alan, `/comments?as=Alan&room=${room}`);

  // Ada selects the City of the third row, and comments on it.
  const name = (await ada.locator("#customers-r2-c1").textContent())!.trim();
  await ada.locator("#customers-r2-c2").click();
  const where = ada.locator("#threads .issho-where-label");
  await expect(where).toHaveText(`City of ${name}`);
  await ada.locator("#threads .issho-composer textarea").fill("Is this the right city?");
  await ada.locator("#threads .issho-composer").getByRole("button", { name: "Comment" }).click();

  const place = ada.locator("#threads .issho-thread .issho-thread-place-label");
  await expect(place).toHaveText(`City of ${name}`);
  await expectMarkOn(ada, cellOf(ada, name, 2));

  // Alan, in another order, sees the thread; its mark is on the same
  // cell, once its row is on his screen.
  await expectMarkOn(alan, cellOf(alan, name, 2));
  await header(alan, "customers", "name").click();
  await header(alan, "customers", "name").click();
  await expect(header(alan, "customers", "name")).toHaveAttribute("aria-sort", "descending");
  await expect(alan.locator("#threads .issho-thread .issho-thread-place-label")).toHaveText(`City of ${name}`);
  await expect(alan.locator("#threads .issho-comment")).toContainText("Is this the right city?");
  await expect(alan.locator(".issho-comment-mark")).toBeHidden();
  await grid(alan, "customers").evaluate((el) => el.scrollTo(0, el.scrollHeight));
  await expectMarkOn(alan, cellOf(alan, name, 2));

  // A click on the mark opens the thread.
  await alan.locator(".issho-comment-mark").click();
  await expect(alan.locator("#threads .issho-thread[data-focused]")).toHaveCount(1);
  expect(errors).toEqual([]);
});

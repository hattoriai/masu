import { expect, test } from "@playwright/test";
import { grid, header, rowText, settled } from "./support";

// A slow source read in a task (the Slow page, `load={:async}`), and a
// controlled grid (the Controlled page, `on_query`): the LiveView runs
// its query, a thousand rows a page, one sort at a time.

async function openGrid(page: import("@playwright/test").Page, path: string, id: string): Promise<void> {
  await page.goto(path);
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible();
  await expect(page.locator(`#${id}-state .masu-running`)).toHaveCount(0, { timeout: 10_000 });
  await expect(page.locator(`#${id} .masu-body .masu-row`).first()).toBeVisible();
}

test.describe("a slow source, read in a task", () => {
  test("a sort runs while the page answers, says so, and shows its rows when they come", async ({ page }) => {
    await openGrid(page, "/slow?delay=600", "slow");
    const before = await rowText(page, "slow", 0);

    await header(page, "slow", "seats").click();
    const running = page.locator('#slow-state .masu-running[role="status"]');
    await expect(running).toContainText("Running…");
    await expect(page.locator("#slow")).toHaveClass(/masu-busy/);
    // The old rows stay until the new ones come.
    expect(await rowText(page, "slow", 0)).toEqual(before);

    await expect(running).toHaveCount(0, { timeout: 10_000 });
    await expect(page.locator("#slow")).not.toHaveClass(/masu-busy/);
    await expect(header(page, "slow", "seats")).toHaveAttribute("aria-sort", "ascending");
    expect(Number((await rowText(page, "slow", 0))[2])).toBe(1);
  });

  test("Stop keeps the rows and the order it had", async ({ page }) => {
    await openGrid(page, "/slow?delay=1500", "slow");
    const before = await rowText(page, "slow", 0);

    await header(page, "slow", "seats").click();
    await page.locator("#slow-state .masu-state-button", { hasText: "Stop" }).click();
    await expect(page.locator("#slow-state .masu-running")).toHaveCount(0);
    await expect(page.locator("#slow")).not.toHaveClass(/masu-busy/);
    await expect(header(page, "slow", "seats")).toHaveAttribute("aria-sort", "none");
    expect(await rowText(page, "slow", 0)).toEqual(before);
  });

  test("scrolling far reads the rows it lacks in tasks", async ({ page }) => {
    await openGrid(page, "/slow?delay=100", "slow");
    await grid(page, "slow").evaluate((el) => (el.scrollTop = 36 * 50_000));
    const row = page.locator('#slow .masu-body .masu-row[aria-rowindex="50003"]');
    await expect(row).toBeVisible({ timeout: 10_000 });
    await expect(row).not.toHaveClass(/masu-loading/, { timeout: 10_000 });
  });
});

test.describe("a controlled grid", () => {
  test("the person's sort goes to the LiveView, which runs its query once, and the grid shows its rows", async ({ page }) => {
    await openGrid(page, "/controlled", "controlled");
    const runs = page.locator("#runs");
    await expect(runs).toHaveText("1");
    await expect(grid(page, "controlled")).toHaveAttribute("aria-rowcount", "100001");

    await header(page, "controlled", "seats").click();
    await expect(page.locator("#controlled-state .masu-running")).toContainText("Running…");
    await settled(page, "controlled");
    await expect(page.locator("#controlled-state .masu-running")).toHaveCount(0, { timeout: 10_000 });
    await expect(runs).toHaveText("2");
    await expect(header(page, "controlled", "seats")).toHaveAttribute("aria-sort", "ascending");
    expect(Number((await rowText(page, "controlled", 0))[3])).toBe(1);

    // One sort at a time: Shift adds none.
    await header(page, "controlled", "name").click({ modifiers: ["Shift"] });
    await expect(page.locator("#controlled-state .masu-running")).toHaveCount(0, { timeout: 10_000 });
    await expect(runs).toHaveText("3");
    await expect(header(page, "controlled", "name")).toHaveAttribute("aria-sort", "ascending");
    await expect(header(page, "controlled", "seats")).toHaveAttribute("aria-sort", "none");
  });

  test("the pager goes to the LiveView's next page of a thousand", async ({ page }) => {
    await openGrid(page, "/controlled", "controlled");
    await page.locator("#controlled .masu-pager").getByRole("button", { name: "Next" }).click();
    await expect(page.locator("#controlled-state .masu-running")).toHaveCount(0, { timeout: 10_000 });
    await expect(page.locator("#runs")).toHaveText("2");
    await expect(page.locator("#controlled .masu-pager-range")).toHaveText("1,001–2,000 of 100,000");
    await expect(page.locator('#controlled .masu-body .masu-row[aria-rowindex="1002"]')).toBeVisible();
  });
});

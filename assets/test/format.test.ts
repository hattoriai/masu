import { test } from "node:test";
import assert from "node:assert/strict";
import { copyText, formatter } from "../src/format";

test("numbers are grouped in the locale", () => {
  assert.equal(formatter("integer", "en-US")(1234567), "1,234,567");
  assert.equal(formatter("integer", "de-DE")(1234567), "1.234.567");
  assert.equal(formatter("number", "en-US")(0.1 + 0.2), "0.3");
  assert.equal(formatter("number", "en-US")(null), "");
});

test("decimals keep the digits the server sent", () => {
  const format = formatter("decimal", "en-US");
  assert.equal(format("120.50"), "120.50");
  assert.equal(format("-3.250"), "-3.250");
  assert.equal(format("1234"), "1,234");
  assert.equal(format("12345678901234567890.12"), "12,345,678,901,234,567,890.12");
  assert.equal(format("n/a"), "n/a");
});

test("dates do not move with the time zone, datetimes without one are read as written", () => {
  assert.equal(formatter("date", "en-US")("2026-10-17"), "Oct 17, 2026");
  assert.equal(formatter("date", "en-GB")("1815-12-10"), "10 Dec 1815");
  assert.equal(formatter("datetime", "en-US")("2026-10-17T09:05:00"), "Oct 17, 2026, 9:05 AM");
  assert.equal(formatter("time", "en-GB")("14:30:00"), "14:30");
  assert.equal(formatter("date", "en-US")("not a date"), "not a date");
});

test("booleans show a check mark, and copy as TRUE and FALSE", () => {
  assert.equal(formatter("boolean", "en")(true), "✓");
  assert.equal(formatter("boolean", "en")(false), "");
  assert.equal(copyText(true), "TRUE");
  assert.equal(copyText(false), "FALSE");
  assert.equal(copyText(null), "");
  assert.equal(copyText(12.5), "12.5");
});

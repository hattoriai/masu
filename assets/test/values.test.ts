import { test } from "node:test";
import assert from "node:assert/strict";
import { invalid, matching } from "../src/parse";
import { formatter } from "../src/format";

test("a value the server would refuse is caught before the round trip", () => {
  assert.equal(invalid("integer", "12", null), null);
  assert.equal(invalid("integer", "1.5", null), "invalid_integer");
  assert.equal(invalid("decimal", "12.50", null), null);
  assert.equal(invalid("decimal", "twelve", null), "invalid_number");
  assert.equal(invalid("number", "1e3", null), null);
  assert.equal(invalid("date", "2026-02-28", null), null);
  assert.equal(invalid("date", "2026-02-30", null), "invalid_date");
  assert.equal(invalid("date", "3/4/2026", null), "invalid_date");
  assert.equal(invalid("time", "23:59", null), null);
  assert.equal(invalid("time", "24:00", null), "invalid_time");
  assert.equal(invalid("datetime", "2026-01-01T10:00:00.000Z", null), null);
  assert.equal(invalid("datetime", "soon", null), "invalid_datetime");
  assert.equal(invalid("enum", "done", ["todo", "done"]), null);
  assert.equal(invalid("enum", "later", ["todo", "done"]), "invalid_value");
  // An enum without values takes any; an empty value is the server's to judge.
  assert.equal(invalid("enum", "later", null), null);
  assert.equal(invalid("integer", null, null), null);
  assert.equal(invalid("text", "anything", null), null);
});

test("an enum's values that match what is typed: those that start with it first", () => {
  const values = ["todo", "doing", "review", "done"];
  assert.deepEqual(matching(values, ""), values);
  assert.deepEqual(matching(values, "do"), ["doing", "done", "todo"]);
  assert.deepEqual(matching(values, "VIEW"), ["review"]);
  assert.deepEqual(matching(values, "zzz"), []);
});

test("a column of decimals shows that many digits, whatever the value has", () => {
  const one = formatter("decimal", "en-US", 1);
  assert.equal(one("2.25"), "2.3");
  assert.equal(one("3"), "3.0");
  assert.equal(one(null), "");
  const two = formatter("number", "de-DE", 2);
  assert.equal(two(1234.5), "1.234,50");
  // Without decimals, a decimal keeps the digits the server sent.
  assert.equal(formatter("decimal", "en-US")("120.50"), "120.50");
});

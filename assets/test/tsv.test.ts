import { test } from "node:test";
import assert from "node:assert/strict";
import { toTSV } from "../src/tsv";

test("joins cells with tabs and rows with line breaks", () => {
  assert.equal(toTSV([["a", "1"], ["b", "2"]]), "a\t1\nb\t2");
});

test("quotes a cell with a tab, a line break or a quote, as spreadsheets do", () => {
  assert.equal(toTSV([["a\tb", 'say "hi"', "one\ntwo", "plain"]]), '"a\tb"\t"say ""hi"""\t"one\ntwo"\tplain');
});

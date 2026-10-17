# Lotus Web's results table

The reference for the theming spec (`specs/look.spec.ts`): Masu's grid,
themed with the tokens of the Theming guide, against Lotus Web's results
table, pixel for pixel.

* `table.html`: the table's markup and classes, as Lotus Web renders them
  (`lib/lotus/web/live/queries/results_component.ex`), with its columns'
  widths fixed so that both tables have the same geometry.
* `table.css`: Lotus Web's CSS for it, built from its sources.
* `Inter.woff2`: Lotus Web's font (`assets/fonts/Inter.woff2`, Inter by
  Rasmus Andersson, SIL Open Font License 1.1). The spec loads it in both
  pages, so that the tables are drawn in the same font on any machine.

To build `table.css` again, from a checkout of lotus_web, with Tailwind 3
and its forms and typography plugins installed (`NODE_PATH`):

```sh
cd lotus_web/assets
sed '/@import "..\/..\/deps/d' css/app.css > /tmp/app.css
cat > /tmp/ref.config.js <<'JS'
const base = require("./tailwind.config.js");
module.exports = { ...base, content: ["path/to/masu/e2e/fixtures/lotus/table.html"] };
JS
npx tailwindcss --config=/tmp/ref.config.js --input=/tmp/app.css --output=/tmp/table.css
```

then remove its `@font-face` rules (the spec loads the font itself).

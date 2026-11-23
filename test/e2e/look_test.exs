defmodule MasuE2E.LookTest do
  use MasuE2E.Case, async: true, parameterize: MasuE2E.Case.projects()

  # Masu in another app's look: its grid, themed with tokens only, against
  # Lotus Web's results table (e2e/fixtures/lotus), pixel for pixel.

  @fixtures Path.expand("../../e2e/fixtures/lotus", __DIR__)
  @external_resource Path.join(@fixtures, "table.css")
  @external_resource Path.join(@fixtures, "table.html")
  @external_resource Path.join(@fixtures, "Inter.woff2")
  @css File.read!(Path.join(@fixtures, "table.css"))
  @table File.read!(Path.join(@fixtures, "table.html"))
  # Lotus Web's own font, on both pages: with the fonts of the machine, the
  # two tables would be drawn in whichever one it has.
  @font Base.encode64(File.read!(Path.join(@fixtures, "Inter.woff2")))
  @font_face ~s|@font-face { font-family: "Inter var"; font-style: normal; font-weight: 100 900; src: url(data:font/woff2;base64,#{@font}) format("woff2"); }|

  defp with_font(page) do
    Page.add_style_tag!(page, content: @font_face)

    Page.evaluate!(page, """
    async () => {
      await Promise.all([document.fonts.load('400 14px "Inter var"'), document.fonts.load('600 14px "Inter var"')]);
      await document.fonts.ready;
    }
    """)
  end

  # The share of pixels that differ by more than a few levels in a channel,
  # except on the lines `skip` (in CSS pixels, of a picture `css_height` high).
  @difference """
  async ([a, b, cssHeight, skip]) => {
    const load = (data) =>
      new Promise((resolve) => {
        const img = new Image();
        img.onload = () => resolve(img);
        img.src = `data:image/png;base64,${data}`;
      });
    const [ia, ib] = await Promise.all([load(a), load(b)]);
    const width = Math.max(ia.width, ib.width);
    const height = Math.max(ia.height, ib.height);
    const pixels = (img) => {
      const canvas = document.createElement("canvas");
      canvas.width = width;
      canvas.height = height;
      const ctx = canvas.getContext("2d");
      ctx.drawImage(img, 0, 0);
      return ctx.getImageData(0, 0, width, height);
    };
    const pa = pixels(ia).data;
    const pb = pixels(ib).data;
    const out = document.createElement("canvas");
    out.width = width;
    out.height = height;
    const octx = out.getContext("2d");
    const diff = octx.createImageData(width, height);
    // A pixel matches when a pixel within one of it in the other image is
    // close to it: text drawn with other anti-aliasing (a composited row
    // draws in grayscale) matches; a colour, a line or a place that
    // differs does not.
    const close = (p, q, x, y) => {
      const i = (y * width + x) * 4;
      for (let dy = -1; dy <= 1; dy++) {
        for (let dx = -1; dx <= 1; dx++) {
          const nx = x + dx;
          const ny = y + dy;
          if (nx < 0 || ny < 0 || nx >= width || ny >= height) continue;
          const j = (ny * width + nx) * 4;
          const delta = Math.max(Math.abs(p[i] - q[j]), Math.abs(p[i + 1] - q[j + 1]), Math.abs(p[i + 2] - q[j + 2]));
          if (delta <= 48) return true;
        }
      }
      return false;
    };
    let different = 0;
    // The lines that differ over most of their width, to name in a failure.
    const lines = [];
    const rgb = (p, x, y) => {
      const i = (y * width + x) * 4;
      return `rgb(${p[i]} ${p[i + 1]} ${p[i + 2]})`;
    };
    for (let y = 0; y < height; y++) {
      // A screenshot can be at twice the CSS pixels (WebKit's is).
      if (skip.includes(Math.floor((y * cssHeight) / height))) continue;
      const before = different;
      for (let x = 0; x < width; x++) {
        const i = (y * width + x) * 4;
        const off = !close(pa, pb, x, y) || !close(pb, pa, x, y);
        if (off) different += 1;
        diff.data[i] = off ? 255 : pa[i] * 0.2;
        diff.data[i + 1] = off ? 0 : pa[i + 1] * 0.2;
        diff.data[i + 2] = off ? 0 : pa[i + 2] * 0.2;
        diff.data[i + 3] = 255;
      }
      if (different - before > width / 2) {
        const x = Math.floor(width / 2);
        lines.push(`${y} (reference ${rgb(pa, x, y)}, grid ${rgb(pb, x, y)})`);
      }
    }
    octx.putImageData(diff, 0, 0);
    return { ratio: different / (width * height), diff: out.toDataURL(), lines };
  }
  """

  defp difference(page, a, b, css_height, skip) do
    Page.evaluate!(page, @difference, [Base.encode64(a), Base.encode64(b), css_height, skip])
  end

  # `(ratio * 100).toFixed(3)`
  defp percent(ratio), do: :erlang.float_to_binary(ratio * 100 / 1, decimals: 3)

  defp data_url_body(data_url),
    do: data_url |> String.split(",") |> Enum.at(1) |> Base.decode64!()

  for mode <- ["light", "dark"] do
    @tag mode: mode
    test "a grid themed with tokens looks like Lotus Web's table (#{mode})",
         %{browser_name: browser_name, mode: mode} = ctx do
      # WebKit draws no box-shadow on a table's row group, so Lotus Web's
      # header has no line under it there (y = 48), where Masu's has.
      skip = if browser_name == :webkit, do: [48], else: []
      lotus = Browser.new_page!(ctx.browser, viewport: %{width: 800, height: 600})

      Page.set_content!(
        lotus,
        ~s(<!doctype html><html lang="en" data-lotus-theme="lotus" class="#{if mode == "dark", do: "dark", else: ""}"><head><style>#{@css}</style></head><body style="margin:0">#{@table}</body></html>)
      )

      with_font(lotus)
      lotus |> Page.mouse() |> Mouse.move!(799, 599)
      reference = Page.locator(lotus, "#lotus")
      reference_box = Locator.bounding_box!(reference)
      a = Locator.screenshot!(reference)

      page = Browser.new_page!(ctx.browser, viewport: %{width: 800, height: 600})
      open_page(page, "/look")

      if mode == "dark",
        do: Page.evaluate!(page, ~s|() => document.documentElement.classList.add("dark")|)

      with_font(page)
      page |> Page.mouse() |> Mouse.move!(799, 599)
      grid = Page.locator(page, "#look .masu-grid")
      # The grid at the page's corner, on whole pixels as the reference is
      # (a grid at half a pixel is drawn half a pixel off).
      Page.locator(page, "#look")
      |> Locator.evaluate!(
        ~s|(el) => Object.assign(el.style, { position: "fixed", top: "0", left: "0", width: "660px" })|
      )

      grid_box = Locator.bounding_box!(grid)
      assert [grid_box.width, grid_box.height] == [reference_box.width, reference_box.height]
      b = Locator.screenshot!(grid)

      %{"ratio" => ratio, "diff" => diff, "lines" => lines} =
        difference(page, a, b, grid_box.height, skip)

      Test.attach("lotus-#{mode}.png", body: a, content_type: "image/png")
      Test.attach("masu-#{mode}.png", body: b, content_type: "image/png")
      Test.attach("diff-#{mode}.png", body: data_url_body(diff), content_type: "image/png")
      File.write!(Test.output_path("lotus-#{mode}.png"), a)
      File.write!(Test.output_path("masu-#{mode}.png"), b)
      File.write!(Test.output_path("diff-#{mode}.png"), data_url_body(diff))
      IO.puts("#{mode}: #{percent(ratio)}% of pixels differ")
      assert ratio < 0.002, "lines that differ: #{Enum.join(lines, ", ")}"

      # A cell under the pointer: Lotus's hover, on the cell.
      lotus |> Page.mouse() |> Mouse.move!(reference_box.x + 200, reference_box.y + 48 + 52 + 26)
      page |> Page.mouse() |> Mouse.move!(grid_box.x + 200, grid_box.y + 48 + 52 + 26)
      # Lotus's colours change in 150ms.
      Page.wait_for_timeout!(lotus, 400)

      hovered =
        difference(
          page,
          Locator.screenshot!(reference),
          Locator.screenshot!(grid),
          grid_box.height,
          skip
        )

      File.write!(Test.output_path("diff-hover-#{mode}.png"), data_url_body(hovered["diff"]))
      IO.puts("#{mode}, hovered: #{percent(hovered["ratio"])}% of pixels differ")
      assert hovered["ratio"] < 0.002, "lines that differ: #{Enum.join(hovered["lines"], ", ")}"
    end
  end
end

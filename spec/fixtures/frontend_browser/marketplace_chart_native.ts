interface NativeChart extends HTMLElement {
  data?: Array<{
    type?: string;
    orientation?: string;
    x?: unknown[];
    y?: unknown[];
    values?: unknown[];
  }>;
  _fullData?: NativeChart["data"];
}

(async () => {
  const read = () =>
    [...document.querySelectorAll<NativeChart>(".js-plotly-plot")].map((plot) =>
      (plot._fullData || plot.data || []).map((trace) => ({
        type: trace.type,
        orientation: trace.orientation,
        x: trace.x,
        y: trace.y,
        values: (
          trace.values ||
          (trace.orientation === "h" ? trace.x : trace.y) ||
          []
        )
          .map(Number)
          .sort((a, b) => a - b),
      })),
    );
  const wait = async (expected: number[]) => {
    const deadline = Date.now() + 30000;
    while (Date.now() < deadline) {
      const plots = read();
      if (
        plots.length === 3 &&
        plots.every(
          (series) =>
            series.length > 0 &&
            series.every(
              (trace) =>
                JSON.stringify(trace.values) === JSON.stringify(expected),
            ),
        )
      )
        return plots;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    throw new Error(`Native chart data mismatch: ${JSON.stringify(read())}`);
  };
  const before = await wait([10, 20]);
  const button = [
    ...document.querySelectorAll<HTMLButtonElement>("button"),
  ].find((element) => element.textContent?.trim() === "Add chart point");
  if (!button) throw new Error("Native chart action button not found");
  button.click();
  const after = await wait([10, 20, 40]);
  return { status: "passed", before, after };
})();

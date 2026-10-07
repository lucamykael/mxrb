interface CustomPlot extends HTMLElement {
  data: Array<{ name: string; y: number[] }>;
  _fullLayout: {
    title: { text: string };
    yaxis: { range: number[] };
    width: number;
    height: number;
  };
  _context: { displayModeBar: boolean; scrollZoom: boolean };
  emit(name: string, event: unknown): void;
}
(async () => {
  const wait = async (name: string) => {
    const deadline = Date.now() + 30000;
    while (Date.now() < deadline) {
      const graph = document.querySelector<CustomPlot>(".js-plotly-plot");
      if (graph?.data?.[1]?.name === name) return graph;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    throw new Error(`Missing custom trace ${name}`);
  };
  const graph = await wait("Dynamic");
  const snapshot = () => ({
    traces: graph.data.map(({ name, y }) => ({ name, y })),
    title: graph._fullLayout.title.text,
    range: graph._fullLayout.yaxis.range,
    width: graph._fullLayout.width,
    height: graph._fullLayout.height,
    modebar: graph._context.displayModeBar,
    zoom: graph._context.scrollZoom,
  });
  const before = snapshot();
  if (
    before.traces.length !== 2 ||
    before.traces[0].name !== "Static" ||
    before.title !== "Dynamic title" ||
    !before.modebar ||
    !before.zoom ||
    before.width !== 800 ||
    before.height !== 400
  )
    throw new Error(`Custom options mismatch ${JSON.stringify(before)}`);
  graph.emit("plotly_click", { points: [{ bbox: { x0: 10, x1: 20 } }] });
  await new Promise((resolve) => setTimeout(resolve, 500));
  const event = document.querySelector<HTMLInputElement>(
    ".mx-name-Event input",
  )?.value;
  const clicks = document.querySelector<HTMLInputElement>(
    ".mx-name-Clicks input",
  )?.value;
  if (event !== "" || clicks !== "1")
    throw new Error(`Click mismatch ${event} ${clicks}`);
  const button = [
    ...document.querySelectorAll<HTMLButtonElement>("button"),
  ].find((node) => node.textContent?.trim() === "Change traces");
  if (!button) throw new Error("Missing Change traces");
  button.click();
  await wait("Changed");
  return { status: "passed", before, after: snapshot(), event, clicks };
})();

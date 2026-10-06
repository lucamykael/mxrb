interface SeriesPlot extends HTMLElement {
  _fullData?: Array<{ name: string; x: unknown[]; y: unknown[] }>;
}
(async () => {
  const names = ['LineChart', 'ColumnChart'];
  const beforeExpected = { 'Region North': { A: 30, B: 8 }, 'Region South': { A: 5, B: 15 } };
  const afterExpected = { 'Region North': { A: 37, B: 8 }, 'Region South': { A: 5, B: 15 }, 'Region East': { C: 12 } };
  const read = () => Object.fromEntries(names.map((name) => {
    const plot = document.querySelector<SeriesPlot>(`.mx-name-Dynamic_${name} .js-plotly-plot`);
    return [name, Object.fromEntries((plot?._fullData ?? []).map((trace) => [trace.name,
      Object.fromEntries(trace.x.map((label, index) => [String(label), Number(trace.y[index])]))]))];
  }));
  const wait = async (expected: Record<string, Record<string, number>>) => {
    const deadline = Date.now() + 30000;
    while (Date.now() < deadline) {
      const actual = read();
      if (names.every((name) => Object.keys(actual[name]).length === Object.keys(expected).length &&
        Object.entries(expected).every(([series, points]) =>
          Object.keys(actual[name][series] ?? {}).length === Object.keys(points).length &&
          Object.entries(points).every(([label, value]) => actual[name][series]?.[label] === value)))) return actual;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    throw new Error(`Dynamic series mismatch: ${JSON.stringify(read())}`);
  };
  const before = await wait(beforeExpected);
  const button = [...document.querySelectorAll<HTMLButtonElement>('button')]
    .find((element) => element.textContent?.trim() === 'Add series value');
  if (!button) throw new Error('Dynamic series action not found');
  button.click();
  const after = await wait(afterExpected);
  return { status: 'passed', before, after };
})();

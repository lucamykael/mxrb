interface AggregatePlot extends HTMLElement { _fullData?: Array<{x: unknown[]; y: unknown[]}>; }
(async () => {
  const beforeExpected = {"count": [4, 3], "sum": [80, 30], "avg": [20, 10], "min": [10, 5], "max": [40, 20], "median": [15, 5], "mode": [10, 5], "first": [10, 5], "last": [40, 20]};
  const afterExpected = {"count": [5, 3], "sum": [180, 30], "avg": [36, 10], "min": [10, 5], "max": [100, 20], "median": [20, 5], "mode": [10, 5], "first": [10, 5], "last": [100, 20]};
  const read = () => Object.fromEntries(Object.keys(beforeExpected).map((kind) => {
    const plot = document.querySelector<AggregatePlot>(`.mx-name-Aggregate_${kind} .js-plotly-plot`);
    const data = plot?._fullData?.[0];
    return [kind, data ? Object.fromEntries(data.x.map((category, i) => [String(category), Number(data.y[i])])) : null];
  }));
  const wait = async (expected: Record<string, number[]>) => {
    const deadline = Date.now() + 30000;
    while (Date.now() < deadline) {
      const actual = read();
      if (Object.entries(expected).every(([kind, [a, b]]) => actual[kind]?.A === a && actual[kind]?.B === b)) return actual;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    throw new Error(`Aggregate mismatch: ${JSON.stringify(read())}`);
  };
  const before = await wait(beforeExpected);
  const button = [...document.querySelectorAll<HTMLButtonElement>('button')].find((element) => element.textContent?.trim() === 'Add aggregate value');
  if (!button) throw new Error('Aggregate action not found');
  button.click();
  const after = await wait(afterExpected);
  return { status: 'passed', before, after };
})();

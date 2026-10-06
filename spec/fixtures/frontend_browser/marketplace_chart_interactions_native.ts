interface InteractivePlot extends HTMLElement {
  _fullData?: Array<{ name: string; x: unknown[]; y: unknown[] }>;
  calcdata?: Array<Array<{ b: number; s: number }>>;
  emit(name: string, event: unknown): void;
}
(async () => {
  const names = ['ColumnChart', 'BarChart'];
  const plot = (name: string) => document.querySelector<InteractivePlot>(`.mx-name-Stacked_${name} .js-plotly-plot`)!;
  const read = () => Object.fromEntries(names.map((name) => [name,
    Object.fromEntries((plot(name)?._fullData ?? []).map((trace) => [trace.name,
      Object.fromEntries((name === 'BarChart' ? trace.y : trace.x).map((label, index) =>
        [String(label), Number((name === 'BarChart' ? trace.x : trace.y)[index])]))]))]));
  const wait = async (north: number, south: number, east = false) => {
    const deadline = Date.now() + 30000;
    while (Date.now() < deadline) {
      const data = read();
      if (names.every((name) => data[name]['Region North']?.A === north &&
        data[name]['Region North']?.B === 8 && data[name]['Region South']?.A === south &&
        data[name]['Region South']?.B === 15 && (!east || data[name]['Region East']?.C === 12))) return data;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    throw new Error(`Chart interaction mismatch: ${JSON.stringify(read())}`);
  };
  const before = await wait(30, -5);
  const stacks = names.map((name) => plot(name).calcdata?.[1]?.[0]);
  if (stacks.some((point) => point?.b !== 30 || point.s !== -5))
    throw new Error(`Stack geometry mismatch: ${JSON.stringify(stacks)}`);
  // Exercise the actual Plotly click listener and Mendix action/refresh pipeline.
  plot('ColumnChart').emit('plotly_click', { points: [{ curveNumber: 0, pointIndex: 1 }] });
  const firstClick = await wait(31, -5);
  plot('BarChart').emit('plotly_click', { points: [{ curveNumber: 1, pointIndex: 0 }] });
  const secondClick = await wait(31, -4);
  const button = [...document.querySelectorAll<HTMLButtonElement>('button')]
    .find((element) => element.textContent?.trim() === 'Add series value');
  if (!button) throw new Error('Add series value action is missing');
  button.click();
  const after = await wait(38, -4, true);
  return { status: 'passed', before, stacks, firstClick, secondClick, after };
})();

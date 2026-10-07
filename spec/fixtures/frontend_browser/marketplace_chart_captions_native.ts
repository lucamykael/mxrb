interface CaptionPlot extends HTMLElement {
  _fullData?: Array<{ name: string; y: number[] }>;
}
(async () => {
  const wait = async (amount: number, caption: string) => {
    const deadline = Date.now() + 30000;
    while (Date.now() < deadline) {
      const trace = document.querySelector<CaptionPlot>('.mx-name-Formatted .js-plotly-plot')?._fullData?.[0];
      if (trace?.name === caption && trace.y[0] === amount) return { name: trace.name, value: trace.y[0] };
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    const actual = document.querySelector<CaptionPlot>('.mx-name-Formatted .js-plotly-plot')?._fullData;
    throw new Error(`Formatted caption mismatch: ${JSON.stringify(actual?.map(({ name, y }) => ({ name, y })))}`);
  };
  const before = await wait(1234.5, 'North: 1,234.500 on 2026-10-06 by Owner');
  const button = [...document.querySelectorAll<HTMLButtonElement>('button')]
    .find((element) => element.textContent?.trim() === 'Change amount');
  if (!button) throw new Error('Change amount action is missing');
  button.click();
  const after = await wait(1235.5, 'North: 1,235.500 on 2026-10-06 by Owner');
  return { status: 'passed', before, after };
})();

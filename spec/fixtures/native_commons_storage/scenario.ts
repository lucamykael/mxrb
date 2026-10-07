(async () => {
  const waitFor = async (check: () => boolean) => {
    for (let i = 0; i < 200; i += 1) {
      if (check()) return;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    throw new Error('Storage action timed out');
  };
  const results: { action: string; message: string; stored: string | null }[] = [];
  for (const [name, expected] of [
    ['Clear', 'true'], ['Exists', 'false'], ['Write', 'Written'],
    ['Read', 'Olá 世界 🌍'], ['Exists', 'true'], ['Remove', 'true'],
    ['Exists', 'false'], ['Write', 'Written'], ['Clear', 'true'], ['Exists', 'false'],
  ]) {
    const button = document.querySelector<HTMLButtonElement>(`.mx-name-${name}`);
    if (!button) throw new Error(`Missing action ${name}`);
    button.click();
    await waitFor(() => [...document.querySelectorAll('.modal-dialog')].some(node => node.textContent?.includes(expected)));
    const stored = localStorage.getItem('mxrb-storage-oracle');
    const expectedStored = name === 'Write' || name === 'Read' || (name === 'Exists' && expected === 'true') ? 'Olá 世界 🌍' : null;
    if (stored !== expectedStored) throw new Error(`Unexpected storage after ${name}: ${stored}`);
    results.push({ action: name, message: expected, stored });
    const confirm = document.querySelector<HTMLButtonElement>('.modal-dialog button.btn-primary');
    if (!confirm) throw new Error('Missing confirmation');
    confirm.click();
    await waitFor(() => document.querySelector('.modal-dialog') === null);
  }
  return { status: 'passed', results };
})();

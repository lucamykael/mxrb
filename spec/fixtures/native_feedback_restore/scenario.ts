declare const mx: { data: Record<string, (options: Record<string, unknown>) => void> };
type NativeObject = { getGuid(): string; set(name: string, value: unknown): void };
(async () => {
  const invoke = (name: string, options: Record<string, unknown>) =>
    new Promise<any>((resolve, reject) => mx.data[name]({ ...options, callback: resolve, error: reject }));
  const waitFor = async (predicate: () => boolean) => {
    for (let attempt = 0; attempt < 200; attempt++) {
      if (predicate()) return;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    throw new Error('Restore oracle timed out');
  };
  const key = 'mxrb-restore-oracle';
  const results: unknown[] = [];
  for (const variant of ['ReadLegacy', 'ReadCurrent']) {
    const object: NativeObject = await invoke('create', { entity: 'FeedbackModule.Probe' });
    const current = { Name: 'Current', Active: false, Count: '12', Amount: '9007199254740993.12345678', When: 1767323045000 };
    for (const [name, value] of Object.entries(current)) object.set(name, value);
    await invoke('commit', { mxobj: object });
    const guid = object.getGuid();
    const read = async () => {
      document.querySelector<HTMLButtonElement>('.mx-name-' + variant)!.click();
      await waitFor(() => document.querySelector('.modal-dialog') !== null);
      const message = document.querySelector('.modal-dialog .modal-body')!.textContent!.trim();
      document.querySelector<HTMLButtonElement>('.modal-dialog button.btn-primary')!.click();
      await waitFor(() => document.querySelector('.modal-dialog') === null);
      return { message, stored: JSON.parse(localStorage.getItem(key)!) };
    };
    localStorage.setItem(key, JSON.stringify({ guid, ...current, Name: 'Stale' }));
    const existing = await read();
    if (existing.stored.guid !== guid || existing.stored.Name !== 'Current') throw new Error('Existing object was overwritten');
    await invoke('remove', { guid });
    const restored = await read();
    if (restored.stored.guid === guid || restored.stored.Name !== 'Current') throw new Error('Object was not recreated');
    const repeated = await read();
    if (repeated.stored.guid !== restored.stored.guid) throw new Error('Restored identity was lost');
    for (const result of [existing, restored, repeated]) {
      if (result.stored.Amount !== current.Amount || result.stored.Count !== '12' || result.stored.Active !== false || result.stored.When !== current.When)
        throw new Error('Restored value mismatch');
    }
    results.push({ variant, existing_guid_preserved: true, missing_guid_replaced: true, repeated_guid_preserved: true,
      existing: existing.message, restored: restored.message, repeated: repeated.message,
      values: { ...restored.stored, guid: '<generated>' } });
  }
  return { status: 'passed', results };
})();

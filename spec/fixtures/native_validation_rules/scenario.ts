interface NativeObject {
  set(name: string, value: unknown): void;
  getGuid(): string;
}
declare const mx: { data: Record<string, (options: Record<string, unknown>) => void> };
interface ProbeResult { label: string; accepted: boolean; expected: boolean; error?: string }

(async () => {
  const call = <T = unknown>(method: string, args: Record<string, unknown>) => new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(method + ' timed out')), 10000);
    mx.data[method]({...args, callback: (value: T) => {clearTimeout(timer); resolve(value)},
      error: (error: Error) => {clearTimeout(timer); reject(error)},
      onValidation: (validations: unknown) => {clearTimeout(timer); reject(new Error('validation ' + JSON.stringify(validations)))}});
  });
  const results: ProbeResult[] = [];
  const saved: string[] = [];
  async function probe(label: string, entity: string, attributes: Record<string, unknown>, expected: boolean) {
    const object = await call<NativeObject>('create', {entity});
    for (const [key,value] of Object.entries(attributes)) object.set(key, value);
    let accepted = false;
    let error: string | undefined;
    try { await call('commit', {mxobj: object}); accepted = true; saved.push(object.getGuid()); }
    catch (failure) { error = String(failure instanceof Error ? failure.message : failure); }
    results.push({label, accepted, expected, error});
  }
  try {
    await probe('required-blank', 'Rules.Child', {Name: ' \t '}, false);
    await probe('required-unicode-space', 'Rules.Child', {Name: '\u2003'}, false);
    await probe('required-nonbreaking-space', 'Rules.Child', {Name: '\u00a0'}, true);
    await probe('required-figure-space', 'Rules.Child', {Name: '\u2007'}, true);
    await probe('required-zero-width-space', 'Rules.Child', {Name: '\u200b'}, true);
    await probe('unique-first-child', 'Rules.Child', {Name: 'Native unique'}, true);
    await probe('unique-across-sibling', 'Rules.Sibling', {Name: 'Native unique'}, false);
    await probe('range-minimum', 'Rules.Range', {Amount: 1.5, Limit: 2.5}, true);
    await probe('range-maximum', 'Rules.Range', {Amount: 2.5, Limit: 2.5}, true);
    await probe('range-below', 'Rules.Range', {Amount: 1.4, Limit: 2.5}, false);
    await probe('range-above', 'Rules.Range', {Amount: 2.6, Limit: 2.5}, false);
    await probe('range-empty', 'Rules.Range', {Amount: null, Limit: 2.5}, true);
    await probe('equals-match', 'Rules.Exact', {Name: 'Expected'}, true);
    await probe('equals-mismatch', 'Rules.Exact', {Name: 'Other'}, false);
    await probe('equals-empty', 'Rules.Exact', {Name: ''}, false);
    await probe('length-two-utf16', 'Rules.Length', {Name: '😀'}, true);
    await probe('length-three-utf16', 'Rules.Length', {Name: '😀a'}, false);
    await probe('length-empty', 'Rules.Length', {Name: ''}, true);
    await probe('date-minimum', 'Rules.Day', {Value: Date.parse('2026-10-05T00:00:00Z')}, true);
    await probe('date-before', 'Rules.Day', {Value: Date.parse('2026-10-04T23:59:59Z')}, false);
    await probe('date-empty', 'Rules.Day', {Value: null}, true);
    return {status: results.every(x => x.accepted === x.expected) ? 'passed' : 'mismatch', results};
  } finally {
    for (const guid of saved.reverse()) await call('remove', {guid});
  }
})()

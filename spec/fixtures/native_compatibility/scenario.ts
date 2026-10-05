declare const mx: { data: { action(options: Record<string, unknown>): void } };
(async () => {
  const expected: Record<string, string> = { Length: '3', Trim: 'Ruby', TrimEmpty: '', Lower: 'ruby', Upper: 'RUBY',
    Encode: 'a%20b%2Bc%2F%C3%A7', EncodeSymbols: '%2A~%21%28%29',
    Decode: 'a b+c/ç', DecodeSpaces: 'a b+c/ç', VerifyRule: 'passed' };
  const results = [];
  for (const [name, value] of Object.entries(expected)) {
    const actual = await new Promise<string>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`${name} timed out`)), 10000);
      mx.data.action({ params: { actionname: `Compatibility.${name}`, applyto: 'none' },
        callback: (result: string) => { clearTimeout(timer); resolve(result); },
        error: (error: Error) => { clearTimeout(timer); reject(error); } });
    });
    results.push({ name, actual, expected: value, passed: actual === value });
  }
  return { status: results.every(result => result.passed) ? 'passed' : 'mismatch', results };
})()

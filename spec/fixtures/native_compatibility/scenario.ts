declare const mx: { data: { action(options: Record<string, unknown>): void } };
type OracleCase = { name: string; expected?: string; expected_error?: boolean };
(async () => {
  const cases: OracleCase[] = [
  {
    "name": "Length",
    "expected": "3"
  },
  {
    "name": "Trim",
    "expected": "Ruby"
  },
  {
    "name": "TrimEmpty",
    "expected": ""
  },
  {
    "name": "Lower",
    "expected": "ruby"
  },
  {
    "name": "Upper",
    "expected": "RUBY"
  },
  {
    "name": "Encode",
    "expected": "a%20b%2Bc%2F%C3%A7"
  },
  {
    "name": "EncodeSymbols",
    "expected": "%2A~%21%28%29"
  },
  {
    "name": "DecodeSpaces",
    "expected": "a b+c/ç"
  },
  {
    "name": "Decode",
    "expected": "a b+c/ç"
  },
  {
    "name": "FindUnicode",
    "expected": "2"
  },
  {
    "name": "FindOffset",
    "expected": "3"
  },
  {
    "name": "FindEmptyPastEnd",
    "expected": "3"
  },
  {
    "name": "FindNegative",
    "expected": "0"
  },
  {
    "name": "FindLast",
    "expected": "3"
  },
  {
    "name": "FindLastUnicode",
    "expected": "3"
  },
  {
    "name": "SubstringUnicode",
    "expected": "ab"
  },
  {
    "name": "SubstringTail",
    "expected": "abc"
  },
  {
    "name": "SubstringBoundary",
    "expected": ""
  },
  {
    "name": "SubstringPastEnd",
    "expected_error": true
  },
  {
    "name": "SubstringTooLong",
    "expected_error": true
  },
  {
    "name": "SubstringNegative",
    "expected_error": true
  },
  {
    "name": "TrimNbsp",
    "expected": " Ruby "
  },
  {
    "name": "IfTrue",
    "expected": "chosen"
  },
  {
    "name": "IfFalse",
    "expected": "chosen"
  },
  {
    "name": "IfNested",
    "expected": "nested"
  },
  {
    "name": "IfGrouped",
    "expected": "20"
  },
  {
    "name": "AndLazy",
    "expected": "false"
  },
  {
    "name": "OrLazy",
    "expected": "true"
  },
  {
    "name": "AndEvaluated",
    "expected": "true"
  },
  {
    "name": "OrEvaluated",
    "expected": "true"
  },
  {
    "name": "DivisionNegative",
    "expected": "true"
  },
  {
    "name": "ModuloPositive",
    "expected": "2"
  },
  {
    "name": "ModuloNegative",
    "expected": "-2"
  },
  {
    "name": "ModuloNegativeDivisor",
    "expected": "2"
  },
  {
    "name": "ModuloDecimal",
    "expected": "true"
  },
  {
    "name": "VerifyRule",
    "expected": "passed"
  }
];
  const results = [];
  for (const item of cases) {
    let actual: string | undefined;
    let error: string | undefined;
    try {
      actual = await new Promise<string>((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error("timed out")), 10000);
        mx.data.action({
          params: { actionname: "Compatibility." + item.name, applyto: "none" },
          callback: (value: string) => {
            clearTimeout(timer);
            resolve(value);
          },
          error: (value: unknown) => {
            clearTimeout(timer);
            reject(value);
          },
        });
      });
    } catch (e) {
      error = String(e);
    }
    results.push({
      name: item.name,
      actual,
      error,
      expected: item.expected,
      expected_error: item.expected_error,
      passed: item.expected_error
        ? !!error && !error.includes("timed out")
        : !error && actual === item.expected,
    });
  }
  return {
    status: results.every((item) => item.passed) ? "passed" : "mismatch",
    results,
  };
})();

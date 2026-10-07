declare const mx: { data: { action(options: Record<string, unknown>): void } };
(async () => {
  const cases = [
    { name: "Case0", expected: "false" },
    { name: "Case1", expected: "true" },
    { name: "Case2", expected: "true" },
    { name: "Case3", expected: "true" },
    { name: "Case4", expected: "false" },
    { name: "Case5", expected: "false" },
    { name: "Case6", expected: "false" },
    { name: "Case7", expected: "false" },
    { name: "Case8", expected: "true" },
    { name: "Case9", expected: "true" },
    { name: "Case10", expected: "false" },
    { name: "Case11", expected: "true" },
    { name: "Case12", expected: "" },
    { name: "Case13", expected: "plain text" },
    { name: "Case14", expected: "bold" },
    { name: "Case15", expected: "safe" },
    { name: "Case16", expected: "safe" },
    { name: "Case17", expected: "line\nnext" },
    { name: "Case18", expected: "line\rnext" },
    { name: "Case19", expected: "linenext" },
    { name: "Case20", expected: "x" },
    { name: "Case21", expected: "safe" },
    { name: "Case22", expected: "Hello" },
    { name: "Case23", expected: "keep" },
    { name: "Case24", expected: "a " },
    { name: "Case25", expected: "outside  world" },
    { name: "Case26", expected: "é" },
    { name: "Case27", expected: "é " },
    { name: "Case28", expected: "x y" },
    { name: "Case29", expected: 'y">Hi' },
  ];
  const results = [];
  for (const item of cases) {
    try {
      const actual = await new Promise((resolve, reject) =>
        mx.data.action({
          params: { actionname: `FeedbackModule.${item.name}` },
          callback: resolve,
          error: reject,
        }),
      );
      results.push({ ...item, actual, passed: actual === item.expected });
    } catch (error) {
      results.push({ ...item, passed: false, error: String(error) });
    }
  }
  return {
    status: results.every((item) => item.passed) ? "passed" : "failed",
    results,
  };
})();

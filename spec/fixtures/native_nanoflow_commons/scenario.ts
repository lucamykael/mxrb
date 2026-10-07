(async () => {
  const waitFor = async (check: () => boolean) => {
    for (let i = 0; i < 200; i += 1) {
      if (check()) return;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    throw new Error("Commons action timed out");
  };
  const results: Record<string, string> = {};
  for (const [name, expected] of [
    ["Encode", "T2zDoSDkuJbnlYwg8J+MjQ=="],
    ["Decode", "Olá 世界 🌍"],
    ["PlatformName", "Web"],
    ["ObjectLookup", "Found synthetic object"],
  ]) {
    const button = document.querySelector<HTMLButtonElement>(
      `.mx-name-${name}`,
    );
    if (!button) throw new Error(`Missing action ${name}`);
    button.click();
    await waitFor(() =>
      [...document.querySelectorAll(".modal-dialog")].some((node) =>
        node.textContent?.includes(expected),
      ),
    );
    results[name] = expected;
    const confirm = document.querySelector<HTMLButtonElement>(
      ".modal-dialog button.btn-primary",
    );
    if (!confirm) throw new Error("Missing confirmation");
    confirm.click();
    await waitFor(() => document.querySelector(".modal-dialog") === null);
  }
  return { status: "passed", results };
})();

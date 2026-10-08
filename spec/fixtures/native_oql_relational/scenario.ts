import cases from "./cases.json";

export default (async () => {
  const waitFor = async (check: () => boolean) => {
    for (let attempt = 0; attempt < 300; attempt++) {
      if (check()) return;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    throw new Error("OQL relational action timed out");
  };
  const results: Record<string, string[]> = {};
  for (const item of [{ name: "Seed" }, ...cases]) {
    document.querySelector<HTMLButtonElement>(`.mx-name-${item.name}`)!.click();
    const selector = ".modal-dialog .modal-body, .mxrb-runtime-notice";
    await waitFor(() => !!document.querySelector(selector));
    const message = document.querySelector(selector)!.textContent!.trim();
    if (item.name === "Seed") {
      if (!message.startsWith("Seeded")) throw new Error(message);
    } else {
      if (!message.startsWith("Rows:")) throw new Error(message);
      const rows = message
        .slice(5)
        .split(";")
        .filter(Boolean)
        .map((value) => value.trim())
        .sort();
      results[item.name] = rows;
      if (
        "expected" in item &&
        JSON.stringify(rows) !== JSON.stringify(item.expected)
      )
        throw new Error(`${item.name}: ${JSON.stringify(rows)}`);
    }
    document
      .querySelector<HTMLButtonElement>(
        '.modal-dialog button.btn-primary, button[aria-label="Dismiss notification"]',
      )!
      .click();
    await waitFor(() => !document.querySelector(selector));
  }
  return { status: "passed", results };
})();

import cases from "./cases.json";

export default (async () => {
  const waitFor = async (check: () => boolean) => {
    for (let attempt = 0; attempt < 300; attempt++) {
      if (check()) return;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    throw new Error("OQL dataset action timed out");
  };
  const actions = cases.flatMap((item) =>
    ["Dataset", "Text"].map((mode) => ({ ...item, name: item.name + mode })),
  );
  const results: Record<string, string[]> = {};
  for (const item of [{ name: "Seed" }, ...actions]) {
    document.querySelector<HTMLButtonElement>(`.mx-name-${item.name}`)!.click();
    const selector = ".modal-dialog .modal-body, .mxrb-runtime-notice";
    await waitFor(() => !!document.querySelector(selector));
    const content = document
      .querySelector(selector)!
      .cloneNode(true) as HTMLElement;
    content.querySelectorAll("button").forEach((button) => button.remove());
    const message = content.textContent!.trim();
    if (item.name === "Seed") {
      if (!message.startsWith("Seeded")) throw new Error(message);
    } else {
      if (!message.startsWith("Rows:")) throw new Error(message);
      let rows = message
        .slice(5)
        .split(";")
        .filter(Boolean)
        .map((value) => value.trim());
      // SQL does not specify the relative order of equal sort keys. Keep the
      // key groups ordered while normalizing only rows tied within each group.
      if ("tie_column" in item && typeof item.tie_column === "number") {
        const groups: string[][] = [];
        for (const row of rows) {
          const previous = groups.at(-1);
          if (
            previous &&
            previous[0].split("|")[item.tie_column] ===
              row.split("|")[item.tie_column]
          )
            previous.push(row);
          else groups.push([row]);
        }
        rows = groups.flatMap((group) => group.sort());
      }
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

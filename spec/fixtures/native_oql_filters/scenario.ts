import cases from "./cases.json";

export default (async () => {
  const waitFor = async (check: () => boolean) => {
    for (let i = 0; i < 200; i += 1) {
      if (check()) return;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    throw new Error("OQL filter action timed out");
  };
  const results: Record<string, string[]> = {};
  for (const item of [{ name: "Seed", expected: [] }, ...cases]) {
    const button = document.querySelector<HTMLButtonElement>(
      `.mx-name-${item.name}`,
    );
    if (!button) throw new Error(`Missing action ${item.name}`);
    button.click();
    await waitFor(
      () => document.querySelector(".modal-dialog .modal-body") !== null,
    );
    const message = document
      .querySelector(".modal-dialog .modal-body")!
      .textContent!.trim();
    if (item.name === "Seed") {
      if (message !== "Seeded") throw new Error(message);
    } else {
      if (!message.startsWith("Rows:")) throw new Error(message);
      const rows = message.slice(5).split(",").filter(Boolean).sort();
      results[item.name] = rows;
      if (JSON.stringify(rows) !== JSON.stringify(item.expected))
        throw new Error(`${item.name}: ${JSON.stringify(rows)}`);
    }
    document
      .querySelector<HTMLButtonElement>(".modal-dialog button.btn-primary")!
      .click();
    await waitFor(() => document.querySelector(".modal-dialog") === null);
  }
  return { status: "passed", results };
})();

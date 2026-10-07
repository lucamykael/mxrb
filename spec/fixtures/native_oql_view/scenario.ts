(async () => {
  const waitFor = async (check: () => boolean) => {
    for (let i = 0; i < 200; i += 1) {
      if (check()) return;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    throw new Error("OQL view action timed out");
  };
  const results: {action: string; message: string}[] = [];
  for (const [name, expected] of [
    ["Seed", "Seeded"],
    ["ReadView", "2: North"],
    ["ReadAssociation", "Source: Street 1"],
    ["ReadDirtySource", "Durable: North"],
    ["CommitChange", "Committed"],
    ["ReadView", "2: Changed"],
    ["DeleteSource", "Deleted"],
    ["ReadView", "1: South"],
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
    results.push({action: name, message: expected});
    const confirm = document.querySelector<HTMLButtonElement>(
      ".modal-dialog button.btn-primary",
    );
    if (!confirm) throw new Error("Missing confirmation");
    confirm.click();
    await waitFor(() => document.querySelector(".modal-dialog") === null);
  }
  return { status: "passed", results };
})();

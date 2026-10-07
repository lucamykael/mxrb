(async () => {
  const waitFor = async (check: () => boolean) => {
    for (let i = 0; i < 160; i += 1) {
      if (check()) return;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    throw new Error("Object storage scenario timed out");
  };
  const click = (name: string) => {
    const button = document.querySelector<HTMLButtonElement>(
      `.mx-name-${name}`,
    );
    if (!button) throw new Error(`Missing button ${name}`);
    button.click();
  };
  const message = async (text: string) => {
    await waitFor(() =>
      [...document.querySelectorAll(".modal-dialog")].some((node) =>
        node.textContent?.includes(text),
      ),
    );
    document
      .querySelector<HTMLButtonElement>(".modal-dialog button.btn-primary")!
      .click();
    await waitFor(() => document.querySelector(".modal-dialog") === null);
  };
  localStorage.removeItem("mxrb-object-oracle");
  const results: object[] = [];
  let previousGuid: string | undefined;
  for (const action of ["WriteLegacy", "WriteCurrent"]) {
    click(action);
    await message("stored");
    const stored = JSON.parse(localStorage.getItem("mxrb-object-oracle")!);
    if (!stored.guid || (previousGuid && stored.guid !== previousGuid))
      throw new Error("Object guid changed");
    previousGuid = stored.guid;
    delete stored.guid;
    const expected = {
      Name: "Object oracle",
      Amount: "9007199254740993.12345678",
      Count: "12",
      Active: true,
      When: 1767323045000,
      "FeedbackModule.Probe_Related": null,
    };
    for (const [key, value] of Object.entries(expected))
      if (stored[key] !== value) throw new Error(`Storage mismatch: ${key}`);
    if (Object.keys(stored).length !== Object.keys(expected).length)
      throw new Error("Unexpected storage fields");
    results.push(stored);
    click("ReadName");
    await message("Object oracle");
    click("ReadAmount");
    await message("9007199254740993.12345678");
  }
  return { status: "passed", same_guid: true, variants: results };
})();
